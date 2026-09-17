# Reference: schema design background

Background for the schema skill. Read only when you need to explain a recommendation.

## Partition key granularity by data volume

| Data volume | Recommended granularity | Example |
|---|---|---|
| < 10 GB/month | No partitioning, or yearly | `toYear(ts)` |
| 10-100 GB/month | Monthly | `toYYYYMM(ts)` |
| 100 GB - 1 TB/month | Weekly or daily | `toMonday(ts)` |
| > 1 TB/month | Daily | `toDate(ts)` |

## Compression codec by data type

| Data type | Recommended codec |
|---|---|
| Integers, sequential | `Delta, ZSTD` |
| Integers, random | `ZSTD` or `LZ4HC` |
| Floats | `Gorilla, ZSTD` |
| Timestamps | `DoubleDelta, ZSTD` |
| Strings, long | `ZSTD(3)` |
| Strings, repetitive | `LowCardinality(String)` plus `ZSTD` |

## Table-level settings checked by schema-10

| Setting | Default | Notes |
|---|---|---|
| `index_granularity` | 8192 | Lower for point lookups, higher for full scans. |
| `min_bytes_for_wide_part` | 10 MB | Parts below this are compact; raising it reduces file count for small parts. |
| `min_rows_for_wide_part` | 0 | Row-based equivalent of the above. |
| `ttl_only_drop_parts` | 0 | Set to 1 when TTL removes whole partitions, to avoid rewriting parts. |
| `max_bytes_to_merge_at_max_space_in_pool` | ~150 GB | Upper bound on a single merge; a partition above it never merges to one part. |

## ORDER BY anti-patterns

| Anti-pattern | Why it hurts |
|---|---|
| UUID or hash as first key column | Every granule spans the whole key range, so the index prunes nothing. |
| High-cardinality ID without a tenant or date prefix | Same effect, plus poor compression on the key column. |
| `DateTime64` with microseconds first | Near-unique values; use a truncated timestamp first and full precision later. |
| Too many key columns | Larger primary index in RAM with no pruning benefit past the first few columns. |
