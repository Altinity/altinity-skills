# Memory reference

Background for the memory skill. Read only when a recommendation needs to be explained.

## Memory limit settings

| Setting | Scope | Notes |
|---------|-------|-------|
| `max_memory_usage` | Query | Per-query limit. 0 means unlimited. |
| `max_memory_usage_for_user` | User | Aggregate limit across that user's concurrent queries. |
| `max_server_memory_usage` | Server | Hard global limit. 0 means "derive from the ratio below". |
| `max_server_memory_usage_to_ram_ratio` | Server | Global limit as a fraction of total RAM (0.9 by default). Lower it when other processes share the host. |
| `max_bytes_before_external_group_by` | Query | Spills aggregation state to disk past this size. Usually set to half of `max_memory_usage`. |
| `max_bytes_before_external_sort` | Query | Same idea for ORDER BY. |
| `max_bytes_in_join` | Query | Limit for the hash table built by a JOIN. |
| `join_algorithm` | Query | `hash` is fastest and most memory hungry; `partial_merge` and `grace_hash` trade CPU for RAM; `auto` switches once `max_bytes_in_join` is reached. |
| `max_concurrent_queries` | Server | Concurrency is a memory multiplier: peak RAM is roughly per-query peak times concurrent queries. |

## Where non-query memory goes

- Mark cache and uncompressed cache: sized by `mark_cache_size` and `uncompressed_cache_size`. Counted in `MemoryResident`, not in per-query tracking.
- Primary keys: `primary_key_bytes_in_memory` per active part, resident for the life of the part.
- Dictionaries: `bytes_allocated` in `system.dictionaries`, resident until the dictionary is dropped or reloaded.
- Memory, Set and Join engine tables: fully resident, no spill path.
- Allocator overhead: jemalloc retains freed arenas, so `MemoryResident` lags `MemoryTracking` downward after a spike.

## Anti-patterns

- Raising `max_server_memory_usage_to_ram_ratio` above 0.9 on a host that also runs an agent, a backup job or Keeper.
- Using `max_memory_usage = 0` for interactive users.
- Flat-layout dictionaries keyed by a sparse UInt64: the flat array is sized by the maximum key, not by the row count.
- Wide ORDER BY keys with small `index_granularity`: both multiply primary-key RAM across every part.
