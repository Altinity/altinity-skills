# Archetype A · Plain MergeTree

## When loaded

Selected by rule 10 (`biz_tabs < 100`) or rule 11 (mid-size plain MT
fallback) — the cluster is a small/medium operational store with no
sharding fan-out, no MV cube chain, no Dictionary enrichment, no Kafka
ingest. Most rows are `MergeTree` or `ReplicatedMergeTree`; a few
`View`s exist for convenience.

## Signature card

Lead `patterns.md` "Cluster-wide writing conventions" → "From the
schema (derived)" with the **catalog-density card**:

```markdown
## Cluster shape — small operational store

This is a plain MergeTree cluster: <N> business tables, no Distributed
fan-out, no MV chain, no Dictionary enrichment. Analyst surface is
the table itself; there is no front-vs-storage split to reason about.

Read priorities:
- **Hot-column thinness matters.** With no engine-side dedup or
  aggregation, query cost scales with column projection. Listing
  `SELECT *` over a wide row pays for every codec.
- **Classification often stops at "Other".** Without a Dim/Fact/Mart
  layout, only confident-Fact tables (timestamp + ≥1M rows) get a
  role; the rest are Other.
- **Append-only, no FINAL.** Plain `MergeTree` has no merge-time
  semantics to wait on. `FINAL` is meaningless here; if a query uses
  it, the table is mis-classified — recheck the engine.
```

## Phase emphasis

- **Phase 5c (hot columns)**: this is the single highest-value mining
  step for archetype A. With no aggregation idioms to teach and no
  join graph to map, the analyst's leverage is "which N columns of M
  do real queries actually touch." Lower the touch-threshold one
  notch (10 → 5 for small clusters) and let the catalog cards carry
  more columns.
- **Phase 7 (classification)**: be conservative. A 50k-row table with
  a timestamp is **Likely Fact**, not Confident. "Other" is the
  honest default.
- **Phase 4 (relations)**: dependency graph is usually trivial.
  Don't pad it.

## Engine traps

- `[trap-A1] FINAL on plain MergeTree is meaningless`. If the corpus
  shows `FINAL` on a plain MergeTree table, either (a) the engine is
  actually `ReplacingMergeTree` and Phase 1d miscounted, or (b) the
  analyst is copy-pasting from a different cluster. Either way,
  surface it as a glossary note.

## Corpus-override list

None. Archetype A defers entirely to corpus-mined conventions —
there's no engine-determined idiom to override with.

If the corpus is thin (rule-of-thumb: <100 distinct normalized query
hashes), prefer **silence over invention** — emit no bullets rather
than guessing. The model already has the catalog; the artifact's
value is the existence verification, not the conventions.
