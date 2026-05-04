# Archetype D · Star schema with Dictionaries

## When loaded

Selected by rule 5 (`dict_share > 0.03` AND `mv_share > 0.10`). The
cluster has explicit Dim/Fact/Mart partitioning (often by database
name: `Dim`, `Fact`, `Mart` — but classify by engine, not name).
Dim tables are `Dictionary` engines for fast lookup; facts are
`*MergeTree` variants; marts are `View` over the facts.

## Signature card

Lead `patterns.md` "Cluster-wide writing conventions" → "From the
schema (derived)" with the **dictGet card**:

```markdown
## Cluster shape — star schema with Dictionary dims

This cluster is laid out as a star: facts in `*MergeTree` variants,
dims as `Dictionary` engines (memory-resident), marts as Views over
facts. Dimension enrichment happens via `dictGet`, not JOIN.

Read priorities:
- **`dictGet('<dim>', '<attr>', <key>)` is the enrichment idiom**,
  not `JOIN <dim> ON …`. JOINs against Dictionary engines work but
  cost a full materialization on each query; `dictGet` resolves
  in-memory per-row.
- **Dictionaries are loaded by ID, not by name**. The `<dim>` arg to
  `dictGet` is the Dictionary's fully qualified name
  (`<db>.<dict_name>`). Naming a fact's storage table here returns
  no results.
- **Multi-tenant per-network dictionaries**: when the cluster
  encodes tenants as `idnetwork`, dims are typically split per
  network (`net_<hash>_<dim>`). The Dictionary list will be large;
  `pipeline.md` should summarize the pattern, not enumerate
  per-tenant.
- **Composite Dictionary keys**: when the dim's primary key is
  `(idnetwork, dim_id)`, `dictGet` requires a tuple:
  `dictGet('<dict>', '<attr>', tuple(<idnetwork>, <key>))`.
- **Polymorphic property store** (when present): a `Replacing*MT` dim
  with `(account_id, prop_name, prop_value, version, is_deleted)`
  rows uses `argMax(prop_value, version) … HAVING NOT
  argMax(is_deleted, version)`, not `dictGet` (it's not a
  Dictionary engine).
```

## Phase emphasis

- **Phase 4b/4c (Dictionary catalog)**: the cluster's value lives
  here. If `system.dictionaries` is populated, mine
  `(name, type, source, element_count, attribute.names)` per
  dictionary. If empty (CH 21.x risk), fall back to
  `engine='Dictionary'` rows in `system.tables` and parse
  `CREATE DICTIONARY … LAYOUT(<layout>) SOURCE(<src>)
  LIFETIME(<lt>)` from `create_table_query`.
- **Phase 7 (classification)**: `Dictionary` engine is **always Dim,
  Confident**. Don't second-guess. View / MaterializedView is
  **always Mart, Confident** when the SELECT body resolves to a
  Fact. Naming hints (`Dim.X`, `Fact.X`, `Mart.X`) get a
  confidence boost only when engine confirms.
- **Phase 7.5c (relationship probes)**: dictGet is "declared", not
  "inferred" — the relationship is in the schema itself. Mark
  Dictionary lookups `[declared]`, not `[inferred]`. JOINs that go
  outside `dictGet` (rare, usually a fact↔fact join) follow the
  standard inferred-relationship probe.

## Engine traps

- `[trap-D1] Dim DB but not Dictionary engine`. A DB named `Dim`
  with `ReplicatedReplacingMergeTree` rows is NOT a Dictionary —
  it's a Replacing fact (often a polymorphic property store). The
  read idiom is `argMax + HAVING NOT argMax(is_deleted, version)`,
  not `dictGet`. Engine, not name, decides.
- `[trap-D2] Dictionary cache layout TTL`. `LAYOUT(CACHE())`
  dictionaries don't preload — first lookup of a key is slow and
  rare keys may miss entirely. `LAYOUT(HASHED())` and `FLAT()`
  preload all rows. Surface the layout in the dictionary's catalog
  card so the analyst knows the expected lookup latency.
- `[trap-D3] Dictionary source freshness`. A `SOURCE(MYSQL(...))`
  dictionary refreshes per `LIFETIME(<seconds>)`. Stale lookups
  return last-loaded data; freshness is `LIFETIME` worst-case.
  Surface in the operational sketches.
- `[trap-D4] Multi-tenant per-network Dictionary fan-out`. If the
  cluster has `net_<hash>_<dim>` per-tenant dictionaries, naming
  the wrong network's dictionary returns 0 lookups silently.
  Document the pattern; do not enumerate.
- `[trap-D5] dictGet on a Distributed cluster`. Dictionaries on
  `<cluster>` macro reside per-shard. A query that reads a
  Distributed fact and `dictGet`s a dim resolves the dim
  per-shard; ensure dim DDL is identical across shards (the
  cluster's deployment usually guarantees this, but worth a
  glossary mention).

## Corpus-override list

| Bullet ID | Action | Replacement |
|---|---|---|
| `B2-anylast-vs-argmax` | Pass through if a hot fact is AggMT (rare on D); otherwise suppress (the latest-row idiom on D facts varies by engine — Replacing facts use `argMax`-on-version with tombstone). | n/a |
| `B1-prewhere` | Pass through. | (corpus-derived) |
| `B3-todate-vs-tostartofday` | Pass through. | (corpus-derived) |
| `B4-select-star` | Pass through. | (corpus-derived) |

If the cluster has `Replacing*MergeTree` polymorphic property stores
in a `Dim`-named DB, the helper additionally emits a derived-bullet
in the schema section pointing to `[trap-D1]` (named there as the
`HAVING NOT argMax(is_deleted, version)` tombstone idiom). This
isn't a corpus override — it's structural — and is included for
completeness in the archetype's idiom list.
