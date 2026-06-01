# clickhouse-profiler · pipeline SQL recipes

Full SQL for the profiler pipeline (phases 0–8). Consult this file when
SKILL.md instructs you to run a phase. SQL assumes you have a read-only
`execute_query` MCP tool available.

All identifiers follow standard ClickHouse system-tables conventions. No
audit-corpus special naming is assumed — that's a different use case
(profiling a pre-captured audit snapshot) documented at the end.

## Phase 0 — Connect and detect shape

### 0a. CH version
```sql
SELECT value FROM system.build_options WHERE name = 'VERSION_FULL';
```
If this fails: `SELECT version()`.

Bucket the result:
- `21.x` → old-style: no `as_select`, empty `system.dictionaries` risk, inline-MV naming `.inner.<name>`
- `22.x` → `as_select` available from 22.1+; inline-MV still `.inner.<name>` on ≤22.12; `loading_dependencies_*` sparse
- `23.x` → inline-MV naming changes to `.inner_id.<uuid>`; `as_select` present
- `≥ 24.x` → `loading_dependencies_*` reliably populated

### 0b. Query-log shape
```sql
DESCRIBE system.query_log;
```
Scan output for column names:
- If you see `any(tables) Array(String)` → **pre-aggregated shape** (audit corpus).
- If you see plain `tables Array(String)` → **raw shape** (live cluster).

Every SQL template below has two versions: use the raw one for live
clusters (default); pre-aggregated if detection matches.

### 0c. Distributed naming
```sql
SELECT name, engine_full
FROM system.tables
WHERE database NOT IN ('system','information_schema','INFORMATION_SCHEMA','_temporary_and_external_tables')
  AND engine = 'Distributed'
LIMIT 100;
```
Parse each row's `engine_full` as:
`Distributed('<cluster_macro>', '<remote_db>', '<remote_table>', <shard_key>, [policy])`

Record:
- The Distributed's own name (`X`) vs its target name (`<remote_table>`).
- The shard key expression (`rand()`, `cityHash64(col)`, `murmurHash3_64(col)`, `sipHash64(col)`, etc.).
- Whether the Distributed name is a prefix/suffix/bare variant of the local.

Build a naming-convention summary:
- `X → X_local` → suffix convention (prism-style)
- `X → X` where current is `X_d` → suffix `_d` convention (tdw-prod)
- `X → Y` where current is `dist_Y` → prefix `dist_` convention (exads)
- No Distributed engines → single-shard cluster (hockeystack)

### 0d. Kafka presence
```sql
SELECT count() AS kafka_n FROM system.tables
WHERE engine = 'Kafka'
  AND database NOT IN ('system','information_schema','INFORMATION_SCHEMA');
```
If > 0: Group-E streaming cluster. Trigger the streaming-specific mining
(Phase 5f).

## Phase 1 — Discovery

### 1a. Cluster topology
```sql
SELECT cluster,
       count() AS hosts,
       max(shard_num) AS shards,
       max(replica_num) AS max_replicas_per_shard
FROM system.clusters
GROUP BY cluster
ORDER BY hosts DESC;
```

### 1b. DB roster + engine mix preview
```sql
SELECT database,
       count() AS n,
       arraySort(groupUniqArray(engine))[1:10] AS engines_sample
FROM system.tables
WHERE database NOT IN ('system','information_schema','INFORMATION_SCHEMA','_temporary_and_external_tables')
GROUP BY database
ORDER BY n DESC;
```

### 1c. Query-log span
Raw:
```sql
SELECT min(event_date) AS qlog_min,
       max(event_date) AS qlog_max,
       count() AS qlog_rows,
       count(DISTINCT normalized_query_hash) AS distinct_queries
FROM system.query_log
WHERE type = 'QueryFinish';
```
Pre-aggregated:
```sql
SELECT min(`any(event_date)`) AS qlog_min,
       max(`any(event_date)`) AS qlog_max,
       count() AS qlog_rows,   -- rows = distinct hashes already
       sum(`count()`) AS qlog_execs
FROM system.query_log
WHERE `any(type)` = 'QueryFinish';
```

### 1d. Engine frequency (business DBs only)
```sql
SELECT engine, count() AS n
FROM system.tables
WHERE database IN (:business_dbs)
GROUP BY engine
ORDER BY n DESC;
```

### 1e. Quick role-counts (for phase-6 priors)
```sql
SELECT
  sum(engine = 'Kafka') AS kafka_n,
  sum(engine = 'Null') AS null_n,
  sum(engine = 'Buffer') AS buffer_n,
  sum(engine = 'MaterializedView') AS mv_n,
  sum(engine = 'Dictionary') AS dict_n,
  sum(engine = 'Distributed') AS dist_n,
  sum(engine = 'View') AS view_n,
  sum(engine LIKE '%MergeTree%') AS mt_family_n,
  sum(engine IN ('MySQL','PostgreSQL','URL','S3','S3Queue','HDFS','MongoDB','Redis')) AS external_n,
  count() AS total
FROM system.tables
WHERE database IN (:business_dbs);
```

## Phase 1.5 — Archetype detect

Inputs: counts already gathered in **Phase 1d** (engine frequency) and
**Phase 1e** (quick role-counts). Output: `primary_archetype ∈
{A,B,C,D,E}` plus optional `secondary_archetypes ⊆ {A,B,C,D,E}`. No
new SQL is required if 1d/1e ran cleanly; if either was skipped, run
the consolidated query below now.

### 1.5a. Consolidated counts (run only if 1e was skipped)

```sql
SELECT
  count()                                                AS biz_tabs,
  countIf(engine = 'Distributed')                        AS dist_n,
  countIf(engine = 'View')                               AS view_n,
  countIf(engine = 'MaterializedView')                   AS mv_n,
  countIf(engine LIKE '%SummingMergeTree%')              AS summ_n,
  countIf(engine LIKE '%AggregatingMergeTree%')          AS agg_n,
  countIf(engine LIKE '%ReplacingMergeTree%')            AS repl_n,
  countIf(engine = 'Dictionary')                         AS dict_n,
  countIf(engine = 'Buffer')                             AS buffer_n,
  countIf(engine = 'Kafka')                              AS kafka_n,
  countIf(engine = 'Null')                               AS null_n,
  countIf(engine IN ('MySQL','PostgreSQL','URL','S3','S3Queue',
                     'HDFS','MongoDB','Redis'))          AS external_n,
  countIf(engine = 'MergeTree')                          AS mt_n
FROM system.tables
WHERE database IN (:business_dbs);
```

Compute shares as `<count> / biz_tabs` for each.

### 1.5b. Decision (first-match-wins)

The archetype routing rules live in `archetypes/README.md`. Apply them
in order, **first match wins**:

| # | Rule | Archetype |
|---|---|---|
| 1 | `biz_tabs > 5000` | **B** |
| 2 | `view_share > 0.7` AND `biz_tabs > 500` | **C** |
| 3 | `kafka_n > 15` OR (`null_n > 20` AND `mv_share > 0.10`) | **E** |
| 4 | `external_n > 30` OR `external_n / biz_tabs > 0.30` | **E** |
| 5 | `dict_share > 0.03` AND `mv_share > 0.10` | **D** |
| 6 | `mv_share > 0.12` AND (`summ_share > 0.02` OR `agg_share > 0.05`) | **C** |
| 7 | `dist_share > 0.20` AND `repl_share > 0.15` | **B** |
| 8 | `dist_share > 0.20` | **B** |
| 9 | `mv_share > 0.08` AND (`buffer_n > 5` OR `mt_share > 0.40`) | **C** |
| 10 | `biz_tabs < 100` | **A** |
| 11 | else (mid-size plain MT fallback) | **A** |

Reference Python sketch (paste-ready; no external deps):

```python
def detect_primary(c):  # c = dict of counts and shares
    if c["biz_tabs"] > 5000: return "B", "rule-1 huge-enterprise"
    if c["view_share"] > 0.70 and c["biz_tabs"] > 500: return "C", "rule-2 view-warehouse"
    if c["kafka_n"] > 15 or (c["null_n"] > 20 and c["mv_share"] > 0.10):
        return "E", "rule-3 kafka-streaming"
    if c["external_n"] > 30 or (c["biz_tabs"] and c["external_n"] / c["biz_tabs"] > 0.30):
        return "E", "rule-4 federation"
    if c["dict_share"] > 0.03 and c["mv_share"] > 0.10: return "D", "rule-5 star-dict"
    if c["mv_share"] > 0.12 and (c["summ_share"] > 0.02 or c["agg_share"] > 0.05):
        return "C", "rule-6 cube-mv"
    if c["dist_share"] > 0.20 and c["repl_share"] > 0.15:
        return "B", "rule-7 sharded-replacing"
    if c["dist_share"] > 0.20: return "B", "rule-8 sharded-plain"
    if c["mv_share"] > 0.08 and (c["buffer_n"] > 5 or c["mt_share"] > 0.40):
        return "C", "rule-9 realtime-mv"
    if c["biz_tabs"] < 100: return "A", "rule-10 small-simple"
    return "A", "rule-11 plain-mt-fallback"
```

### 1.5c. Hybrid (secondary) detection

After the primary is assigned, evaluate the *other* ten rules with
thresholds halved. Any rule that fires adds its archetype to
`secondary_archetypes` (deduped, primary excluded). The intent is to
catch hybrids — a Cube/MV cluster that also ingests via Kafka, a
sharded OLAP cluster with a non-trivial MV layer, etc.

```python
HALVED = {
    "view_share": 0.35, "kafka_n": 7, "null_n_with_mv": (10, 0.05),
    "external_n_count": 15, "external_n_share": 0.15,
    "dict_share": 0.015, "mv_share_for_d": 0.05,
    "mv_share_for_c": 0.06, "summ_share": 0.01, "agg_share": 0.025,
    "dist_share": 0.10, "repl_share": 0.075,
    "mv_share_for_realtime": 0.04, "buffer_n": 2, "mt_share": 0.20,
}

def detect_secondaries(c, primary):
    sec = set()
    if c["biz_tabs"] > 2500: sec.add("B")
    if c["view_share"] > HALVED["view_share"] and c["biz_tabs"] > 250: sec.add("C")
    if c["kafka_n"] > HALVED["kafka_n"]: sec.add("E")
    nm = HALVED["null_n_with_mv"]
    if c["null_n"] > nm[0] and c["mv_share"] > nm[1]: sec.add("E")
    if c["external_n"] > HALVED["external_n_count"]: sec.add("E")
    if c["biz_tabs"] and c["external_n"] / c["biz_tabs"] > HALVED["external_n_share"]:
        sec.add("E")
    if c["dict_share"] > HALVED["dict_share"] and c["mv_share"] > HALVED["mv_share_for_d"]:
        sec.add("D")
    if c["mv_share"] > HALVED["mv_share_for_c"] and \
       (c["summ_share"] > HALVED["summ_share"] or c["agg_share"] > HALVED["agg_share"]):
        sec.add("C")
    if c["dist_share"] > HALVED["dist_share"] and c["repl_share"] > HALVED["repl_share"]:
        sec.add("B")
    if c["dist_share"] > HALVED["dist_share"]: sec.add("B")
    if c["mv_share"] > HALVED["mv_share_for_realtime"] and \
       (c["buffer_n"] > HALVED["buffer_n"] or c["mt_share"] > HALVED["mt_share"]):
        sec.add("C")
    sec.discard(primary)
    return sorted(sec)
```

### 1.5d. Load the archetype module(s)

Read `archetypes/<primary>.md` in full now. The module's **Phase
emphasis** section will guide the model's effort allocation across
Phases 3-7. The module's **Engine traps** and **Corpus-override
list** sections are consulted again at Phases 5d.1 and 8.

For each secondary, read only the **Engine traps** and
**Corpus-override list** sections of `archetypes/<secondary>.md`.

### 1.5e. Record the assignment

The primary + secondaries are written into the artifact in two places
at synthesis time:

- `SKILL.md` frontmatter: `primary_archetype: <X>` and (optional)
  `secondary_archetypes: [<Y>, <Z>]`.
- `patterns.md` opening line: `**Cluster archetype**: <X> (<rule>);
  hybrid signals: <list-or-"none">`.

If the user explicitly asks "why this archetype?", show the rule
that matched plus the 1-2 inputs that crossed thresholds.

## Phase 2 — Questionnaire (interactive)

Present a preview of phase-1 findings (including the assigned
archetype from 1.5), then ask ≤5 questions. See SKILL.md for question
templates. No SQL here.

The first question is the **database-scope** question — which of the
business DBs found in Phase 1b should be in scope for deep mining.
The answer feeds Phase 3's `WHERE database IN (:included)` filter and
the Phase 5a workload-shape window, so narrowing here cuts the most
downstream work. Surface the Phase 1c table-count breakdown when
asking — the user picks scope by where the volume actually lives, not
by name. Default is "all non-sandbox business DBs"; common
narrowings are single-tenant DB, single product line, or
exclude-archived. `system`, `information_schema`, and
`_temporary_and_external_tables` are always excluded.

## Phase 3 — Catalog

### 3a. Table metadata
```sql
SELECT
    database, name,
    engine, engine_full,
    partition_key, sorting_key, primary_key, sampling_key,
    total_rows, total_bytes,
    metadata_modification_time,
    comment
FROM system.tables
WHERE database IN (:included);
```

### 3b. Columns for Pareto tables (deferred; run after phase 5a picks the top)
```sql
SELECT database, table, name, type, position,
       is_in_partition_key, is_in_sorting_key, is_in_primary_key,
       default_kind, default_expression,
       compression_codec,
       comment
FROM system.columns
WHERE (database, table) IN (:pareto_pairs);
```

### 3c. Distributed/local pair table
Derived from 0c output. Produce a list of pairs, one per Distributed
engine, with shard key and a recommendation for which name to query.

### 3d. MV TO-target resolution
```sql
SELECT database, name, engine_full, as_select
FROM system.tables
WHERE engine = 'MaterializedView' AND database IN (:included);
```
If `as_select` column doesn't exist (CH < 22):
```sql
SELECT database, name, engine_full, create_table_query
FROM system.tables
WHERE engine = 'MaterializedView' AND database IN (:included);
```

**`engine_full` codec bug fallback**: some CH 23.x builds return
`readData: block decode for exception: unexpected value 111 for boolean`
when `engine_full` is selected alongside other columns over the native
protocol / HTTP. If you hit this, **do not** keep retrying `engine_full`;
drop it and parse `substring(create_table_query, 1, 500)` instead — every
`TO <db>.<table>` clause and every `SETTINGS kafka_*='...'` key-value is
present in `create_table_query` and the substring cap keeps the payload
small:

```sql
SELECT database, name,
       substring(create_table_query, 1, 500) AS ddl
FROM system.tables
WHERE engine = 'MaterializedView' AND database IN (:included);
```

Extract the TO target from `engine_full` or parse CREATE TABLE via regex
`TO\s+([a-zA-Z0-9_.]+)`. Follow the chain: if TO target is a Distributed,
parse the Distributed's `engine_full` (or its DDL substring) to find the
actual backing table. Repeat until non-Distributed.

## Phase 4 — Relations

### 4a. Dependency graph
```sql
SELECT database, name, engine,
       dependencies_database, dependencies_table,
       loading_dependencies_database, loading_dependencies_table,
       loading_dependent_database, loading_dependent_table
FROM system.tables
WHERE database IN (:included)
  AND (length(dependencies_table) > 0
       OR length(loading_dependencies_table) > 0
       OR length(loading_dependent_table) > 0);
```

### 4b. Dictionary catalog
```sql
SELECT database, name, type, source, element_count,
       attribute.names, attribute.types,
       key.names, key.types,
       hit_rate, found_rate, status, last_exception
FROM system.dictionaries
WHERE database IN (:included);
```

### 4c. Dictionary fallback (if 4b returns 0 rows despite Dictionary engines)
```sql
SELECT database, name, create_table_query
FROM system.tables
WHERE engine = 'Dictionary' AND database IN (:included);
```
Parse `CREATE DICTIONARY ... (col1 T1, col2 T2, ...) PRIMARY KEY (keys)
SOURCE(<source>) LAYOUT(<layout>) LIFETIME(<lifetime>)` from the DDL.
Extract attribute list, source type, layout type.

### 4d. View / MV bodies (for implicit-relation extraction)
```sql
-- CH ≥ 22 (has as_select)
SELECT database, name, engine, as_select
FROM system.tables
WHERE database IN (:included)
  AND engine IN ('View', 'MaterializedView', 'LiveView');

-- CH < 22 fallback
SELECT database, name, engine, create_table_query
FROM system.tables
WHERE database IN (:included)
  AND engine IN ('View', 'MaterializedView');
```
Regex-extract `FROM\s+(?:(\w+)\.)?(\w+)` and `JOIN\s+(?:(\w+)\.)?(\w+)`
references from each View/MV body.

## Phase 5 — Query mining

### 5a. Top-50 tables by execs, with workload shape + users

Raw query_log:
```sql
SELECT t AS full_name,
       count() AS execs,
       sum(query_duration_ms) AS total_ms,
       sumIf(1, query_kind = 'Select') AS sels,
       sumIf(1, query_kind = 'Insert') AS ins,
       arraySlice(arraySort(groupUniqArray(user)), 1, 8) AS users
FROM system.query_log
ARRAY JOIN tables AS t
WHERE type = 'QueryFinish'
  AND event_date BETWEEN :mine_from AND :mine_to
  AND splitByChar('.', t)[1] NOT IN
      ('system','information_schema','INFORMATION_SCHEMA','_temporary_and_external_tables','_table_function')
GROUP BY t
ORDER BY execs DESC LIMIT 50;
```

Pre-aggregated query_log (audit corpus):
```sql
SELECT t AS full_name,
       sum(`count()`) AS execs,
       sum(`sum(query_duration_ms)`) AS total_ms,
       sum(if(`any(query_kind)` = 'Select', `count()`, 0)) AS sels,
       sum(if(`any(query_kind)` = 'Insert', `count()`, 0)) AS ins,
       arraySlice(arraySort(groupUniqArray(`any(user)`)), 1, 8) AS users
FROM system.query_log
ARRAY JOIN `any(tables)` AS t
WHERE `any(type)` = 'QueryFinish'
  AND splitByChar('.', t)[1] NOT IN
      ('system','information_schema','INFORMATION_SCHEMA','_temporary_and_external_tables','_table_function')
GROUP BY t
ORDER BY execs DESC LIMIT 50;
```

### 5b. Co-occurrence (empirical join graph)

Raw:
```sql
SELECT arraySort(arrayFilter(
         x -> splitByChar('.',x)[1] NOT IN
              ('system','information_schema','INFORMATION_SCHEMA',
               '_temporary_and_external_tables','_table_function'),
         tables)) AS ts,
       length(ts) AS n,
       count() AS execs
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date BETWEEN :mine_from AND :mine_to
  AND length(ts) BETWEEN 2 AND 8
GROUP BY ts
ORDER BY execs DESC LIMIT 50;
```

Pre-aggregated:
```sql
SELECT arraySort(arrayFilter(
         x -> splitByChar('.',x)[1] NOT IN
              ('system','information_schema','INFORMATION_SCHEMA',
               '_temporary_and_external_tables','_table_function'),
         `any(tables)`)) AS ts,
       length(ts) AS n,
       sum(`count()`) AS execs
FROM system.query_log
WHERE `any(type)` = 'QueryFinish' AND length(ts) BETWEEN 2 AND 8
GROUP BY ts
ORDER BY execs DESC LIMIT 50;
```

### 5c. Hot columns per Pareto table

ARRAY JOIN of two arrays with different lengths fails. Use a subquery
with two separate `arrayJoin` calls:

Raw:
```sql
SELECT t, col, sum(execs) AS touches
FROM (
  SELECT arrayJoin(tables) AS t,
         arrayJoin(columns) AS col,
         1 AS execs
  FROM system.query_log
  WHERE type = 'QueryFinish'
    AND event_date BETWEEN :mine_from AND :mine_to
)
WHERE t IN (:pareto) AND startsWith(col, concat(t, '.'))
GROUP BY t, col
HAVING touches > :threshold
ORDER BY t, touches DESC;
```

Pre-aggregated:
```sql
SELECT t, col, sum(execs) AS touches
FROM (
  SELECT arrayJoin(`any(tables)`) AS t,
         arrayJoin(`any(columns)`) AS col,
         `count()` AS execs
  FROM system.query_log
  WHERE `any(type)` = 'QueryFinish'
)
WHERE t IN (:pareto) AND startsWith(col, concat(t, '.'))
GROUP BY t, col
HAVING touches > :threshold
ORDER BY t, touches DESC;
```

Threshold guidance: start with 10 for small query logs (<10k rows),
100 for medium (10k-1M), 1000 for huge (>1M). Goal: ~15-30 columns per
hot table.

### 5d. Representative normalized queries (PII stripped)

Raw:
```sql
SELECT normalized_query_hash,
       any(normalizeQuery(replaceRegexpAll(query, '/\\*.*?\\*/', ''))) AS clean,
       count() AS execs,
       arrayDistinct(any(tables)) AS tables_touched
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date BETWEEN :mine_from AND :mine_to
  AND has(tables, :target_table)
GROUP BY normalized_query_hash
ORDER BY execs DESC
LIMIT 5;
```

Pre-aggregated:
```sql
SELECT normalized_query_hash,
       normalizeQuery(replaceRegexpAll(`any(query)`, '/\\*.*?\\*/', '')) AS clean,
       `count()` AS execs,
       `any(tables)` AS tables_touched
FROM system.query_log
WHERE `any(type)` = 'QueryFinish'
  AND has(`any(tables)`, :target_table)
ORDER BY execs DESC
LIMIT 5;
```

**Do not quote these queries literally in the artifact.** Use them to
understand shape — which columns are filtered, which aggregates, which
joins — and write pattern cards in `patterns.md`.

### 5d.1 — Form-level writing conventions (from the query corpus)

The cluster's hot queries reveal stylistic conventions the analyst
should follow. These are observable engine-level facts about how
queries on this cluster are written, not recipes — distinct from the
schema-level facts mined elsewhere.

Run on the same mining window:

```sql
WITH q AS (
  SELECT lower(replaceRegexpAll(query, '/\\*.*?\\*/', '')) AS body, count() AS execs
  FROM system.query_log
  WHERE type = 'QueryFinish'
    AND event_date BETWEEN :mine_from AND :mine_to
    AND query_kind = 'Select'
    AND has(tables, :hot_fact)            -- pick the top hot fact
  GROUP BY body
)
SELECT
  sumIf(execs, match(body, '\\bprewhere\\b'))                       AS uses_prewhere,
  sumIf(execs, match(body, '\\bwhere\\b')
            AND NOT match(body, '\\bprewhere\\b'))                  AS uses_where_only,
  sumIf(execs, match(body, '\\bfinal\\b'))                          AS uses_final,
  sumIf(execs, match(body, '\\bargmax\\s*\\('))                     AS uses_argmax,
  sumIf(execs, match(body, '\\banylast\\s*\\('))                    AS uses_anylast,
  sumIf(execs, match(body, '\\btodate\\s*\\('))                     AS uses_todate,
  sumIf(execs, match(body, '\\btostartofday\\s*\\('))               AS uses_tostartofday,
  sumIf(execs, match(body, '\\bselect\\s+\\*'))                     AS uses_select_star,
  sum(execs)                                                        AS total
FROM q;
```

Word-boundary regex via `match()` avoids the substring-match traps
(`whereas`, `nowhere`, `prewhere` matching the bare-`where` test) that
plain `position()` checks fall into.

Write down the **form ratios** (uses_prewhere / total, etc.) per hot
fact, and surface the dominant ones in the artifact:

- If `uses_prewhere / (uses_prewhere + uses_where_only) > 0.5` on the
  top fact, document **"PREWHERE the tenant + date filters"** in the
  cluster's writing-style conventions section of `patterns.md`. Use the
  observed ratio as the why: "≥ X% of hot queries on this cluster use
  PREWHERE for these columns; the optimizer often hoists from WHERE,
  but the explicit form is the cluster idiom and easier to read."
- If `uses_anylast / (uses_anylast + uses_argmax) > 0.5` on AggMT
  facts, document `anyLast` as the latest-row idiom (not `argMax`).
- If `uses_todate / (uses_todate + uses_tostartofday) > 0.5`,
  document `toDate(<col>)` as the daily-bucket idiom.
- If `uses_select_star / total > 0.05`, note "wide projections appear
  in N% of hot queries — narrow projection is preferred but not
  enforced on this cluster" and don't make it a hard rule.

These are **observable, cluster-specific writing conventions**. They
are not recipes (the analyst still composes its own SQL); they are
form-level facts about how this cluster's queries are written. Document
them in `patterns.md` under "Cluster-wide writing conventions" and
cite the observed ratio so the analyst knows the strength of the
convention.

If the form ratios are roughly even (no dominant style), don't invent a
convention. Note "no dominant form-level convention observed" instead
of guessing.

**Run this via the helper, not by hand.** Arithmetic + threshold
checks + bullet formatting drift across runs when the model does
them:

```bash
python3 tools/synthesize_conventions.py counts.json <top_fact> \
        --archetypes C \
        --top-fact-has-anylast-simple-agg
```

Arguments:
- `counts.json`: single-row result of the form-mining query above (a
  JSON object, not an array).
- `<top_fact>`: fully-qualified name of the top fact to cite in
  bullets.
- `--archetypes`: comma-separated list of the archetypes assigned at
  Phase 1.5 (primary first, then any secondaries — order doesn't
  matter to the helper). Each archetype's **Corpus-override list**
  is consulted before bullets are emitted.
- `--top-fact-has-anylast-simple-agg`: pass this flag if the top
  fact's `system.columns` rows include any
  `SimpleAggregateFunction(anyLast, …)` column type. This is the
  trigger for archetype C's hard-suppression of the
  `argMax`/`anyLast` corpus bullet (see `archetypes/C-cube-mv.md`
  → `[trap-C1]`).

Output is a markdown fragment ready to paste under the "From the
corpus (mined)" subsection of `patterns.md`. The helper's decision
rules match this section exactly; if you tweak the rules here,
update `synthesize_conventions.py` in the same change. Archetype
override behavior is documented in
`archetypes/<id>.md` → "Corpus-override list" — keep those tables
and the helper's switch logic in sync.

To check whether the trigger flag applies, query columns once on the
top fact:

```sql
SELECT name, type
FROM system.columns
WHERE database = :top_db AND table = :top_table
  AND type LIKE 'SimpleAggregateFunction(anyLast,%';
```

If any rows return, pass `--top-fact-has-anylast-simple-agg`.

### 5e. Co-occurrence dedup (mandatory after 5b)

Strip pseudo-joins that are actually engine resolutions:

- `(X, .inner.mv_X)` / `(X, .inner_id.<uuid>)` → view-to-storage resolution (CH MV), not a join.
- `(X, X_local)` / `(X_d, X)` / `(dist_X, X)` → Distributed-to-local resolution, not a join.
- Any set where all members resolve to the same underlying data via engine wrapping.

Build an exclusion list from the Distributed/MV pairing tables (0c, 3c,
3d) and filter 5b results through it.

### 5f. Streaming-specific mining (when phase 0d shows Kafka engines)

```sql
-- Kafka consumers with broker/topic/group
SELECT name, engine_full
FROM system.tables
WHERE engine = 'Kafka' AND database IN (:included);
```
Parse each `engine_full`:
`Kafka SETTINGS kafka_broker_list = '<host:port>', kafka_topic_list = '<topic>', kafka_group_name = '<group>', kafka_format = '<format>', ...`

If `engine_full` fails with the CH 23.x codec bug (`unexpected value 111
for boolean`), fall back to `substring(create_table_query, 1, 500)` as
described in 3d. Regex-extract keys directly from the DDL:
`kafka_topic_list = '([^']+)'`, `kafka_group_name = '([^']+)'`,
`kafka_broker_list = '([^']+)'`.

```sql
SELECT name,
       extract(create_table_query, 'kafka_topic_list = ''([^'']+)''') AS topic,
       extract(create_table_query, 'kafka_group_name = ''([^'']+)''') AS cg,
       extract(create_table_query, 'kafka_broker_list = ''([^'']+)''') AS brokers
FROM system.tables
WHERE engine = 'Kafka' AND database IN (:included);
```

```sql
-- Null engine landing pads (typical between Kafka and MV)
SELECT name FROM system.tables
WHERE engine = 'Null' AND database IN (:included);
```

```sql
-- Kafka-triggered MVs — chain Kafka → MV → target
SELECT name, engine_full, as_select   -- or create_table_query on CH<22
FROM system.tables
WHERE engine = 'MaterializedView' AND database IN (:included);
```
For each MV, the SELECT body reveals the source table (usually a Kafka
engine or Null engine). The `TO` clause in `engine_full` reveals the
target.

Build an ingestion-chain map for the artifact's `pipeline.md`:
`<Kafka topic> → <Kafka engine table> → [<Null pad> →] <MV name> → <target>`

If target is a Distributed: follow to the `_local` via 3d.

### 5g. Cluster-name resolution (if needed)

If the chosen name from 1a is generic, look at Kafka engine_full for
business-identifying hostnames:
```sql
SELECT name, engine_full FROM system.tables WHERE engine = 'Kafka' LIMIT 10;
```
Extract broker hostnames; if they reveal a business name, use it.

Otherwise, use the dominant business-DB name from 1b.

## Phase 6 — Demotion (split analyst-hot vs pipeline-hot)

Algorithm:

```
for each of the top-50 tables from 5a:
    demote = False
    reasons = []

    # Rule 1: insert-dominated
    if ins > 0 and (ins / (sels + ins)) > 0.9:
        demote = True; reasons.add("insert-dominated")

    # Rule 2: service-users-only
    if all(u in SERVICE_USERS for u in users):
        demote = True; reasons.add("service-users-only")

    # Rule 3: never co-occurs with analyst-hot surface
    # Only apply after a preliminary analyst-hot set exists.

    # Rule 4: engine-by-nature
    if engine in ('Kafka', 'Null', 'Buffer', 'MaterializedView') or
       name starts with '.inner.mv_' or '.inner_id.':
        demote = True; reasons.add("engine-is-infra")

    # Rule 5: staging naming
    if name suffix in ('_new', '_tmp', '_staging', '_old', '_backup'):
        demote = True; reasons.add("staging-name")

    # Caveats (un-demote):
    # - If name matches <base>_test_v<n> AND exec count rivals base:
    #     it's shadow-traffic, not a sandbox. Keep hot.
    # - If this is one of hundreds of tables with per-tenant hash in name
    #   AND co-occurs with the main fact:
    #     summarize as cache pattern; list pattern once, not per-tenant.
```

`SERVICE_USERS` default: `default, clickhouse, airflow*, bot*, monitor*,
oncall*, empty-string`. The questionnaire lets the user add/remove.

**Run this via the helper, not by hand.** The arithmetic + caveats are
mechanical and inconsistent when done by the model:

```bash
python3 tools/pareto_cut.py top50.json schema.json \
        --service-users default,clickhouse_operator,airflow \
        --archetype C \
        --target 20
```

Inputs:
- `top50.json`: result rows from the 5a query, as JSON list of objects
  with keys `full_name, execs, total_ms, sels, ins, users`.
- `schema.json` (optional): per-table `engine, total_rows` from
  Phase 1d / Phase 3. Without it, engine-by-nature (Rule 4) is skipped
  for tables not flagged by name.
- `--archetype` (optional): the Phase 1.5 primary archetype letter.
  When `B` and the cluster has > 5000 business tables (huge-enterprise
  sub-pattern from `archetypes/README.md` rule 1), the helper raises the
  service-user dominance threshold and is more aggressive on Rule 2.
  No effect for other archetypes — they share the default thresholds.

Output: a markdown summary listing analyst-hot vs. demoted, with
**review flags** for ambiguous cases the model needs to resolve:

- `misleading-staging-name`: `_new`/`_tmp` suffix but select-dominated
  by humans. The suffix is conventional but the table is live.
  Confirm with the catalog owner before final demotion.
- `shadow-traffic-vs-<base>`: `*_test_v<n>` running at ≥ 50% of base
  table's exec count. Almost certainly live A/B traffic.
- `per-tenant-hash-pattern`: looks like one of N per-tenant caches.
  Summarize the pattern once in `pipeline.md`; do not enumerate.

Resolve review flags with judgment + co-occurrence evidence (Phase 5b)
before Phase 7.

## Phase 7 — Classification

For each analyst-hot table (post-demotion), assign a role:

```
case engine:
    'Dictionary'        → Dim, Confident
    'MaterializedView'  → would've been demoted; skip
    'View', 'LiveView'  → Mart, Confident
    'Kafka','Null','Buffer' → would've been demoted; skip
    else:
        if 'MergeTree' in engine:
            if has_timestamp_column and total_rows >= 1_000_000:
                Fact, Confident if total_rows >= 10_000_000 else Fact, Likely
            elif total_rows < 100_000 and is_lookup_shaped (id+name cols):
                Dim, Likely (not Dictionary)
            else:
                Other
        else:
            Other
```

Naming hints — use ONLY if engine-based rule gave Other or Likely:
- DB named `Fact`, `Facts`, `f_*`: boost toward Fact
- DB named `Dim`, `Dims`, `dim_*`: **hint only** — verify engine is Dictionary or lookup-shaped MergeTree. Don't classify as Dim just from name.
- DB named `Mart`, `Marts`, `m_*`: boost toward Mart (if engine is View/MV/small derived MT)
- DB named `Staging`, `Stg`, `stg_*`: Staging

Wrap the output as a table:
```
(database, table, engine, role, confidence, rows, notes)
```

Confidence levels: `Confident`, `Likely`, `Other`. Nothing else. No
probabilities, no "High/Medium/Low".

## Phase 7.5 — Verification (mandatory before synthesis)

Every non-trivial fact you intend to write into the artifact passes
through this phase. Three verification mechanics for three claim types.
Capture results to a per-claim record (`verified_at`, `query_used`,
`result_summary`) and embed inline at synthesis time.

If the user declined to provide a verification tenant in Phase 2, skip
the behavior and relationship probes; mark all such claims as
`inferred from schema` and warn loudly in the README's verification log.

### 7.5a · Existence verification (cheap, run for every named identifier)

Before any table or column name lands in the artifact, confirm it
exists on this cluster. Maintain a working set of `(database, table)`
and `(database, table, column)` tuples mentioned across phases 3–7;
verify the whole set in two queries:

```sql
-- Tables: every (db, table) you plan to name
SELECT database, name
FROM system.tables
WHERE (database, name) IN (:planned_tables);
-- compare result set to :planned_tables; the difference is the drop list.

-- Columns: every (db, table, column) you plan to name
SELECT database, table, name
FROM system.columns
WHERE (database, table, name) IN (:planned_columns);
-- compare to :planned_columns; difference is the drop list.
```

**Drop, do not demote.** A non-existent referent in the KB is never
useful; the cost of leaving it in is silent breakage at consumer
query-time. If a name was load-bearing for a relationship or pattern
card, drop the card too rather than rewriting around the missing
referent.

Common sources of hallucination this catches:
- Referring to `<db>.authors` when the real author dim is named
  something else (e.g. `mstuserinformation_new`).
- Citing `<table>.createddate` when the real time column is
  `p_recorddate` / `event_date` / `_timestamp`.
- Inferring an MV target from naming convention without confirming it.

### 7.5b · Behavior verification (run per fact you make a claim about)

For every behavior claim you plan to make in the artifact (FINAL
amplifies ~Nx; primary key prunes; skip index `<name>` is used; this
filter shape is cheap), run **EXPLAIN + a real probe** and capture the
numbers.

#### EXPLAIN (claim a query shape uses the index correctly)

```sql
EXPLAIN indexes = 1
SELECT <list>
FROM <table> [FINAL]
WHERE <filter shape>;
```

Record from the EXPLAIN output:
- `granules` total vs. selected (the prune ratio, e.g. `739/836261`).
- Whether `Primary key` and any `Skip index` lines appear.
- Whether `MergeTreeInOrder` / `MergeTreeThread` is the leaf reader.

If prune is < 50% of granules, the claim "primary key prunes" is wrong
for this shape on this tenant — investigate before writing it.

#### Real probe (claim about read_rows, latency, FINAL amplification)

The probe runs on the verification tenant chosen in Phase 2. Use a
unique comment token so the row in `system.query_log` is recoverable:

```sql
/* profiler_probe_<table>_<rand_token> */
SELECT <minimal column list>
FROM <table> [FINAL]
WHERE <tenant_filter>
  AND <date_filter>
LIMIT <small N>
SETTINGS log_queries = 1;
```

Wait briefly (1–2s) for `query_log` flush, then look up the captured
record:

```sql
SELECT query_id, read_rows, read_bytes, result_rows,
       query_duration_ms, memory_usage,
       ProfileEvents['SelectedParts']    AS parts,
       ProfileEvents['SelectedRanges']   AS ranges,
       ProfileEvents['SelectedMarks']    AS marks
FROM system.query_log
WHERE event_date >= today() - 1
  AND query LIKE '%profiler_probe_<table>_<rand_token>%'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 1;
```

**MCP profile gotcha**: the MCP tool may run as a service user whose
profile defaults `log_queries = 0`. The `SETTINGS log_queries = 1`
override is required; without it the probe runs but no `query_log` row
is produced. If the lookup returns 0 rows, demote the claim to
`inferred from schema` and note the cause in the README verification
log.

Embed the captured numbers next to the claim in the artifact. Example:

> FINAL on `<table>` amplifies reads ~100x on this cluster
> (verified 2026-04-25, tenant=<id>: `read_rows=54,094,238`,
> `parts=129`, `ranges=739`, `query_id=…`).

If the probe times out, errors, or you can't recover the `query_log`
row, mark the claim `inferred from schema` and move on. Don't loop
retries.

### 7.5c · Relationship verification (cardinality probe, every JOIN claim)

For every JOIN you plan to document — declared in DDL or inferred from
column-name overlap — run the cardinality probe on the verification
tenant. **Every JOIN claim is marked `[inferred]` regardless of probe
outcome**: ClickHouse has no real FKs, and the probe answers "does this
join behave 1:1 on the captured tenant," not "is this an FK."

```sql
/* profiler_card_<left>_<right>_<rand_token> */
SELECT
  count()                                AS matched,
  uniqExact(a.<join_col>)                AS distinct_left,
  uniqExact(b.<join_col>)                AS distinct_right,
  count() / greatest(uniqExact(a.<join_col>), 1) AS avg_fanout
FROM <left> a
ANY LEFT JOIN <right> b USING (<join_col>)
WHERE a.<date_col> >= today() - 7
  AND a.<tenant_filter>
SETTINGS log_queries = 1;
```

For composite keys (multi-column join), use a tuple:

```sql
SELECT
  count()                                      AS matched,
  uniqExact((a.<col1>, a.<col2>))              AS distinct_left,
  uniqExact((b.<col1>, b.<col2>))              AS distinct_right,
  count() / greatest(uniqExact((a.<col1>, a.<col2>)), 1) AS avg_fanout
FROM <left> a
ANY LEFT JOIN <right> b
  ON a.<col1> = b.<col1>
 AND a.<col2> = b.<col2>
WHERE a.<date_col> >= today() - 7
  AND a.<tenant_filter>
SETTINGS log_queries = 1;
```

**Type coercion on the join key.** Before composing the probe, pull the
declared types from `system.columns` for both sides:

```sql
SELECT database, table, name, type
FROM system.columns
WHERE (database, table, name) IN (
  ('<left_db>', '<left_table>', '<left_col>'),
  ('<right_db>', '<right_table>', '<right_col>')
);
```

If types differ — most commonly `Nullable(String)` ↔ `String`, or
`UInt64` ↔ `String` — wrap the side that needs coercion explicitly.
The probe itself will fail with `ILLEGAL_TYPE_OF_ARGUMENT` or silently
return `matched=0` if the types are incompatible, and *that* is the
information the analyst needs in the artifact:

```sql
-- Example: a.u_authorid is Nullable(String); b.authorsocialid is String.
ANY LEFT JOIN <right> b
  ON toString(a.<col1>) = b.<col1>          -- Nullable(String) → String
 AND a.<col2>           = b.<col2>
```

Document the wrapping form in the relationship card so the analyst
copies the working shape, not a broken one. The wrap is part of the
join's identity on this cluster, not an implementation detail.

Health checks:
- `avg_fanout` ∈ [0.9, 1.5] → clean lookup-style JOIN. Document it.
- `avg_fanout` > 5 → the join key is weaker than it looks. Investigate
  whether a composite key is required (e.g. `u_authorid +
  channelgroupid` on a multi-channel author dim). If composite, redo
  the probe with the composite key.
- `matched` near zero → the inferred relationship is wrong. Drop the
  pattern card.
- Probe errors out (parser quirk, type mismatch on the join column,
  column doesn't exist) → existence check should have caught it; if
  not, drop the relationship.

Capture and embed the probe result inline in the artifact, e.g.:

> Inferred join: `mentiondetails.(u_authorid, channelgroupid) ↔
> mstuserinformation_new.(authorsocialid, authorchannelgroupid)`.
> Probe 2026-04-25 on tenant=<id>: `matched=42,293`,
> `distinct_left=42,293`, `distinct_right=42,293`, `avg_fanout=1.0`.
> `[inferred]` — re-probe on your tenant before trusting cardinality.

### 7.5d · Build the verification log

Maintain a flat list across 7.5a–c of every claim attempted, with
status:

```
existence: <db>.<table>           verified
existence: <db>.<table>.<col>     dropped (column does not exist)
behavior:  <claim text>           verified (read_rows=…, query_id=…)
behavior:  <claim text>           inferred (no log_queries row captured)
relationship: <a> ↔ <b>           verified (avg_fanout=1.0; [inferred])
relationship: <a> ↔ <b>           unverified (probe errored: …)
```

This log is emitted to README.md's "Verification log" section
(template in `templates.md`). It is the audit trail; reviewers check
it to see what was actually tested.

## Phase 8 — Synthesis (writing files)

See `templates.md` for the section templates. Write files in this order:

1. **`SKILL.md` (draft)** — author this FIRST from phase-1 discovery +
   phase-5a Pareto. This is the only file that must exist for the artifact
   to be usable at all. A run cut short after this point still produces a
   working Skill.
2. `catalog.md` — per-table cards. Authoritative detail for each
   analyst-hot table.
3. `patterns.md` — query-writing priors per hot fact.
4. `pipeline.md` — demoted tables + ingestion shape.
5. `glossary.md` — naming, users, quirks, term decoder.
6. **`SKILL.md` (polish)** — optional second pass: tighten cross-refs to
   the appendices, confirm classification labels are consistent, trim if
   over budget. Skip this step if the draft at #1 was already solid.
7. `README.md` — meta: source, decisions, limitations.

Writing SKILL.md first forces you to commit to the Pareto cut and the
cluster-name decision early. The appendices then elaborate on the same
set of facts; they can't contradict the SKILL's decisions.

### Archetype-driven content routing

Before writing `patterns.md`, load `archetypes/<primary>.md`. That
module's **Signature card** is the lead block of `patterns.md`'s
"Cluster-wide writing conventions" → "From the schema (derived)"
subsection. Non-negotiable: the bundle MUST contain the primary
archetype's signature card. The card identifies:

- **A** (Plain MergeTree): hot-column thinness table.
- **B** (Sharded OLAP): Distributed/local pairing card.
- **C** (Cube/MV warehouse): MV-chain card.
- **D** (Star + Dictionary): dictGet enrichment block.
- **E** (Streaming/Federation): external-engine warning banner.

When secondaries were detected in Phase 1.5, append each secondary's
**Engine traps** section as a sub-block under the relevant catalog
card or as a dedicated "Secondary archetype trap notes" subsection in
`patterns.md`. Do NOT duplicate the secondary's signature card —
secondaries contribute traps + corpus overrides only.

**Corpus-override merging**: before invoking
`tools/synthesize_conventions.py`, collect the union of
`Corpus-override list` entries from primary + all secondaries.
Dedup by bullet ID. Pass the merged set as `--archetypes <P>,<S1>,…`
to the helper; the helper applies suppression / replacement
deterministically.

**Inferred-relationship cards (skip-set lead)**: when the primary
archetype is in `{B, C, D}` AND an inferred-relationship card joins
a fact to a dim that has no time partition axis, the card MUST lead
with **skip-set form**:

```sql
SELECT … FROM <dim>
WHERE (k1, k2) IN (
  SELECT k1, k2 FROM <fact>
  WHERE <tenant_filter> AND <date_filter>
)
```

…not bare composite-key JOIN. Direct JOIN forces a full dim scan
when the dim has no date prune; the skip-set prunes the dim read to
the fact's matched keys (typically 3-4 orders of magnitude smaller).
The bare JOIN form may follow as an "also valid when the dim is
small" alternative, but skip-set leads.

For archetype A (plain MergeTree, often single-tenant analytics),
skip-set isn't load-bearing — bare JOIN is fine.
For archetype E primary, the inferred-relationship probe is rarely
relevant (engines are streaming or external).

### Pareto cut decision

Default: 15-25 analyst-hot tables get full detail cards in `catalog.md`.
Cutoff rule:
- If execs follow a steep curve (top 10 are 90% of execs), stop at ~10.
- If distribution is flat (top 50 cover 60%), go to 25.
- If even 25 is inadequate coverage, prefer quality: cut at 20 + warn in README that the cluster's workload is long-tail.

### Hot-column cut per table

Rule of thumb: top 10-25 columns per table covers most real queries. Cut
when touches fall below `max_touches / 20` or when you hit 25. Mention
the total column count so the reader knows how much was omitted.

### 8e — Lean pass (last step before emit)

After the 7 files are drafted but before emitting them, run a lean
pass. The bundle is a Skill consumed by an LLM that already knows
ClickHouse — restating things the consumer model already has wastes
context and dilutes the cluster-specific signal. Two concrete
checks:

**a. Drop generic ClickHouse explanations.** Re-read each file. For
each paragraph, ask: *"Does the consumer model need this
explanation, or is this generic CH the model already knows?"* Drop
or compress the 5 antipatterns (defined in `templates.md` § "What
NOT to include"):
1. CH error codes (`Code: 43`, etc.)
2. `finalizeAggregation` / `*Merge` mechanics — keep only the
   cluster's *application*, not engine internals
3. Generic FINAL semantics — keep only this cluster's collapse
   ratio, parts touched, latency tail
4. Standard archetype-trap expansions (C1–C4, B1–B5, etc.) — collapse
   to one-sentence cluster-applications + the trap ID; full prose
   stays in `archetypes/<id>.md` in the profiler skill, not the
   per-cluster bundle
5. CH version-feature explanations beyond a one-line "this cluster
   is on CH X.Y, has Z, lacks W"

Cluster-specific traps are the exception — keep their full bodies,
because the prose describes *this cluster*, not the archetype
generally.

**b. Collapse cross-file duplication to one source of truth.** For
each rule, list, or verified probe that appears in more than one
file, name one source-of-truth file (per the table in `templates.md`
§ "One source of truth") and replace the others with a
cross-reference. Common targets:
- The FINAL/anyLast rule lives in `patterns.md` once; `SKILL.md`
  and `catalog.md` cite by phrase.
- Verified probe records (`verified <date>; read_rows=…;
  query_id=…`) live once — usually in `catalog.md`'s per-table
  card. `patterns.md` cites by `query_id`.
- Full Kafka / Null / Buffer engine listings live in `pipeline.md`
  once; `patterns.md` and `SKILL.md` cite the count + a forbidden-
  to-SELECT one-liner.
- Tenant-key invariant lives in `SKILL.md` § "Critical naming"
  once; per-fact cards reference it.

Quick test: pick 2-3 of the bundle's load-bearing phrases (e.g. the
exact tenant-key tuple `(categoryid, brandid)`, the trap-Cn IDs)
and grep across the bundle. If the same phrase appears in 3+ files
in similar prose, two of them should be cross-references instead.

**c. Re-verify backticked identifiers against `system.columns`.**
Phase 7.5a verifies the model's *intent set* — the names it planned
to use, gathered from phases 3–7. Column-name typos still enter
prose at Phase 8 synthesis (the model hand-types `authorfollowercount`
when the real column is `followerscount`). The lean pass closes the
gap by re-checking the emitted markdown against the live cluster.

Procedure:

1. Across all 6 drafted files, extract every backticked identifier
   matching one of:
   - `` `<db>.<table>.<col>` `` — fully qualified.
   - `` `<table>.<col>` `` — table-qualified (resolve `<table>` via
     the bundle's database scope; if ambiguous, qualify by re-reading
     the surrounding card heading).
   - Bare `` `<col>` `` *inside a per-table card section* in
     `catalog.md` or `patterns.md` — the surrounding card heading
     names the table.

   Plain-text mentions ("the author follower count") are out of
   scope by design — this check only targets the backticked
   identifier convention the templates already enforce.

2. Build the working set of `(database, table, column)` triples
   referenced. Run the same query Phase 7.5a uses:

   ```sql
   SELECT database, table, name
   FROM system.columns
   WHERE (database, table, name) IN (:emitted_columns);
   ```

   The set difference (`emitted_columns` − query result) is the
   hard-fail list.

3. For each missed identifier:
   - Locate the offending paragraph in the bundle.
   - Re-query `system.columns` for the table to find the actual
     column name (`SELECT name FROM system.columns WHERE database
     = … AND table = …`).
   - Rewrite the paragraph with the correct name.
   - Re-scan after rewrite. Do not emit until the missed list is
     empty.

This is **hard-fail, not log-and-emit**. The whole point of the
post-synthesis pass is that hallucinated column names survive the
model's own review and only break at consumer query time.

**d. Self-check items 19, 20, and 21 in `templates.md`** verify the
result:
- item 19: every paragraph in `patterns.md` references a
  cluster-specific identifier, a probe number, or a
  cluster-application of an archetype trap. No paragraph teaches
  generic ClickHouse.
- item 20: each rule / probe / list lives in one source-of-truth
  file; others cross-reference.
- item 21: every backticked identifier in the emitted bundle was
  re-verified against `system.columns` after prose synthesis (the
  step c above closes the gap between Phase 7.5a's intent-set
  verification and prose-time typos).

The lean pass typically removes 25–35% of the draft word count
without removing any cluster-specific signal. If the cuts hit
cluster-specific content (verified probes, identifiers, trap-Cn-on-
this-cluster notes), back them out — those are not what the lean
pass targets.

## Catalog-only fallback (phase 5 empty)

If `count()` on query_log is zero, or if the mined window returns no
business-query rows:

- Skip phase 5 entirely.
- In phase 6, no demotion data — mark all Kafka/Null/Buffer/MV engines
  as pipeline; everything else stays analyst-hot.
- In phase 7, classify by engine only; no hot-column enrichment.
- Phase 8: write `patterns.md` with one paragraph explaining that
  patterns are inferred from schema only.
- In README.md, flag: "no analyst workload observed in query log" and
  explain what that limits.

This is the prism-cluster case (157 execs, all audit scanner).

## Audit-corpus profiling (variant mode)

When profiling an `audit_*` snapshot instead of a live cluster (test mode
during profiler development), you can connect to the `support` cluster
and target any audit DB:

```
Prefix table references with the audit DB name:
  system.tables           → <audit_db>.tables_raw
  system.columns          → <audit_db>.columns_raw
  system.parts            → <audit_db>.parts_raw
  system.dictionaries     → <audit_db>.dictionaries (may be empty!)
  system.query_log        → <audit_db>.query_log_24h (or .query_log)
  system.build_options    → <audit_db>.build_options
  system.clusters         → <audit_db>.clusters
```

The query_log is pre-aggregated (`any(...)` column wrappers + `count()` /
`sum(query_duration_ms)`). Use the pre-aggregated SQL templates.

## SSL/transient retry pattern (harness-level)

When the MCP tool reports `NETWORK_ERROR`, `Connection reset`, `SSL
connection unexpectedly closed`, or similar transient errors:

1. Wait a short backoff (2-5 seconds).
2. Retry the exact same query once.
3. If it fails again: check connectivity with a simple `SELECT 1`.
4. If that fails: wait 10-15s and check again.
5. If still failing after ~60s total: abort and tell the user.

For bash wrappers (test mode): `until cc support -q "SELECT 1" 2>/dev/null; do sleep 5; done`.

Do not try to switch connection paths. Do not silently skip queries.

## Query size and time bounds

When running phase-5 mining on very large query logs:

- If `system.query_log` estimated scan > 50 GiB, add `SAMPLE 0.1`.
- If the log spans > 30 days, narrow to `event_date >= today() - 7` by default.
- If `sys.query_log` has > 1B rows, use `event_time >= now() - INTERVAL 24 HOUR`.

Document the mining window in the artifact's frontmatter (`mined_window`).
Narrow windows mean narrower Pareto (weekly/monthly batch queries
missed); state this explicitly in README.md.

## SQL-template quick reference

| Phase | Query | Raw | Pre-aggregated |
|---|---|---|---|
| 0a | Version | `SELECT version()` | same |
| 0b | Shape | `DESCRIBE system.query_log` | same |
| 0c | Dist pairs | `engine_full` parse | same |
| 0d | Kafka count | `engine='Kafka'` | same |
| 1a | Topology | `system.clusters` | same |
| 1b | Roster | `GROUP BY database` | same |
| 1c | Log span | `min/max event_date` | `min/max `any(event_date)`` |
| 1d | Engine mix | `GROUP BY engine` | same |
| 5a | Hot tables | `ARRAY JOIN tables` + `count()` | `ARRAY JOIN ``any(tables)``` + `sum(`count()`)` |
| 5b | Co-occur | `arraySort(arrayFilter(...,tables))` | `arraySort(arrayFilter(...,`any(tables)`))` |
| 5c | Hot cols | Nested `arrayJoin` | Same, with wrapped names |
| 5d | Reps | `argMax(normalizeQuery(...))` | `normalizeQuery(`any(query)`)` |
