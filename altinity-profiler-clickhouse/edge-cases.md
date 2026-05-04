# clickhouse-profiler · edge-case library

Gotchas observed across six worked examples. Consult when you hit
something unexpected; scan once at the start of profiling if the cluster
shape feels unusual.

> All worked examples in this file are illustrative — none of the
> profiler logic depends on these clusters existing. The patterns
> generalize; the cluster names are pinned only to make the symptom
> recognizable when re-encountered.

Organized by where in the pipeline the edge case bites.

## Phase 0 · Shape detection

### `system.tables.as_select` column missing (CH < 22)
**Symptom**: `SELECT as_select FROM system.tables` returns `Unknown
expression or function identifier 'as_select'`.

**Handling**: use `create_table_query` and regex-extract the AS SELECT
body: `AS\s+SELECT\s+([\s\S]+)$`. For View/MV `TO` target, parse
`CREATE (MATERIALIZED )?VIEW .* TO (\w+\.\w+) AS SELECT .*` — or just
`engine_full` which on MVs contains the TO clause.

Clusters affected: `exads` (CH 21.8).

### Column names wrapped as `any(...)` in query_log
**Symptom**: `SELECT tables FROM system.query_log` returns "Unknown
column `tables`" but `DESCRIBE system.query_log` shows `any(tables)
Array(String)`.

**Handling**: this is pre-aggregated-by-normalized_query_hash query_log
(audit corpus format; some production setups do this too). Use the
pre-aggregated SQL templates from `pipeline.md`:

- Wrap column names in backticks: `` `any(tables)` ``, `` `any(type)` ``.
- Aggregates for count/duration: `` `count()` ``, `` `sum(query_duration_ms)` ``.
- `ARRAY JOIN `any(tables)` AS t`.

Clusters affected: all audit snapshots; some production clusters with
custom query_log materialization.

### `engine_full` codec bug on CH 23.x
**Symptom**: `SELECT engine_full FROM system.tables` (or combined with other
columns) fails with `readData: block decode for exception: unexpected
value 111 for boolean`. Querying the same rows without `engine_full` works.

**Cause**: a Nullable(Bool) / enum-ish value inside the engine_full
formatter's block payload deserializes incorrectly on some 23.x builds
(seen on 23.8.16.43.altinitystable). It is a server-side bug, not a query
bug. Retries don't help.

**Handling**: drop `engine_full` from the SELECT and substitute
`substring(create_table_query, 1, N)` (N ≈ 400–600). Every piece of
information `engine_full` carries is also in `create_table_query`:

- MV `TO` target: regex `TO\s+([a-zA-Z0-9_.]+)` on the DDL.
- Kafka settings: `extract(create_table_query, 'kafka_topic_list = ''([^'']+)''')`,
  same shape for `kafka_group_name`, `kafka_broker_list`, `kafka_format`.
- Distributed pair: `extract(create_table_query, 'Distributed\\([^)]+\\)')`
  then split on commas.
- `ReplicatedMergeTree` ZK path: `extract(create_table_query, 'ReplicatedMergeTree\\(''([^'']+)''')`.

Do not loop retries. Move on.

Clusters affected: `locobuzz2` (CH 23.8.16.43.altinitystable, first
observation).

### Generic cluster macros (`default`, `all-*`, `clickhouse`)
**Symptom**: `SELECT cluster FROM system.clusters` returns only names
like `default`, `all-replicated`, `all-sharded`, `test_*`,
`parallel_replicas`, `clickhouse`, `prod`, `local` — none identify the
business.

**Handling**: fall back through the name chain:
1. Kafka broker hostname from Kafka engines' `engine_full`.
2. Dominant business-database name.
3. Dominant table-name prefix.
4. ZooKeeper path prefix from Replicated engines' `engine_full`:
   `/clickhouse/tables/<cluster-id>/...` — if `<cluster-id>` is literal
   (not `{shard}`), use it.
5. Ask the user.

Clusters affected: `razorpay-payments` (only `clickhouse`); `hockeystack`
(only operational macros).

## Phase 3 · Catalog

### `loading_dependencies_*` sparsely populated
**Symptom**: almost all rows in `system.tables` have empty
`loading_dependencies_*` even for MVs that clearly depend on source
tables.

**Handling**: use `dependencies_*` (the older columns) + regex-extract
`FROM\s+(?:(\w+)\.)?(\w+)` and `JOIN\s+(?:(\w+)\.)?(\w+)` from `as_select`
or `create_table_query`.

Clusters affected: `betpawa` (CH 22.12 — 8/564 populated), `tdw-prod`
(CH 22.3 — 0/564 populated), `exads` (CH 21.8 — 0/119).

### `system.dictionaries` empty despite Dictionary engines
**Symptom**: `SELECT count() FROM system.dictionaries` returns 0 but
`SELECT count() FROM system.tables WHERE engine='Dictionary'` returns
N > 0.

**Handling**: enumerate from `system.tables.engine='Dictionary'` and
regex the DDL from `create_table_query`:
```
CREATE DICTIONARY <name> (
  col1 Type1 [DEFAULT ...],
  ...
)
PRIMARY KEY <key-expr>
SOURCE(<type>(...))
LAYOUT(<layout>(...))
LIFETIME(<lifetime>)
```
Extract: attribute list, primary key, source, layout.

Also note in the artifact: "Dictionary runtime state not observed
(system.dictionaries empty at profile time). Attributes inferred from
DDL; run `DESCRIBE dictionaries.<name>` at query time for current state."

Clusters affected: `exads` (CH 21.8).

### MaterializedView `TO` target is a Distributed
**Symptom**: MV's `engine_full` shows `TO default.payments` but
`default.payments` is a `Distributed` engine, not a storage table.

**Handling**: follow the chain. Parse the Distributed's `engine_full`:
`Distributed('<cluster>', '<db>', '<local>', <shard_key>)`. The
`<local>` is the actual storage table. If `<local>` is ALSO a
Distributed, recurse (rare).

Resolution chain: `MV.TO → Distributed.engine_full(remote_table) → _local`.

Clusters affected: `razorpay-payments` (MVs write to Distributed fronts,
not directly to `_local`).

### MV uses inline storage (`.inner.mv_*` or `.inner_id.<uuid>`)
**Symptom**: Tables named `\`.inner.mv_X\`` (CH < 23) or
`\`.inner_id.<uuid>\`` (CH ≥ 23) appear in `system.tables` with
`engine = *MergeTree` but they're not the analyst-facing name. They
co-occur with the wrapping View `X` or MV `mv_X` in query_log's
`tables` array.

**Handling**:
- Don't list as separate analyst-hot entries.
- In Phase 5 co-occurrence, strip pairs of `(X, .inner.mv_X)` — they're
  view-to-storage resolution, not joins.
- In `pipeline.md`, note the convention: `.inner.*` is the underlying
  storage; query the wrapping name.

Clusters affected: `exads` (CH 21.8, `.inner.mv_*`).

## Phase 4 · Relations

### `Dim.*` database but NOT Dictionary engine
**Symptom**: DB named `Dim` holds tables with
`ReplicatedReplacingMergeTree` engine (or plain MergeTree). These look
like dimensions by name but aren't Dictionaries.

**Handling**: classify by engine. The tables are Replacing-MT facts
(often polymorphic property stores like `key, attribute, value,
version`). Query via `argMax + HAVING NOT argMax(is_deleted, version)`
idiom, NOT `dictGet`.

Clusters affected: `hockeystack` (`Dim.PropertiesValue` etc. as 531B-row
Replacing table with `(added_at, is_deleted)` version-and-tombstone
signature).

### Polymorphic property store pattern
**Symptom**: a table with columns like `(account_id, property_type,
property_name, property_value, version, is_deleted)` — each row is one
property assignment; the table holds attributes for many objects.

**Handling**: document as a first-class pattern in `patterns.md`. The
idiom is:
```sql
SELECT account_id,
       argMax(property_value, version) AS current_value
FROM Dim.PropertiesValue
WHERE account_id = <id>
  AND property_name = '<name>'
GROUP BY account_id
HAVING NOT argMax(is_deleted, version)
```

Clusters affected: `hockeystack`.

## Phase 5 · Query mining

### `ARRAY JOIN` with two arrays of different length fails
**Symptom**: `ARRAY JOIN tables, columns` returns
`SIZES_OF_ARRAYS_DONT_MATCH`.

**Handling**: use a subquery with separate `arrayJoin` calls (cross
product, then filter):
```sql
SELECT t, col, sum(execs) AS touches
FROM (
  SELECT arrayJoin(tables) AS t,
         arrayJoin(columns) AS col,
         1 AS execs
  FROM system.query_log
  WHERE type = 'QueryFinish'
)
WHERE t IN (:pareto) AND startsWith(col, concat(t, '.'))
GROUP BY t, col;
```
Keep the `startsWith` filter to drop spurious cross-product rows.

### Thin query log — audit-scanner-only workload
**Symptom**: query log has < 100 distinct normalized_query_hashes and/or
queries only come from user `default` or similar.

**Handling**: catalog-only fallback. Skip Phase 5 hot-column mining.
In `patterns.md` prominently state: "patterns inferred from schema; no
observed analyst workload in the mined window." In `README.md`, flag
this as a limitation.

Clusters affected: `prism-cluster` (157 execs, all audit scanner).

### Generic `valN` measurement columns
**Symptom**: fact tables have 100+ columns named `val1`, `val2`, ...,
`val109`. The query log shows analysts touch many of these slots, but
no naming convention reveals which physical quantity each slot holds.

**Handling**: surface in glossary as a known pattern — the mapping
lives outside ClickHouse (in the upstream application's metadata). In
per-table catalog card, list the top-N `valN` touched but note that
meaning is not in the schema. Pattern card in `patterns.md` advises
users to ask the domain owner which `valN` maps to which quantity.

Clusters affected: `tdw-prod` (fab metrology: `cdsem.val1..val109`,
`defect.val1..val37`).

### Ultra-wide tables (> 100 columns)
**Symptom**: tables with 200-1000 columns — `tlm.xian_ees_run_data`
has 997; `met.cdsem` has 545. DESCRIBE-ing them in the artifact would
blow the token budget.

**Handling**: list only hot columns (top 15-30 by touches) + state
total column count. Pattern card advises `DESCRIBE` at query time for
the full column list. Never try to enumerate all columns in the
catalog.

Clusters affected: `tdw-prod`.

## Phase 6 · Demotion

### `_test` siblings with real traffic
**Symptom**: tables matching `<base>_test_v<n>` appear in the Pareto
with exec counts rivaling or exceeding the non-test sibling
(`<base>_v<n>` / bare `<base>`).

**Handling**: do NOT auto-demote on `_test` suffix. This is a
shadow-traffic / A-B test pattern. Keep the test variant analyst-hot and
document the sibling pair in `pipeline.md` so analysts understand the
situation.

Clusters affected: `razorpay-payments` (`payments_test_v3` had 15k
execs vs `payments_v4` at 18).

### Per-tenant cache fleets
**Symptom**: a business DB has hundreds of tables with the same naming
pattern: `temp_actions_identity_joined_<tenant_hash>_*` or
`materialized_view_<hash>_<hash>_<slug>`. They co-occur with a hot fact
and are written+read by the same user.

**Handling**: detection rule — ≥ 30% of a business DB's tables share a
common per-tenant hash infix matching a hot fact's sort-key-leader.
Summarize as a cache pattern (one section describing the pattern), do
NOT enumerate individual tenant copies.

Clusters affected: `hockeystack` (462/517 tables are per-tenant caches).

### Shadow / prefixed parallel pipeline
**Symptom**: the business DB contains a set of tables, MVs, and Kafka
engines that mirror the main chain table-by-table under a shared name
prefix. For example the main chain is
`kafkafinalqueue → mv_mentiondetails → mentiondetails`
and a second chain exists as
`mitresearch_kafkafinalqueue → mv_mitresearch_mentiondetails → mitresearch_mentiondetails`.
Same schema, same sort-key shape, but a different Kafka topic and
(usually) much smaller row counts.

Detection rule (apply after Phase 3d has resolved MV TO-targets):

- Collect the set of `(kafka_topic, mv_name, target_table)` triples.
- Group by a common prefix stripped from `mv_name` and `target_table`
  (`<prefix>_<core>`).
- If ≥ 2 triples share the same `<core>` (e.g. `mentiondetails`,
  `kafkafinalqueue`) with one empty prefix and one non-empty prefix,
  it's a shadow pipeline.

**Handling**:

- Keep **both** targets as analyst-hot cards in `catalog.md`; they are
  distinct tables with potentially distinct data.
- In `pipeline.md`, show them as sibling rows in the Kafka→MV→target
  table. Add a short note: "<prefix> is a parallel pipeline
  (research / sub-tenant / staging). Confirm scope before treating its
  data as equivalent to the main target."
- In `SKILL.md` "When to use X vs Y", include a one-liner on the
  shadow/main pair.
- Do NOT merge them under one card; that hides the fact that one is
  sub-scope.
- Do NOT demote the shadow chain as "staging" just because it is
  smaller — shadow pipelines are often production-critical for a
  sub-product.

Clusters affected: `locobuzz2` (`mitresearch_*` mirror of the main
mentions chain; 1.58M rows vs 647M on the main).

### Dual-fed tables (MV + external INSERT)
**Symptom**: a `_local` table receives inserts from BOTH the MV
pipeline AND external HTTP clients. Insert/select ratio is ambiguous.

**Handling**: flag in `pipeline.md`. Don't demote — the table is the
consumer of valid data from two paths. Document both insertion paths
so analysts know the data provenance.

Clusters affected: `razorpay-payments` (29 dual-fed tables).

### Buffer engine in front of a fact
**Symptom**: `Buffer('<db>', '<fact>', <N shards>, <flush_seconds>,
...)` table alongside the main fact table.

**Handling**: not analyst-hot — inserts go here, then flush to the
main fact. Reads from the Buffer return buffered+underlying rows
(with brief inconsistency). Document in `pipeline.md`; analyst surface
is the main fact.

Clusters affected: `hockeystack` (`actions_buffer` in front of `actions`).

## Phase 7 · Classification

### Fact-shaped tables under non-Fact DBs
**Symptom**: a `Replicated*MergeTree` table with timestamp column and
1B+ rows lives in `default` (not `Fact.*`, not `Mart.*`).

**Handling**: classify by engine + shape, ignore DB naming. This is
Fact, Confident. Don't demote just because it's not under a
Fact-named DB.

Clusters affected: `razorpay-payments` (one `default` DB, all facts
there), `hockeystack` (`hockeystack.actions`).

### Single-shard cluster with no Distributed engines
**Symptom**: `SELECT count() FROM system.tables WHERE engine='Distributed'`
returns 0, even on a multi-node cluster (replicas, not shards).

**Handling**: no Distributed-local pairing section needed. Skill omits
the "query this for cluster-wide reads" idiom. Document topology in
`SKILL.md` as "single-shard, replicated".

Clusters affected: `hockeystack` (single-shard).

### `rand()` shard key on Distributed tables
**Symptom**: Distributed's `engine_full` ends with `..., rand())`.

**Handling**: reads ALWAYS broadcast. Document in `patterns.md`: no
filter-based shard pruning; every query touches all shards. If the
user asks about sharding optimization, there is none — the shard key
is random.

Clusters affected: `exads`, parts of `razorpay-payments`,
`nseAccountCountryToTrafficRand` in `prism-cluster`.

### Hourly partition scheme with exploding partition count
**Symptom**: `PARTITION BY toYYYYMMDDhhmmss(toStartOfHour(date_time))`
— creates one partition per hour. A week-long query touches 168
partitions per shard.

**Handling**: surface as a gotcha in `glossary.md` and in the raw-fact
table's catalog card. Pattern cards must emphasize tight time windows.

Clusters affected: `exads` (raw `events` table).

### Short TTL on target tables
**Symptom**: `TTL <time_col> + toIntervalDay(<1..3>)` or similar — data
lives briefly.

**Handling**: pattern examples in `patterns.md` should default to
narrow windows (1 day or shorter). Document the TTLs in the catalog
card so users know the retention.

Clusters affected: `razorpay-payments` (1-91 day TTLs on various).

## Phase 8 · Synthesis

### Cluster has only one business database
**Symptom**: all business data lives in `default` (razorpay) or one
named DB (prism's `divinity`). The SKILL.md "Databases" section is
trivial.

**Handling**: collapse the Databases section to a one-liner. Organize
by suffix/role instead (e.g., "Tables are grouped by suffix: `_local`
= shard storage, `_test_v<n>` = shadow-traffic sibling, etc."). Avoid
making a useless `| DB | tables | role |` table with one row.

### Cluster has dramatic schema drift between audits
**Symptom** (relevant during re-profiling): the fingerprint changed
significantly since the last run.

**Handling**: in `README.md`, add a "Since last run" section listing
new/removed tables, engine changes, and workload shifts. If the change
is minor (table count within 5%, no engine changes), note the
fingerprint bump but don't overstate.

### User asks for "just a quick profile"
**Symptom**: user wants a minimal artifact, not the full 5-10k words.

**Handling**: offer two size targets in the questionnaire (Phase 2).
"Concise" (~5k words): top-10 Pareto, minimal `pipeline.md`, skip
heavy engine cheat sheet if only 1-2 engines present. "Full" (~10k):
default. Honor the choice.

## General

### Target cluster has custom functions / SQL extensions
**Symptom**: query log has function names that aren't standard
ClickHouse (`customExtract(...)`, `tenantLookup(...)`).

**Handling**: note in `glossary.md` term decoder. Don't try to document
the function's behavior — defer to the cluster owner. Just flag that
it's cluster-specific.

### Target cluster has user-defined functions (UDFs)
**Symptom**: `SELECT * FROM system.functions WHERE origin != 'System'`
returns rows.

**Handling**: list them in `glossary.md`. Each row is `(name,
definition summary)`. Keep this short.

### MCP tool times out on large query_log scans
**Symptom**: Phase 5 queries consistently fail on timeout for a large
query_log.

**Handling**:
- Add `SAMPLE 0.1` to mining queries.
- Narrow the mining window to `event_date >= today() - 7`.
- Document the sampling in `mined_window` frontmatter.
- Expect slightly fuzzier Pareto at the margin; the top 15 tables are
  usually stable.

### Target cluster is CH Cloud (limited system access)
**Symptom**: some system tables return "access denied" or are
restricted.

**Handling**: adapt queries to use only permitted system tables. If
`system.query_log` is unavailable, fall back to catalog-only mode.
Document what couldn't be observed in `README.md`.

### Cluster has projections (CH ≥ 21.10)
**Symptom**: `system.tables` has rows where `engine` is normal
MergeTree but the table uses projections for query acceleration.

**Handling (CH ≥ 24)**: `system.projections` is available. List
projections directly:
```sql
SELECT database, table, name, type, granularity
FROM system.projections
WHERE database IN (:included);
```

**Handling (CH < 24, including CH 23.8)**: `system.projections` does not
exist (`UNKNOWN_TABLE`). Two fallbacks:

1. Per-part projection rows:
   ```sql
   SELECT database, table, name, count() AS parts
   FROM system.projection_parts
   WHERE database IN (:included)
   GROUP BY database, table, name;
   ```
   (`system.projection_parts` exists on 21.10+.)

2. If the above is also unavailable or empty, regex-extract from
   `create_table_query`:
   ```sql
   SELECT database, name,
          extractAll(create_table_query, 'PROJECTION\\s+([a-zA-Z0-9_]+)\\s*\\(') AS projections
   FROM system.tables
   WHERE database IN (:included)
     AND create_table_query ILIKE '%PROJECTION%';
   ```

If neither signal is present, state "no projections detected" in the
catalog card — do not claim projections are absent without checking.
Note the projection in the table's card. Pattern cards can note when
a projection would auto-trigger (CH optimizer picks them per query).

Clusters affected: `locobuzz2` (CH 23.8, `system.projections` missing;
regex fallback confirmed no projections present).
