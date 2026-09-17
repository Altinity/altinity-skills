---
name: altinity-expert-clickhouse-dictionaries
description: Diagnoses ClickHouse external dictionaries - load status, memory usage, layout choice, reload staleness, source connectivity and lookup performance. Use for dictionary load failures, FAILED or LOADING_FAILED status, stale dictionary data, high dictionary RAM and slow dictGet lookups.
license: Apache-2.0
---

# Dictionary diagnostics

Answers "are the dictionaries loaded, fresh, and worth the RAM they cost" from `system.dictionaries`, `system.query_log`, `system.asynchronous_metrics` and `system.text_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 15 checks: dictionary inventory, health and load status, memory usage against server RAM, top dictionaries by memory, configuration and layout, staleness against `lifetime_max`, current failures, load errors in the log, lookup performance from query_log, hit and miss ratio, cache dictionary analysis, flat and hashed size check, source types, source connectivity for ClickHouse-sourced dictionaries and scheduled reload status. 1 of them needs `system.text_log`.
- `reference.md` — background (settings, sizing, anti-patterns); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Deep-dive statements

After a dictionary has been reloaded, or when one dictionary needs a closer look, read its load state directly. Substitute `{dictionary_name}` with the name from check dictionaries-02 or dictionaries-07.

```sql
SELECT
    database,
    name,
    status,
    loading_start_time,
    last_successful_update_time,
    loading_duration,
    element_count,
    formatReadableSize(bytes_allocated) AS memory,
    last_exception
FROM clusterAllReplicas('{cluster}', system.dictionaries)
WHERE name = '{dictionary_name}';
```

## Interpretation rules

- Status `FAILED` or `LOADING_FAILED` with a non-empty `last_exception` is a source problem, not a ClickHouse problem. Quote the exception text; it names the failing host, table or credential. `NOT_LOADED` is normal when `dictionaries_lazy_load` is on and nothing has queried the dictionary yet.
- `seconds_since_update` greater than `lifetime_max` means a reload is overdue or silently failing. Greater than twice `lifetime_max` means the dictionary is serving stale data and reloads have been failing for a while; pair it with the load errors from dictionaries-08 to find out which.
- `bytes_allocated / element_count` above 1000 bytes per key is a wasteful layout. A `flat` layout over sparse or high integer keys allocates for the whole key range; switch to `hashed` or `sparse_hashed`. When the working set is a small slice of a very large source, a `cache` or `ssd_cache` layout is cheaper than holding it all.
- A cache-type dictionary with a low hit ratio (dictionaries-10, dictionaries-11) is the wrong choice or is sized too small. Every miss becomes a synchronous round trip to the source, so a low hit ratio makes lookups slower than no dictionary at all. Either raise the cache size or switch to a hashed layout that holds everything.
- When the source is unreachable, check connectivity from the ClickHouse server host, not from the machine running this session. Dictionary sources are resolved by the server: DNS, firewall rules and credentials are the server's, and a source that works from a laptop can still fail on the server.
- To force a reload the user may run `SYSTEM RELOAD DICTIONARY` for one dictionary or `SYSTEM RELOAD DICTIONARIES` for all of them. Do not run either yourself: a reload of a large dictionary blocks lookups and re-reads the whole source, and reloading everything at once can spike memory on a busy server.
- Dictionary memory counts toward the server's total memory budget and is not reclaimed under pressure. When dictionaries-03 shows a double-digit percentage of RAM, that memory is unavailable to queries regardless of `max_server_memory_usage`.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Dictionary memory a large share of RAM, or queries failing on memory limits → load skill `altinity-expert-clickhouse-memory`
- Load failures needing the full exception text from the server log → load skill `altinity-expert-clickhouse-logs`
- Slow `dictGet` lookups dominating query time → load skill `altinity-expert-clickhouse-reporting`
- ClickHouse-sourced dictionary failing on a remote host or replica → load skill `altinity-expert-clickhouse-replication`
- Source query denied by permissions → load skill `altinity-expert-clickhouse-grants`
- Broad health picture or unclear problem area → load skill `altinity-expert-clickhouse-overview`
