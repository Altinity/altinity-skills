# Merges reference

Background material for `altinity-expert-clickhouse-merges`. Read only when you
need to explain or justify a recommendation.

## Merge-size and TTL settings

Read the current values from `system.merge_tree_settings` and compare with the
defaults before proposing a change. Only the settings whose `changed` flag is 1
were tuned on this server.

| Setting | What it controls | Typical direction when merges lag |
|---|---|---|
| `max_parts_to_merge_at_once` | Parts per merge task | Raise to consolidate many small parts faster |
| `max_bytes_to_merge_at_max_space_in_pool` | Largest merge when the pool is idle | Lower if large merges starve small ones or OOM |
| `max_bytes_to_merge_at_min_space_in_pool` | Largest merge when the pool is busy | Lower under disk or memory pressure |
| `enable_vertical_merge_algorithm` | Allows the vertical (column-by-column) merge | Keep enabled on wide tables |
| `vertical_merge_algorithm_min_rows_to_activate` | Row threshold for vertical merges | Lower so wide-table merges go vertical sooner |
| `vertical_merge_algorithm_min_columns_to_activate` | Column threshold for vertical merges | Lower on very wide tables |
| `max_number_of_merges_with_ttl_in_pool` | Concurrent TTL merges per server | Raise when TTL merges queue up, lower when they crowd out regular merges |
| `max_replicated_merges_with_ttl_in_queue` | Concurrent TTL merges in the replication queue | Same trade-off on replicated tables |
| `parts_to_delay_insert` | Part count at which inserts are throttled | Raise only as a temporary mitigation |
| `parts_to_throw_insert` | Part count at which inserts fail with TOO_MANY_PARTS | Raise only as a temporary mitigation |

Raising `parts_to_delay_insert` or `parts_to_throw_insert` hides the symptom and
buys time. It does not make merges faster, so pair it with a real fix.

## Pool capacity

Merge concurrency is bounded by `background_pool_size` (and
`background_merges_mutations_concurrency_ratio` on newer versions). When the
MergesAndMutations pool is above 90 percent utilized, merges are limited by
capacity, not by data volume, and settings that allow larger merges will not
help.

## Ad-hoc query safeguards

When writing extra queries against log tables:

- Always add a `LIMIT`.
- Always bound historical queries by `event_time`.
- Always filter `system.part_log` by `event_type` (`NewPart`, `MergeParts`,
  `MutatePart`).
- Never run `SELECT * FROM system.part_log` or any unbounded scan of a `*_log`
  table.
- Aggregate in SQL rather than pulling rows back and joining them by hand.
