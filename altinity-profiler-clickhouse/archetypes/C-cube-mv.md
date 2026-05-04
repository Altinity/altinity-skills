# Archetype C · Cube / MV warehouse

## When loaded

Selected by rule 2 (`view_share > 0.7` view warehouse), rule 6
(`mv_share > 0.12` AND (`summ_share > 0.02` OR `agg_share > 0.05`)
cube/MV), or rule 9 (`mv_share > 0.08` AND (`buffer_n > 5` OR
`mt_share > 0.40`) realtime-MV). The cluster's analyst surface is a
chain of `View` → `MaterializedView` → `.inner.mv_<name>` /
`.inner_id.<uuid>` → (often) `Distributed` → `*MergeTree`
pre-aggregated cube. Hot facts are `SummingMergeTree` or
`AggregatingMergeTree` storage backing analyst-facing Views.

## Signature card

Lead `patterns.md` "Cluster-wide writing conventions" → "From the
schema (derived)" with the **MV-chain card**:

```markdown
## Cluster shape — pre-aggregated cube warehouse

This cluster pre-aggregates events through a MaterializedView chain.
The analyst surface is the wrapping `View` (or top-level
`Distributed`); the inline `.inner.mv_*` / `.inner_id.<uuid>` storage
is transparent. Reads pass through the engine's merge-time
aggregation — the answers the analyst sees are already aggregated
per the source MV's `GROUP BY`.

Read priorities:
- **Query the View, not the storage**. The wrapping View resolves to
  the inline storage automatically. Naming the storage directly
  bypasses the View's projection list and surfaces engine-internal
  schema.
- **AggregatingMergeTree is read with `FINAL` (or matching `*Merge`
  functions)**, never `argMax(col, ts)`. The engine's
  `SimpleAggregateFunction(anyLast, …)` columns have already picked
  a winner per merge bucket; `argMax` on a different timestamp
  column is semantically wrong and will return inconsistent results.
- **SummingMergeTree is read with plain `SUM(col)`**, NEVER `count()`
  on merged rows. Counts must use a dedicated count column populated
  on insert (`sum(<count_col>)`). `count()` on a Summing target
  returns merged-row count, not event count.
- **Time partition is the cube's load-bearing prune**. A query that
  doesn't filter on the partition's time expression scans every
  bucket — at cube scale this is a multi-billion-row read.
```

## Phase emphasis

- **Phase 3d (MV TO-target resolution)**: critical. Every MV's `TO`
  target must resolve to a concrete storage. If the resolution chain
  passes through a Distributed (common — MV writes to a Distributed
  front, which writes to the local `_local`), follow it.
- **Phase 5b/5e (co-occurrence dedup)**: the model will see
  `(View_X, .inner.mv_X)` or `(View_X, X_local, .inner_id.<uuid>)`
  triples in the query log. These are NOT joins; they're engine
  resolutions. The dedup pass MUST strip them or the join graph is
  fictional.
- **Phase 5d.1 (form mining)**: pass `--archetype C` to
  `synthesize_conventions.py`. The corpus-override list below
  takes effect; the helper hard-suppresses the
  `argMax`/`anyLast` corpus bullet when the top fact is AggMT
  with `SimpleAggregateFunction(anyLast, …)` columns.
- **Phase 7.5c (relationship probes)**: cube ↔ dim joins are common
  on C. Lead inferred-relationship cards with **skip-set form**
  (`WHERE (k1, k2) IN (SELECT k1, k2 FROM <fact> WHERE
  <tenant_filter> AND <date_filter>)`) — direct composite-key JOIN
  forces a full dim scan when the dim has no time axis. The
  skip-set prunes the dim read to the fact's matched keys (often
  3-4 orders of magnitude smaller).

## Engine traps

- `[trap-C1] anyLast over FINAL on SimpleAggregateFunction(anyLast, …)`.
  AggMT columns declared as `SimpleAggregateFunction(anyLast, …)` are
  pre-merged: the engine has already picked a value per merge bucket.
  Reading them with `FINAL + anyLast(col)` is the engine-native path.
  `argMax(col, <ts>)` is semantically wrong here regardless of
  corpus prevalence — `argMax`'s timestamp argument is a different
  column from the `anyLast` ordering, and the two answers will
  diverge whenever insert order doesn't match `<ts>` order.
- `[trap-C2] SummingMergeTree count is wrong without a count column`.
  `count()` over a Summing target counts post-merge rows, not source
  events. Either `sum(<count_col>)` if a count column exists, or
  `countMerge(<state_col>)` if the column is an `AggregateFunction`
  state. Plain `count()` lies.
- `[trap-C3] *Merge() functions for AggregateFunction columns`.
  Columns of type `AggregateFunction(<func>, …)` (not Simple) need
  `<func>Merge(<col>)` to read. `quantilesMerge`, `uniqMerge`,
  `sumMerge`. Plain reads return the binary state, not the value.
- `[trap-C4] FINAL inside JOIN parser quirk on CH 23.x`. `JOIN
  <table> u FINAL` is a parser error; wrap the FINAL side in a
  subquery: `JOIN (SELECT … FROM <table> FINAL …) u`. Document this
  in glossary if any AggMT/Replacing FINAL JOINs appear in the
  corpus.
- `[trap-C5] Inline MV storage naming churn`. CH < 23 names inline
  MV storage `.inner.mv_<name>`; CH ≥ 23 names it
  `.inner_id.<uuid>`. The dedup pass must handle both. Co-occurrence
  pairs `(View, .inner_id.*)` are storage-resolution, not joins.
- `[trap-C6] Buffer engine in front of a fact`. When `Buffer(...,
  <fact>, ...)` exists, inserts hit the Buffer first, then flush to
  the fact. Reads from the Buffer return buffered+underlying — brief
  inconsistency window. Analyst surface is the underlying fact, not
  the Buffer. Document the Buffer in `pipeline.md`, not as an
  analyst-hot card.

## Corpus-override list

| Bullet ID | Action | Replacement |
|---|---|---|
| `B2-anylast-vs-argmax` | **Hard-suppress** when top fact has any `SimpleAggregateFunction(anyLast, …)` column. Replace with engine-native bullet from `[trap-C1]`. | "**Latest-row idiom on AggMT**: `anyLast(col)` over `FINAL`, not `argMax(col, ts)` — engine stores `SimpleAggregateFunction(anyLast, …)`, so `anyLast` is the engine-native path. Corpus prevalence is irrelevant; `argMax` on a different timestamp column produces inconsistent results." |
| `B1-prewhere` | Pass through. | (corpus-derived) |
| `B3-todate-vs-tostartofday` | Pass through. | (corpus-derived) |
| `B4-select-star` | Pass through, but raise the warning threshold (cube projections are wider; `SELECT *` is more expensive than on plain MT). | (corpus-derived; helper does not need a code change for this) |

If `SummingMergeTree` is the top fact's engine, the helper additionally
suppresses any "counting" bullet that recommends `count()` over
`sum(1)` — the engine has its own answer (see `[trap-C2]`).
