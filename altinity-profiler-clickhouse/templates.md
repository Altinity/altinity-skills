# clickhouse-profiler · output templates

Section-by-section templates for the 6 files in the emitted
`<cluster>-analyst/` artifact. Load this at Phase 8 (synthesis).

Write files in this order: **`SKILL.md` (draft) → `catalog.md` → `patterns.md`
→ `pipeline.md` → `glossary.md` → `SKILL.md` (polish if time) → `README.md`**.

Rationale: SKILL.md is the one file that must exist for the artifact to be
useful at all. Writing it first — based on phase-1 discovery and the
phase-5a Pareto — guarantees a usable result even if a long run gets cut
short. The top-tables table comes straight from phase-5a; engine idioms
from phase-1d; ingestion shape from phase-0c + phase-5f. The appendices
fill detail, not breadth. Return to SKILL.md after the appendices only to
tighten cross-references and confirm classification labels are consistent.

## What NOT to include in the bundle

The bundle ships to a consumer model that already knows ClickHouse. Per
Anthropic's Skill best-practices: *"Default assumption: Claude is
already very smart. Only add context Claude doesn't already have.
Challenge each piece of information: 'Does Claude really need this
explanation?'"* The 5 antipatterns below are the most common forms of
generic-CH bloat — strip each pass before emitting a file:

1. **CH error codes.** No `Code: 43 ILLEGAL_TYPE_OF_ARGUMENT`-style
   error-code prose. State the rule (`finalizeAggregation` is wrong on
   a `SimpleAggregateFunction` column on this cluster) without
   reproducing the engine's error message.
2. **Aggregate-function internals.** No `finalizeAggregation` /
   `*Merge` / state-vs-resolved-value mechanics. Document only the
   cluster's *application* — which columns are state-storing, which
   the analyst reads with `FINAL`, and the verified read cost.
3. **Generic FINAL semantics.** Assume the consumer model knows what
   `FINAL` does. Document only how *this cluster*'s FINAL behaves —
   the merge-bucket collapse ratio, parts touched on a representative
   read, the latency tail. Never the textbook explanation.
4. **Standard archetype-trap expansions.** Trap IDs (e.g. trap-C1,
   trap-B3, trap-D2) appear in the bundle as one-sentence
   cluster-applications, not full prose. Full trap explanations live
   in the profiler's `archetypes/<id>.md` modules. Cluster-specific
   traps (e.g. locobuzz2's trap-C5: legacy `.inner.<name>` MV naming
   on this cluster) are the exception — those keep their full body
   because they describe *this cluster*, not the archetype generally.
5. **CH version-feature explanations.** Beyond a single line stating
   the CH version and the one or two notable features it has or
   lacks, do not document version differences — the consumer model
   already knows the CH release notes.

These antipatterns are enforced by self-check items 19 and 20 below.

## One source of truth — cross-reference, do not restate

Files other than `SKILL.md` are loaded **lazily** by the consumer
model — they enter context only when read. Restating the same rule in
3 files is wasteful only when multiple files happen to load, but
that's exactly the common analyst-question case (`patterns.md` plus
`catalog.md`, or `SKILL.md` plus `pipeline.md`). The contract: each
rule, list, and verified probe lives in one source-of-truth file;
others cross-reference. Default homes:

| Content | Source-of-truth file | Cross-referenced from |
|---|---|---|
| Per-fact engine rules (FINAL, anyLast, partition prune) | `patterns.md` | `SKILL.md`, `catalog.md` |
| Verified probe records (`read_rows`, `query_id`) | `catalog.md` (per-table) | `patterns.md` (cite by `query_id`) |
| Full Kafka / Null / Buffer engine listings | `pipeline.md` (demoted infra) | `patterns.md`, `SKILL.md` |
| Inferred-relationship cards w/ cardinality probes | `patterns.md` | `catalog.md` (cite) |
| Tenant-key invariant (e.g. `(categoryid, brandid)`) | `SKILL.md` (Critical naming) | `patterns.md`, `catalog.md` (one-line refs) |
| Trap IDs (C1..C6, B1..B5, etc.) — full prose | `archetypes/<id>.md` (in profiler skill) | bundle files cite the ID + one-line cluster-application |

When in doubt: pick the file whose primary purpose covers the content,
state it once in full, and have the others link to it.

## Frontmatter (SKILL.md only)

```yaml
---
name: <cluster>-analyst
description: |
  <2-4 sentences.
  Sentence 1: what cluster / what workload ("gambling analytics",
                                            "fintech payments telemetry").
  Sentence 2: what databases are covered.
  Sentence 3: when to load this Skill — explicit trigger phrases.>
cluster_fingerprint: ch-<version> / cluster=<macro> / schema-hash-<hash16>
generated_at: <YYYY-MM-DD>
mined_window: <N>d · <execs> executions · <hashes> normalized queries
verification_tenant: <tenant_id_or_"none">
verification_summary: <N>/<M> claims verified · <K> demoted to inferred · <D> dropped
profiler_version: 0.4
---
```

`cluster_fingerprint` components:
- CH version (from build_options)
- Primary cluster macro
- 16-char hash of `cityHash64(groupArray((database, name, engine, partition_key, sorting_key)))` over business tables

`description` is the **most important** field — claude.ai uses it to
decide when to load this Skill. Make it specific: name the cluster, the
primary databases, one or two signature domain terms.

## SKILL.md structure

```markdown
---
<frontmatter>
---

## Cluster at a glance
<3-6 bulleted lines>
- **Workload**: <domain name + 1-sentence description>.
- **ClickHouse <version>**, <topology>.
- **Business databases**: <count + list of names>.
- **Engine mix** (business tables only): <top-5 with counts>.
- **User sandboxes skipped**: <list-if-any>.

## Critical naming convention — read first  [OPTIONAL]
<Include only if cluster has non-standard naming.>
<Explain the convention explicitly with a table showing the pattern.>
<Example conventions seen:
- `_d` suffix (bare = local, `_d` = Distributed)
- `_local` suffix (bare = Distributed, `_local` = local)
- `dist_` prefix
- `.inner.mv_*` auto-naming (CH<23 MV inline storage)
- 4-tier View/MV/.inner/Distributed chain
- Multi-tenant `net_<hash>_*` per-tenant dicts>

## How data flows (ingestion shape)  [REQUIRED if Kafka/MV/Null/Buffer present]
<ASCII diagram from upstream to analyst surface.>
<Short prose paragraph explaining.>

## Databases
| DB | Tables | Role |
|---|---:|---|
| `<name>` | <N> | <1-sentence role> |
...

## Analyst-hot tables (top <N>) — see `catalog.md` for details
| Table (query this) | Engine family | Rows | Partition / sort | Role |
|---|---|---:|---|---|
| `<full.name>` | <ReplReplacingMT etc.> | ~<X>B | <partition> / <sort> | Fact, Confident |
...

## Join map  [OPTIONAL if single-table workload]
<Empirical, from query-log co-occurrence. After stripping pseudo-joins.>
<ASCII/bullet-list showing which tables connect and on what key.>

## Engine idioms (only engines in this cluster)
<Routing block — content is loaded from `archetypes/<primary>.md`.
Phase 1.5 picked the primary archetype letter (A/B/C/D/E) and any
secondaries. The primary archetype's "Signature card" is the lead.
Each secondary archetype contributes its "Engine traps" block,
appended as sub-sections. Do NOT render a generic engine list here —
use the archetype module's vocabulary.>

<Concrete shape per archetype:>
- **A** (Plain MergeTree): hot-column thinness table; cold-table
  reminder; minimal engine notes (one line per engine present).
- **B** (Sharded OLAP): Distributed/local pairing card; ReplacingMT
  dedup idioms (FINAL vs argMax-on-version vs GROUP BY).
- **C** (Cube/MV warehouse): MV-chain card; AggMT/SummingMT idioms;
  `anyLast` over `FINAL`, NOT `argMax(col, ts)` on
  `SimpleAggregateFunction(anyLast, …)` columns.
- **D** (Star + Dictionary): dictGet enrichment block; Dim/Fact/Mart
  high-confidence labels; multi-tenant per-network dict pattern.
- **E** (Streaming/Federation): external-engine warning banner;
  Kafka NEVER-SELECT; Null landing pad note; remote-read cost.

<Concrete example, archetype B:>
**ReplicatedVersionedCollapsingMergeTree** (Fact.BetSlip):
aggregate as `SUM(sign * col)`. Never `SUM(col)` — double-counts
uncollapsed rows. Use `FINAL` only for small result sets.

<Secondary trap notes — append only when Phase 1.5 detected
secondaries. Title each block "Secondary archetype trap notes:
<letter>" and pull only the **Engine traps** section from the
secondary archetype module.>

## When to use X vs Y  [OPTIONAL]
<When multiple near-identical tables exist (cubes, test/live siblings).>

## Query-writing priors — see `patterns.md`
<1-line pointer>

## Pipeline / infra — see `pipeline.md`
<1-line pointer listing demoted categories by role, not by name>

## Glossary — see `glossary.md`
<1-line pointer>

## Cold tables — use DESCRIBE first
<Reminder that long-tail tables only appear in catalog.md by name+engine;
`DESCRIBE <table>` is mandatory before writing SQL for them.>

## Staleness
<Required. When to regenerate; when NOT to.>
```

## catalog.md structure

```markdown
# <cluster>-analyst · catalog

<Opening paragraph: what this file is + note on hot-column source +
note on verification — every named table/column was confirmed in
`system.tables`/`system.columns` at profile time.>

---

## <full.table.name>  [Role, Confidence]

- **Engine**: `<engine_full truncated if long>`
- **Rows**: ~<X>
- **Partition**: `<expr>`
- **Sorting key**: `<list>` · **Primary key**: `<list>`
- **Merge tuning** (optional): `<unusual settings>`
- **Existence verified**: `<YYYY-MM-DD>` (every column listed below
  appeared in `system.columns` at profile time)

**Hot columns** (of <total> total):
`<col1>` (<touches>), `<col2>` (<touches>), ...
<If query log thin: "Hot columns not mined (thin query log). Key columns: <partition + sort>.">

**Aggregation rule**: <per-engine>
<Example: "VersionedCollapsing. Always `SUM(sign * col)`. Never `SUM(col)`.">

**Read-cost note** (verified, optional): <FINAL amplification, primary
key prune, skip index usage with captured numbers>

  Example:
  > FINAL on this table amplifies reads ~100x on the captured tenant.
  > A 7-day tenant slice reads ~54M rows
  > (verified 2026-04-25, tenant=<id>: `read_rows=54,094,238`,
  > `parts=129`, `ranges=739`, `query_id=…`,
  > `granules_prune=739/836,261`).

  If the probe could not run: `inferred from schema: <reason>`.

**Gotcha** (optional): <anti-pattern>
**Typical filter** (optional): <1 line>
**Enrichment**: <dictGet `[declared]`, or JOIN with `[inferred]` marker
+ link to the relationship card>

---

<Repeat per analyst-hot table.>

## Dim.* — Dictionaries  [OPTIONAL — only if cluster has Dictionaries]

| Dictionary | Type | Source | Rows | Key attributes |
|---|---|---|---:|---|
| `<name>` | <Flat/Hashed/Cache/...> | <MySQL/ClickHouse/...> | <N> | <attr list> |
...

**Lookup idiom**: `dictGet('<name>', 'attr', key)` — NOT JOIN.

<If system.dictionaries was empty at profile time, add the caveat.>

## Cold tables

<Short list of remaining tables as name+engine, OR a query suggestion:>

For any table not above, run:
  DESCRIBE <db>.<table>
  SHOW CREATE TABLE <db>.<table>
```

## patterns.md structure

This file is a **knowledge base**, not a recipe book. Each card states
the engine-level facts a competent analyst needs to compose correct SQL
on a given fact table — time column, measures, dimensions, enrichment
shape, declared vs. inferred relationships. Do **not** prescribe SQL
shapes for question classes. The analyst writes its own queries.

```markdown
# <cluster>-analyst · fact knowledge cards

**Per-fact knowledge: what an analyst needs to know to write correct SQL
against each analyst-hot fact on this cluster.** Priors, not recipes.

## Cluster-wide writing conventions

Two kinds of conventions belong here, and the distinction matters:

- **From the corpus (mined)** — form-level conventions derived from
  query-log mining in `pipeline.md §5d.1`. Each bullet **must** cite
  an observed ratio. If a form is roughly evenly split, **omit the
  bullet** — silence is the default. The exception: if the analyst
  would naturally *expect* a convention on this axis (e.g. PREWHERE
  on a tenant-leading sort key) and the corpus shows none, write
  `no dominant form-level convention observed for <axis>` so the
  analyst doesn't assume one.
- **From the schema (derived)** — structural conventions that follow
  from engine choices, partitioning, naming layout. These cannot have
  ratios because they aren't behavioral — they are structural. Phrase
  them as imperatives.

### From the corpus (mined)

<Generated from Phase 5d.1 by `tools/synthesize_conventions.py`.>

Examples:

- **Filter form**: `PREWHERE` the tenant + date filters (observed in
  ~`<X>%` of hot queries on `<top_fact>`; the optimizer often hoists
  from `WHERE`, but the explicit form is the cluster idiom and easier
  to read).
- **Latest-row idiom on AggMT**: `anyLast(col)` over `FINAL`, not
  `argMax(col, ts)` (observed in ~`<X>%` of AggMT-touching queries;
  the engine stores `SimpleAggregateFunction(anyLast, …)` so
  `anyLast` is the engine-native path).
- **Daily bucket**: `toDate(<time_col>)`, not `toStartOfDay()`
  (observed in ~`<X>%` of daily aggregations).
- **Counting**: `count()`, not `sum(1)` (observed in ~`<X>%`).
- **Wide projections**: `SELECT *` appears in only ~`<X>%` of hot
  queries — name columns explicitly.

### From the schema (derived)

- Always query `<dist_name>` for analytics; bare name is single-shard.
- Use `dictGet`, not JOIN, on Dictionary engines.
- Every query must include `<tenant_col> = <tenant_id>` (load-bearing
  on the primary index).
- No Distributed engine — single-shard, no fan-out.

## Fact: `<full.table.name>`

**Engine**: `<engine_family>` — read with `<FINAL | argMax | sum(sign*col)>`.

- **Time axis**: `<col>` (partition: `<expr>`). `<col>` is the
  load-bearing filter — without it, FINAL/scan reads the whole table.
- **Tenant axis** (if applicable): `<col>` is the lead sort-key prefix
  after the time bucket. Always filtered.
- **Measures** (verified columns, with engine-correct aggregation):
  - `<col1>` — `SUM(<col1>)` (plain), or `SUM(sign * <col1>)` for
    Collapsing-family.
  - `<col2>` — `<aggregation note>`
- **Dimensions** (commonly grouped on): `<col1>`, `<col2>`, ...
- **Enrichment relationships**:
  - `<dim_or_fact>` via `dictGet('<name>', '<attr>', <key>)` —
    `[declared]` (Dictionary).
  - `<other_fact>` via JOIN on `<key>` — `[inferred]` (no FK; see
    relationship card below).

**Read-cost note** (verified):
> A 7-day tenant slice reads ~`<N>` rows under FINAL with the
> canonical filter shape (verified `<date>`, tenant=`<id>`,
> `query_id=<…>`).
>
> If unverified: `inferred from schema: <reason>`.

**Inferred relationships** (re-probe before trusting):
- `<this_fact>.(<key_cols>) ↔ <other>.(<key_cols>)`
  - Captured cardinality on tenant=`<id>` (`<date>`):
    `matched=<N>`, `distinct_left=<N>`, `distinct_right=<N>`,
    `avg_fanout=<f>`.
  - Probe to re-run on your tenant:
    ```sql
    SELECT count() AS matched,
           uniqExact((a.<col1>, a.<col2>))   AS distinct_left,
           uniqExact((b.<col1>, b.<col2>))   AS distinct_right,
           count() / greatest(uniqExact((a.<col1>, a.<col2>)), 1) AS avg_fanout
    FROM <left> a
    ANY LEFT JOIN <right> b
      ON a.<col1> = b.<col1>
     AND a.<col2> = b.<col2>
    WHERE a.<date_col> >= today() - 7
      AND a.<tenant_filter>;
    ```
  - Healthy: `avg_fanout ∈ [0.9, 1.5]`.

**Engine traps on this table** (verified or version-pinned):
- <e.g. "FINAL inside JOIN: `JOIN <table> u FINAL` is a parser error on
  CH 23.x; wrap the FINAL side in a subquery.">
- <e.g. "`finalizeAggregation(anyLastSimpleState(col))` over FINAL
  produces `Code: 43 ILLEGAL_TYPE_OF_ARGUMENT` — under FINAL, use plain
  `anyLast(col)`.">

**Shape illustration only** (NOT a recipe — illustrates the engine
constraints, not the answer to a specific question):
```sql
SELECT <dim>, <engine-correct-agg(measure)>
FROM   <table> [FINAL]
WHERE  <time_col> BETWEEN <from> AND <to>
  AND  <tenant_filter>
GROUP BY <dim>
```

<Repeat per analyst-hot fact. ~6-10 cards per cluster.>

## Cluster-wide engine trap reference

<Pull engine-level traps that apply across multiple facts up here, with
the version they were observed on. Each entry tagged `verified` or
`from CH docs` so the analyst can judge.>

## Operational / freshness probes

<Verified or inferred: how to check data recency on this cluster. State
which.>

## `FINAL` — when it's legitimate on this cluster  [REQUIRED if any
AggregatingMergeTree / ReplacingMergeTree / CollapsingMergeTree is
analyst-hot]

State the cluster's actual policy, not a generic warning. The
consumer-model default is "FINAL is slow, use argMax" — override that
explicitly when the cluster's schema is designed for FINAL reads.

Template:

> `FINAL` **is** the read idiom on <list tables, e.g. `mentiondetails`,
> `page_stats`, `mstuserinformation_new`>. These are
> `AggregatingMergeTree` with `SimpleAggregateFunction(anyLast, …)` (or
> `ReplacingMergeTree` with `<version_col>`) and are **designed** to be
> read with `FINAL`. Do not rewrite `FINAL` as `argMax(col, <ts>)` on
> these tables — the effective version is
> <insert-order within sort-key bucket | the stated version column |
> `added_at`>, and `argMax` on a different timestamp column produces
> the wrong answer.
>
> The `FINAL` cost model on this cluster is `O(parts-per-bucket ×
> bucket-size)`. With a tight partition filter (`<time_col> >=
> toDateTime(…)`) you pay for one day's parts, which is cheap. Without
> a partition filter, `FINAL` reads every part in the table — that's
> the anti-pattern, not `FINAL` itself.

Tables where `FINAL` is **not** the idiom (if any) should be listed
separately: e.g. plain `MergeTree` logs, Replacing-MT tables that use
the `argMax + HAVING NOT argMax(is_deleted, version)` tombstone idiom
(Dim.* polymorphic stores).

## Common mistakes to avoid

- <Anti-pattern 1>
- <Anti-pattern 2>
- ...

### Anti-pattern: missing date-column filter on an AggMT fact  [REQUIRED
if any AggregatingMergeTree with a date lead in the sort key is hot]

Symptom (template):

```sql
SELECT <col>
FROM   <fact>            -- AggMT, sort key (toStartOfDay(<date>), <tenant>, …)
WHERE  <tenant_col> = ?
  AND  <other_col> IS NOT NULL
  AND  <equality_probe> = ?   -- e.g. a native platform ID
```

Problem: the sort-key lead column (`toStartOfDay(<date>)` or similar) is
not in the filter, so the query scans every partition for the tenant.
When the query runs frequently and the table is large, daily read
volume runs into the trillions of rows.

Rewrite template:

```sql
SELECT <col>
FROM   <fact>
PREWHERE <date_col> >= toDateTime(<from>)   -- partition prune lead
     AND <tenant_col> = ?
     AND <equality_probe> = ?
LIMIT 1                                      -- if the caller is probing
```

If the caller truly doesn't know the age, default the range to
`today() - <sensible-window>` and accept the occasional miss — it's
almost always cheaper than a tenant-wide scan. Check with the catalog
owner whether the native-platform-ID probe can be shifted to a skip
index.

If this anti-pattern was observed in the query log, include the
normalized query hash and the observed per-day rows-read volume in the
card — it's the most persuasive form of evidence for the rewrite.

## When the Skill doesn't cover a table

- `DESCRIBE` first.
- For unfamiliar engines, check `engine_full` via
  `SELECT engine_full FROM system.tables WHERE database=... AND name=...`.
```

## pipeline.md structure

```markdown
# <cluster>-analyst · pipeline / operational

<Opening paragraph: what this file is for.>

## Ingestion shape

<Diagram, prose. Required if Kafka/MV/Buffer/Null present.>

## Distributed ↔ local pairing

<Required if Distributed engines present.>

| Distributed | Backing local | Shard key | Where to query |
|---|---|---|---|
| `<dist_name>` | `<local_name>` | `<expr>` | `<dist_name>` for analytics |

## Demoted tables by category

### Streaming infra  [if Kafka/Null/MV/Buffer present]
- Kafka engine: <list-if-short, or a query suggestion>
- Null landing pads: <list>
- MV triggers (no storage): <list>
- `.inner.*` auto-storage: <noted, not enumerated>
- Buffer: <list>

### Staging
- `_new`, `_tmp`, `_staging`: <list>

### Backup / DR mirrors  [if present]
- `<list>`

### DBA utility
- `<list>`

### User sandboxes
- `<list>` (skipped from analyst Pareto)

### Test/live siblings  [if present — only if detected]
- `<pair>` — document which one carries real traffic.

### Per-tenant caches  [if detected]
- Summarize pattern; DO NOT enumerate individual tenant copies.

## Service users

- `<user>` — <role> (service vs analyst vs Redash/dashboard)
- ...

## Operational sketches

<A few queries an operator might run: freshness, per-shard size imbalance,
latest event, ETL lag.>

## When to regenerate this Skill

- <Triggers: schema change, version upgrade, etc.>

## When NOT to regenerate

- <Row-count growth, routine updates.>
```

## glossary.md structure

```markdown
# <cluster>-analyst · glossary

## Naming conventions on this cluster

<The rules that differ from standard ClickHouse practice.>

- **`<pattern>`** — <what it means>
- ...

## Users

- **Service / pipeline**: `<list>`
- **Human / analyst**: `<role, not exhaustive list>`
- **Dashboards**: `<role>`

## Known CH <version> quirks  [REQUIRED]

- <version-specific gotcha 1>
- <version-specific gotcha 2>
- ...

<Examples:>
- **`system.tables.as_select` missing** (CH < 22): use `create_table_query` regex.
- **`system.dictionaries` empty despite Dictionary engines** (CH 21.8 seen): enumerate from `tables_raw.engine='Dictionary'`.
- **`loading_dependencies_*` sparse**: fall back to `dependencies_*` + `as_select` regex.
- **MV inline storage naming**: `.inner.mv_<name>` on CH<23; `.inner_id.<uuid>` on CH≥23.

## Writing-style gotchas

- <Type mismatches, column-name inconsistencies, etc.>

## Term decoder  [REQUIRED for domain-specific clusters]

| Term | Meaning |
|---|---|
| `<code/abbreviation>` | <expansion / business meaning> |
...

<Heavy: fab-metrology terms (cdsem, LWR), ad-tech (RTB, CTR), biotech
(lims samples), finance (GGR, RTB), telemetry (runid, toolid).>

## Cluster fingerprint components

<How the fingerprint is computed for staleness detection.>

## Regeneration triggers  [brief, mirrors SKILL.md staleness section]
```

## README.md structure (meta — NOT loaded as part of the Skill)

```markdown
# <cluster>-analyst — Skill bundle notes

**What this is**: a per-cluster ClickHouse analyst Skill produced by the
`clickhouse-profiler` Skill. Save the files in this folder as a Skill in
claude.ai (Settings → Capabilities → Add Skill; upload zip or folder).

## Source

- **Cluster**: <name>
- **Fingerprint**: <from frontmatter>
- **CH version**: <version>
- **Generated**: <date>
- **Profiler version**: <version>
- **MCP source**: <tool name>
- **Mined window**: <from>..<to>, <rows> executions, <hashes> normalized queries

## Workload character

<2-4 paragraphs describing what the cluster does, based on schema
evidence. Naming of databases, table names, and query log vocabulary.>

## Design decisions used for this draft

- Cluster name inferred via <path in fallback chain>.
- <Anything else optional that was applied.>

## Limitations

- <What's missing and why — empty system.dictionaries, thin query log,
  sparse dependencies, etc.>

## Verification log  [REQUIRED]

Audit trail of what was checked at profile time vs. inferred. Every
named identifier, behavior claim, and JOIN appears as one row. Entries
are flat — each line is `<type>: <subject> · <status> [· <evidence>]`.

The block below is **illustrative only** (actual outputs from a real
run; substitute your cluster's identifiers). The profiler logic does
not depend on any specific table or column existing.

```
verification_tenant: <tenant_id_or_"none">
verified_at: <YYYY-MM-DD>

existence checks:
  <db>.<fact_table>                          verified
  <db>.<dim_table>                           verified
  <db>.<dropped_table>                       dropped (table does not exist)
  <db>.<other_fact>.<verified_col>           verified
  <db>.<other_fact>.<dropped_col>            dropped (column does not exist)
  …

behavior claims:
  <fact_table> / FINAL amplifies ~100x       verified  read_rows=…  query_id=…
  <fact_table> / 7d tenant ~10–60M reads     verified  read_rows=…  query_id=…
  <other_fact> / FINAL + <date_col>=today()  inferred  (no probe — stale data on tenant)
  …

relationship probes:
  <fact_table> ↔ <dim_table>
    by (<lk1>, <lk2>) ↔ (<rk1>, <rk2>)
    verified  matched=…  fanout=1.0  [inferred — re-probe per tenant]
  <fact_table> ↔ <other_fact>
    by (<key>)
    unverified  (probe errored: type mismatch on join col)  [inferred]
  …
```

Counts at the top of the log: `<N>/<M> claims verified · <K> demoted to
inferred · <D> dropped`. The same counts appear in SKILL.md
frontmatter as `verification_summary`.

If `verification_tenant: none` (user declined), all behavior and
relationship claims should appear as `inferred` and the artifact's
evidence layer is thinner — note this prominently here and in SKILL.md
staleness section.

## Since last run  [REQUIRED for regeneration; OMIT for first run]

<If a prior Skill existed:>
- Prior generated_at: <date>
- New tables: <list>
- Removed tables: <list>
- Engine changes: <list>
- Workload shifts: <observed>
- Schema fingerprint change: <yes/no>

## How to use this Skill

1. Compress this folder: `zip -r <name>-analyst.zip <name>-analyst/`.
2. In claude.ai, go to Settings → Capabilities → Add Skill.
3. Upload the zip (or the folder directly, if supported).
4. The Skill's `description` auto-triggers it when you query this cluster.

## How to regenerate

Re-run the `clickhouse-profiler` Skill against the same cluster. Save
the new output over the prior Skill. The new SKILL.md's `Since last run`
section will summarize what changed.
```

## Writing standards

### PII

- Never emit literal values, emails, IPs, user IDs, tokens from raw query_log.
- Use placeholders: `<tenant>`, `<from>`, `<to>`, `<id>`, `<bu>`, `<name>`.
- Strip `/* ... */` comments before any query text is inspected.
- Use `normalizeQuery()` on any example SQL extracted from query_log.
- User lists: descriptive roles, not exhaustive names. Name only
  representative handful.
- Kafka broker hostnames: permitted if clearly publicly known; redact
  otherwise.

### Tone

- Second-person or imperative. "Always filter `bu` first." Not "I'd
  recommend filtering `bu` first."
- No adjectives of emphasis: "huge", "critical", "amazing", "beautiful".
  State. "4.05B rows" not "a huge 4.05B rows".
- Mark inferences: "inferred from schema, no query-log signal",
  "Likely" (confidence), "probably" (schema-only inference).
- No emojis.
- Monospace `backticks` for identifiers (tables, columns, engines, SQL
  keywords inline).

### Classification tags

Always: `Fact, Confident` / `Fact, Likely` / `Dim, Confident` /
`Dim, Likely` / `Mart, Confident` / `Mart, Likely` / `Staging` /
`Cache` / `Other`.

Never: "probably Fact", "High-priority Dim", numeric probabilities.

### Length budgets (strict)

- SKILL.md: 1500-2500 words.
- catalog.md: 1000-2500 words (depending on Pareto size).
- patterns.md: 800-2000 words.
- pipeline.md: 600-1500 words.
- glossary.md: 500-1200 words.
- README.md: 400-1500 words.

If the cluster has dramatically more material (rare), the ceiling can
flex by ~25%. Going well beyond 10k total words typically means the
Pareto wasn't cut aggressively enough.

### Heading depth

- SKILL.md: use `##` for sections, `###` for sub-sections. Do not use `#` inside (the frontmatter title is the `#`).
- Other files: same. Title of the file appears at the top as `# <cluster>-analyst · <purpose>`.

### Tables vs prose

- Engine list, top-15 tables, Distributed pairs, Dictionary summary,
  term decoder: **tables**.
- Ingestion shape, cluster character, workload character, aggregation
  idioms longer than 1 line, staleness triggers: **prose**.
- Pattern cards: hybrid — bulleted ingredients + SQL template.

### Code fences

- SQL shapes: triple-backtick `sql` fences.
- Identifier inline: single backticks.
- DDL in catalog: triple-backtick fences for multi-line `engine_full`
  output. Truncate if longer than 500 characters — the full text is in
  the cluster; catalog shows the shape only.

## Template self-check before emitting

Run through this list before writing:

1. Every analyst-hot table has a card in `catalog.md`.
2. Every card has: engine, rows, partition, sort, hot columns,
   aggregation rule, and at least one gotcha or filter note.
3. The SKILL.md "Engine idioms" section matches the **primary
   archetype**'s expected engine mix from `archetypes/<primary>.md`.
   The archetype letter is named at the top of `patterns.md`, and the
   archetype module's signature card is rendered. Engines that don't
   match the archetype's profile (and aren't part of any detected
   secondary archetype) are absent from the section.
4. `patterns.md` has ≥ 4 fact knowledge cards unless the cluster has
   very few analyst-hot facts. Each card teaches engine-level facts;
   none prescribes a SQL recipe for a question class.
5. `pipeline.md` has the Distributed ↔ local pairing table if any
   Distributed engines exist.
6. `glossary.md` has a term decoder for any non-obvious domain.
7. `SKILL.md` top-tables list matches `catalog.md` cards.
8. Frontmatter `description` triggers correctly: would a user asking
   "help me query `<cluster>`" match this? If not, rewrite the
   description.
9. No PII leaked anywhere. Grep for `@` (emails), `/*` (comments),
   suspicious-looking identifiers.
10. No placeholders left: `<TBD>`, `<FILL>`, `<TODO>` indicate missing
    data. Replace before emitting.
11. **Existence**: every `<db>.<table>` and `<db>.<table>.<col>` named
    anywhere in the artifact appears in the verification log under
    `existence: … verified`. None named `dropped`.
12. **Behavior**: every claim about read-cost, prune behavior, FINAL
    amplification, or skip-index usage either carries a
    `verified <date>; read_rows=…; query_id=…` tag inline OR is
    explicitly marked `inferred from schema`. No bare assertions.
13. **Relationships**: every JOIN documented anywhere in the artifact
    is marked `[inferred]` and carries a captured cardinality probe
    (matched, distinct_left, distinct_right, avg_fanout) OR is marked
    `unverified: <reason>`. No JOIN documented as if it were declared.
14. **No SQL recipes for question classes**. Search `patterns.md` for
    headings like "Pattern: top-N posts" or "Pattern: daily mentions
    by channel" — these are recipe-shaped (one query per business
    question). Replace with per-fact knowledge cards. The analyst
    composes its own queries from the facts.
15. README.md has a Verification log with counts at the top
    (`<N>/<M> verified · <K> inferred · <D> dropped`); SKILL.md
    frontmatter `verification_summary` matches.
16. **Writing conventions are mined, not invented.** Every bullet under
    `patterns.md` § "Cluster-wide writing conventions" cites an observed
    ratio from Phase 5d.1 (e.g. `~78% of hot queries`). If the corpus
    didn't yield a dominant form for some axis, omit that bullet —
    don't fall back to a generic "best practice".
17. **Primary archetype is named at the top of `patterns.md`** (e.g.
    `Archetype: C — Cube/MV warehouse`), and the archetype module's
    **Signature card** is the lead block of the
    "From the schema (derived)" subsection. If Phase 1.5 detected
    secondary archetypes, their **Engine traps** sections appear as
    sub-blocks (NOT their signature cards — secondaries contribute
    traps + corpus overrides only).
18. **Skip-set lead on inferred-relationship cards**. For every
    `<fact> ↔ <dim>` inferred-relationship card in `patterns.md`,
    when the primary archetype ∈ `{B, C, D}` AND the right side is a
    dim with no time partition axis, the card MUST lead with
    skip-set form (`WHERE (k1, k2) IN (SELECT k1, k2 FROM <fact>
    WHERE <tenant_filter> AND <date_filter>)`), not bare composite-key
    JOIN. Bare JOIN may follow as an alternative for small dims.
    For archetypes A and E this rule does not apply.
19. **No generic ClickHouse in `patterns.md`.** Every paragraph in
    `patterns.md` references at least one of: a cluster-specific
    identifier (a table / column / MV / engine instance by name), a
    captured probe number with `query_id`, or a cluster-application
    of an archetype trap (e.g. "on this cluster, trap-C5 takes the
    form of `.inner.<name>` legacy naming because the MV pre-dates
    the CH 23 upgrade"). Drop any paragraph that explains generic CH
    mechanics — FINAL semantics, error codes, `finalizeAggregation`,
    state-vs-resolved-value, the textbook anyLast/argMax tradeoff —
    the consumer model already has that. See "What NOT to include"
    above for the 5 antipatterns.
20. **No restated rules across files.** Each rule, list, or verified
    probe lives in one source-of-truth file (see the table in "One
    source of truth" above); the others cross-reference. Specifically:
    the FINAL/anyLast rule is stated in full in `patterns.md` once;
    `SKILL.md` and `catalog.md` reference it without restating. The
    full Kafka engine listing is in `pipeline.md` once; `patterns.md`
    cites it. The same `query_id`-tagged verification record appears
    in exactly one file. Grep the bundle for the rule's signature
    phrase before emitting — if it appears in 3 files in similar
    language, two of them are restating instead of cross-referencing.
21. **Backticked identifiers re-verified post-synthesis.** Phase 7.5a
    verifies the model's *intent set* (names planned during phases
    3–7), but column-name typos can still enter prose at Phase 8
    synthesis — `authorfollowercount` when the real column is
    `followerscount`. Phase 8e step c re-extracts every backticked
    `<db>.<table>.<col>`, `<table>.<col>`, and bare `<col>` (inside a
    per-table card) from the emitted markdown and re-queries
    `system.columns`. Any miss is a hard fail — rewrite the offending
    paragraph and re-scan, don't log-and-emit. Plain-text mentions
    are out of scope; this only enforces the backticked-identifier
    convention the templates already require.
