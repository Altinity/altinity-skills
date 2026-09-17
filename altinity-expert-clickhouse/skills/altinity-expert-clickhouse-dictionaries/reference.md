# Reference: dictionary background

Background for the dictionaries skill. Read only when you need to explain a recommendation.

## Layout by size and key shape

| Elements | Recommended layout |
|---|---|
| < 100K with dense sequential integer keys | `flat` |
| 100K - 10M | `hashed` |
| Sparse or non-sequential integer keys | `sparse_hashed` |
| > 10M with only part of the data actually queried | `cache` or `ssd_cache` |
| Composite keys | `complex_key_hashed` |
| Range lookups on a validity interval | `range_hashed` |

## Common failure patterns

| Symptom | Usual cause | Fix |
|---|---|---|
| High `bytes_allocated` per key | `flat` layout over a wide key range, or too many elements | Switch to `hashed` or `sparse_hashed`, or filter the source query |
| Slow reload | Large source table re-read in full | Add a WHERE filter, or configure an `update_field` for incremental updates |
| Stale data, status still LOADED | Source unreachable, reload failing silently | Check connectivity from the server host, inspect `last_exception` |
| Status FAILED | Source query itself fails | Verify the source table, query and credentials |
| Low cache hit ratio | Cache too small, or access pattern is not skewed | Raise the cache size, or move to a hashed layout |

## Settings

| Setting | Notes |
|---|---|
| `dictionaries_lazy_load` | When on, dictionaries load on first access instead of at startup; status stays NOT_LOADED until then. |
| `dictionary_load_wait_timeout_ms` | How long a query waits for a lazily loaded dictionary before failing. |
| `max_dictionary_num_to_warn` | Server warns above this many dictionaries. |
| `dictionary_use_async_executor` | Loads the source in parallel for dictionaries that support it. |
