# Archetype B · Sharded OLAP

## When loaded

Selected by rule 1 (`biz_tabs > 5000` huge-enterprise), rule 7
(`dist_share > 0.20` AND `repl_share > 0.15` sharded-replacing), or
rule 8 (`dist_share > 0.20` sharded-plain). The cluster has a
`Distributed` front for analytics, with `_local` (or sibling-named)
tables on each shard. Naming convention is cluster-specific —
`_local` suffix, `_d`/no-suffix, `dist_` prefix all appear.

## Signature card

Lead `patterns.md` "Cluster-wide writing conventions" → "From the
schema (derived)" with the **Distributed/local card**:

```markdown
## Cluster shape — sharded OLAP

This cluster has <N> shards behind a `Distributed` front. The naming
convention here is `<convention>` (e.g. bare = local, `_d` =
Distributed; or bare = Distributed, `_local` = local — fill from
Phase 0c).

Read priorities:
- **Always query the Distributed name for analytics**, never the
  bare/`_local` storage. Direct `_local` reads return one shard's
  partial answer.
- **Shard key shapes the read cost**. A query that filters on
  `<shard_key_expr>` prunes fanout to the relevant shard; queries
  without that filter broadcast to all <N> shards. `rand()` shard
  keys force broadcast unconditionally.
- **Replicated*MergeTree dedup**: ReplacingMergeTree is the cluster's
  primary dedup engine. The latest-row idiom is `argMax(col,
  <version_col>)` for bulk scans (cheap), and `FINAL` for small
  slices (correct but expensive at scale).

The Distributed/local pairing table in `pipeline.md` is the load-
bearing reference for this cluster. Read it before composing any
multi-shard query.
```

## Phase emphasis

- **Phase 0c**: parse every Distributed engine's `engine_full` to
  derive the naming convention. This is non-negotiable for B; if the
  parse fails, fall back to `substring(create_table_query, 1, 500)`
  and re-parse. The artifact is wrong without this.
- **Phase 5e (co-occurrence dedup)**: heavily emphasised — every
  `(Distributed_X, X_local)` pair must be stripped before the join
  graph is rendered, or the artifact will document non-existent
  joins.
- **Phase 6 (Pareto demotion)**: for huge-enterprise (`biz_tabs >
  5000`), demote aggressively. `_local` tables that exist only as
  Distributed backings should NOT appear analyst-hot — they're
  transparent storage. `pareto_cut.py --archetype B` raises the
  service-user demotion threshold and lowers the analyst-hot target
  to ~10 (from default 20).
- **Phase 7.5c (relationship probes)**: skip-set form is the idiom
  on B for any join where the right side is a tenant-scoped dim
  with no time axis (or where the Distributed front would broadcast
  the dim scan). Lead the relationship card with skip-set, follow
  with the bare composite-key form as a fallback.

## Engine traps

- `[trap-B1] _local is for diagnostics only`. Document one or two
  `_local`-direct probes in `pipeline.md` for ops use, but do not
  surface the `_local` names in `catalog.md` as analyst-facing
  tables. The Distributed front is the analyst surface.
- `[trap-B2] rand() shard key forces broadcast`. If
  `engine_full` ends with `..., rand())`, every read fans out to
  every shard regardless of filter. Document it as a freshness/cost
  axis, not a tunable.
- `[trap-B3] ReplacingMergeTree FINAL cost on sharded reads`. FINAL
  on a Distributed-fronted ReplacingMT pays the merge cost
  per-shard then merges the shard outputs. For bulk scans, the
  `argMax(col, <version_col>)` rewrite is faster on this cluster.
- `[trap-B4] ReplacingMergeTree tombstone idiom`: when soft-delete
  is encoded as `is_deleted` flag + version column, the read idiom
  is `argMax(col, <ver>) … HAVING NOT argMax(<is_deleted>, <ver>)`,
  not `FINAL` (FINAL keeps the tombstone row).

## Corpus-override list

| Bullet ID | Action | Replacement (if any) |
|---|---|---|
| `B2-anylast-vs-argmax` | **Suppress** unless `AggregatingMergeTree*` is detected on a hot fact | n/a — on B without AggMT, the latest-row idiom is `argMax`-on-version, not `anyLast` |
| `B1-prewhere` | Pass through unchanged | (corpus-derived) |
| `B3-todate-vs-tostartofday` | Pass through unchanged | (corpus-derived) |
| `B4-select-star` | Pass through unchanged | (corpus-derived) |

The skip-set guidance for inferred-relationship cards is enforced by
templates.md self-check item 18 when archetype is B/C/D, not by a
corpus-override bullet.
