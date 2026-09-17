# Cache reference

Background for the caches skill. Read only when a recommendation needs to be explained.

## Sizing guidance

| Cache | Typical size | Notes |
|-------|--------------|-------|
| Mark cache | 5-10 percent of RAM | Go higher only for random-access workloads whose marks fit; the ceiling is 15 percent. |
| Uncompressed cache | 0 (disabled), or 5-10 percent | Only worth enabling for repeated small point reads. |
| Query cache | 1-5 GB | Only helps identical, repeated, deterministic queries. |
| Compiled expression cache | 128 MB to 1 GB | Raise it for workloads with many distinct complex expressions. |

## Settings

| Setting | Scope | Notes |
|---------|-------|-------|
| `mark_cache_size` | Server | Mark cache limit in bytes. Default 5 GiB. |
| `uncompressed_cache_size` | Server | Uncompressed block cache limit. 0 disables it. |
| `compiled_expression_cache_size` | Server | Compiled expression cache limit. |
| `<query_cache><max_size_in_bytes>` | Server config | Query cache limit. Not exposed as a flat server setting name. |
| `use_uncompressed_cache` | Query or profile | Opt in per query; the cache does nothing without it. |
| `use_query_cache` | Query or profile | Opt in per query, with `query_cache_ttl` and `query_cache_min_query_runs` controlling what gets stored. |
| `index_granularity` | Table | Rows per mark, default 8192. Higher means fewer marks and a smaller mark cache, at the cost of coarser skipping. |

## Why marks multiply

Mark count grows with the number of active parts, the number of columns in Wide parts, and inversely with `index_granularity`. Halving `index_granularity` doubles the marks. Adaptive granularity (`index_granularity_bytes`, default 10 MiB) caps mark size for wide rows. A table with thousands of tiny parts pays the per-part mark overhead many times over, so fixing merges often shrinks the mark cache more than any setting change.

## Anti-patterns

- Lowering `index_granularity` to "reduce the cache" — it does the opposite.
- Enabling the uncompressed cache globally for an analytical scan workload; every scan evicts the cache and nothing is reused.
- Sizing the mark cache above 15 percent of RAM instead of reducing the mark count.
- Judging the query cache by hit ratio when the workload has no repeated identical queries.
