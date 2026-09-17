# Part log reference

Background for the part-log skill. Read only when a recommendation needs to be explained.

## Event types in system.part_log

| event_type | Written when | Reading it |
|------------|--------------|------------|
| `NewPart` | An insert creates a part, or a Buffer or materialized view flushes one | Rate equals insert batch rate. One part per insert per partition. |
| `MergeParts` | A background merge produces a part | `rows` and `size_in_bytes` describe the result; `duration_ms` is the merge time. |
| `MutatePart` | ALTER UPDATE, ALTER DELETE or an index or TTL materialization rewrites a part | One row per rewritten part, so one mutation over 500 parts writes 500 rows. |
| `DownloadPart` | A replica fetches a part from another replica instead of merging it locally | Normal after a restart or while catching up; sustained volume means replication trouble. |
| `RemovePart` | A part is removed from the working set | Follows every merge (source parts), TTL cleanup and DROP or DETACH PARTITION. |
| `MovePart` | A part moves between volumes or disks | Storage policy moves, TTL TO DISK or TO VOLUME, or a manual MOVE PARTITION. |

`error` is zero for a successful event. A non-zero value carries the ClickHouse error code and `exception` holds the message.

## Useful columns

`event_time` and `duration_ms` give rate and latency. `rows` and `size_in_bytes` give volume. `part_name` and `partition_id` identify the object. `merged_from` lists the source parts of a merge, which is how a merge tree of a given part can be reconstructed. `peak_memory_usage` shows what a merge or mutation cost in RAM.

## Settings that shape these rates

| Setting | Scope | Effect |
|---------|-------|--------|
| `parts_to_delay_insert` | Table | Inserts begin sleeping when a partition exceeds this part count. |
| `parts_to_throw_insert` | Table | Inserts fail with TOO_MANY_PARTS past this count. |
| `max_bytes_to_merge_at_max_space_in_pool` | Table | Caps merge size, and therefore the largest part. |
| `background_pool_size` | Server | Number of concurrent merges and mutations. |
| `min_bytes_for_wide_part` | Table | Decides Compact versus Wide storage for new parts. |
| `async_insert` | Query or profile | Batches small inserts server side, which is the usual fix for a high NewPart rate. |
| `max_insert_block_size` | Query | Splits one insert into several parts when the block is large. |

## Retention

`system.part_log` is written only when the `part_log` block exists in the server config, and its history is bounded by its TTL. A short TTL silently narrows every window in this skill.
