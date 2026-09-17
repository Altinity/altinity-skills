# Storage reference

Background for the storage skill. Read only when a recommendation needs to be explained.

## Settings

| Setting | Scope | Notes |
|---------|-------|-------|
| `min_bytes_for_wide_part` | Table | Parts smaller than this are stored Compact (one file for all columns). Default 10 MiB. |
| `min_rows_for_wide_part` | Table | Row-count equivalent of the above. Default 0, meaning bytes decide. |
| `max_bytes_to_merge_at_max_space_in_pool` | Table | Largest merge the pool will attempt. Caps how big a single part can become. |
| `prefer_not_to_merge` | Table | Emergency brake that stops merges for a table. Leaves part counts growing; only for incident response. |
| `storage_policy` | Table | Selects the volume set from `system.storage_policies` for tiered or object storage. |
| `ttl_only_drop_parts` | Table | Makes TTL drop whole parts instead of rewriting them, which is far cheaper on IO. |
| `max_partitions_to_read` | Query | Guards against queries that scan every partition. |

## Codecs

| Data shape | Codec | Notes |
|------------|-------|-------|
| General columns | `ZSTD(1)` or `ZSTD(3)` | Better ratio than LZ4 at moderate CPU cost. |
| Monotonic integers, counters | `Delta, ZSTD` | Stores differences before compressing. |
| Timestamps, DateTime | `DoubleDelta, ZSTD` | Stores the difference of differences; very effective for regular intervals. |
| Floating-point gauges | `Gorilla, ZSTD` or `FPC` | Designed for slowly changing telemetry. |
| Repetitive strings | `LowCardinality(String)` | A type change, not a codec. Dictionary-encodes the column and speeds up filters and GROUP BY. |
| Already-compressed blobs | `NONE` | Re-compressing costs CPU and gains nothing. |

## Disk space rules of thumb

- Keep at least as much free space as the largest expected merge, and never let a data disk exceed 85 percent in steady state.
- `system.parts` counts only `active` parts. Inactive parts awaiting cleanup and detached parts also occupy disk; compare `system.disks` free space against the sum from `system.parts` to spot the difference.
- Object-storage disks report free space from the local cache, not from the bucket, so disk-percentage checks are meaningful only for local volumes.

## Anti-patterns

- Adding disk to absorb unbounded system log growth instead of setting TTL.
- Partitioning by day on a table that receives a few thousand rows a day, producing thousands of tiny parts and inflating both mark cache and file handles.
- Lowering `min_bytes_for_wide_part` to zero "for consistency", which turns every small part into a per-column file set.
- Removing detached parts with reason `broken` or `noquorum` before establishing why they were detached.
