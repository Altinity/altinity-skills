# archetypes/ · cluster-shape modules

Each cluster gets one **primary archetype** assigned at Phase 1.5. The
primary archetype's module is loaded in full at Phase 8 (synthesis) and
governs:

- which signature card leads `patterns.md`
- which engine traps land in the artifact's "Engine traps" sections
- which form-mining bullets get **suppressed** because the archetype's
  idiom contradicts corpus prevalence (the **corpus-override list**)
- which phases get extra emphasis during mining

A cluster may also pick up zero or more **secondary archetypes** when
threshold-crossing signals indicate a hybrid (a Cube/MV warehouse that
also ingests via Kafka, for example). For secondaries, only the
**Engine traps** and **Corpus-override list** sections are merged in;
the signature card and phase emphasis come from the primary.

## The five archetypes

| | Name | Module | When (one-line) |
|---|---|---|---|
| A | Plain MergeTree | `A-plain-mt.md` | catalog-heavy, no Distributed, no MV chain |
| B | Sharded OLAP | `B-sharded-olap.md` | `Distributed` engine ≥ 20% of business tables |
| C | Cube/MV warehouse | `C-cube-mv.md` | `MaterializedView` ≥ 12% AND (`SummingMergeTree` ≥ 2% OR `AggregatingMergeTree` ≥ 5%) |
| D | Star+Dictionary | `D-star-dict.md` | `Dictionary` ≥ 3% AND `MaterializedView` ≥ 10% |
| E | Streaming/Federation | `E-streaming-fed.md` | `Kafka` count ≥ 15 OR external engines (`MySQL`+`PostgreSQL`+`URL`+`S3`+`S3Queue`) ≥ 30 tables or ≥ 30% |

Authoritative rules live in
`/Users/Workspaces/otel/skill-draft/specs/audit-groups.md` §Methodology;
the runtime version below is a faithful copy with no logic changes.

## Decision rules (first-match-wins)

Inputs from Phase 1d / 1e:
- `biz_tabs` — number of business tables (system tables excluded)
- `dist_share` — `Distributed` count / `biz_tabs`
- `view_share` — `View` count / `biz_tabs`
- `mv_share` — `MaterializedView` count / `biz_tabs`
- `summ_share` — `SummingMergeTree*` count / `biz_tabs`
- `agg_share` — `AggregatingMergeTree*` count / `biz_tabs`
- `repl_share` — `ReplacingMergeTree*` (incl. Replicated variants) count / `biz_tabs`
- `dict_share` — `Dictionary` count / `biz_tabs`
- `buffer_n` — `Buffer` count
- `kafka_n` — `Kafka` count
- `null_n` — `Null` count
- `external_n` — sum of `MySQL`, `PostgreSQL`, `URL`, `S3`, `S3Queue`,
  `HDFS`, `MongoDB`, `Redis` counts
- `mt_share` — plain `MergeTree` count / `biz_tabs`

Apply in order, first match wins:

1. **Huge enterprise** → **B** if `biz_tabs > 5000`.
2. **View warehouse** → **C** if `view_share > 0.7` AND `biz_tabs > 500`.
3. **Kafka streaming** → **E** if `kafka_n > 15` OR (`null_n > 20` AND `mv_share > 0.10`).
4. **Federation** → **E** if `external_n > 30` OR (`external_n / biz_tabs) > 0.30`.
5. **Star + dict** → **D** if `dict_share > 0.03` AND `mv_share > 0.10`.
6. **Cube/MV** → **C** if `mv_share > 0.12` AND (`summ_share > 0.02` OR `agg_share > 0.05`).
7. **Sharded replacing** → **B** if `dist_share > 0.20` AND `repl_share > 0.15`.
8. **Sharded plain** → **B** if `dist_share > 0.20`.
9. **Real-time MV** → **C** if `mv_share > 0.08` AND (`buffer_n > 5` OR `mt_share > 0.40`).
10. **Small/simple** → **A** if `biz_tabs < 100`.
11. **Else** → **A** (plain MergeTree mid-size).

The Phase 1.5 SQL recipe and a small Python sketch for evaluating these
rules deterministically live in `pipeline.md`.

## Hybrid (secondary) detection

After the primary archetype is assigned, re-evaluate the *other* ten
rules with thresholds halved — i.e. rule 3 fires as a secondary if
`kafka_n > 7` OR (`null_n > 10` AND `mv_share > 0.05`). Any rule that
fires this pass adds its archetype to `secondary_archetypes` (deduped,
primary excluded).

The intent is to catch hybrids like:
- C primary + E secondary: a Cube/MV warehouse that ingests via Kafka
  (locobuzz2; also exads's `realtime` sub-pattern).
- B primary + C secondary: a sharded OLAP cluster with a non-trivial MV
  layer (tdw-prod's `MaterializedView:272` over the Distributed front).
- D primary + E secondary: star+dict with Kafka top-of-funnel.

If no secondary fires, the cluster is single-archetype.

## What each module declares

Every archetype module has the same five sections, in this order:

1. **When loaded** — the rule that selected it, restated in plain prose.
2. **Signature card** — the one card the artifact's `patterns.md` MUST
   contain when this archetype is primary. Includes a markdown
   skeleton ready to fill.
3. **Phase emphasis** — which existing pipeline phases get extra
   attention for this shape (e.g. C inflates Phase 5b co-occurrence
   dedup; D inflates Phase 7 classifier confidence on Dictionary
   engines). This is guidance for the model, not new SQL.
4. **Engine traps** — the cluster-shape-specific gotchas. Each trap is
   tagged `[trap-id]` so the corpus-override list can refer to them.
5. **Corpus-override list** — bullet IDs from
   `synthesize_conventions.py` that this archetype overrides, with
   the prescribed replacement bullet (or empty for plain
   suppression).

The model loads the primary's full module; for each secondary, only
sections 4 and 5 are merged in.

## Bullet IDs (used by corpus-override lists)

`synthesize_conventions.py` emits each bullet with a stable ID so
archetype modules can reference them:

| ID | What it conveys | Default form |
|---|---|---|
| `B1-prewhere` | Filter form: `PREWHERE` vs `WHERE` | "PREWHERE the tenant + date filters …" |
| `B2-anylast-vs-argmax` | Latest-row idiom on AggMT | `anyLast(col)` over `argMax(col, ts)` |
| `B3-todate-vs-tostartofday` | Daily bucket | `toDate(<col>)` |
| `B4-select-star` | Wide projections note | only when ratio crosses thresholds |

When an archetype module suppresses (or replaces) a bullet, it
references it by ID. New bullets added to the helper must reserve a
new ID and document it here.

## Why archetype, not engine

ClickHouse engines combine arbitrarily — any cluster can host
`AggregatingMergeTree` *and* `ReplacingMergeTree` *and* `Dictionary`
*and* `Distributed`. An "engine fork" forces the profiler to compose N
engine modules without a way to say which one carries the cluster's
weight. Archetype already encodes that — rule 1 (huge enterprise)
overrides engine mix; rule 2 (view warehouse) overrides engine mix;
the cluster's *purpose* is the organising axis. Engine traps still get
expressed inside archetype modules — they just live where they
matter.
