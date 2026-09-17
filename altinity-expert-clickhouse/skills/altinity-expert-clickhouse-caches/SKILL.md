---
name: altinity-expert-clickhouse-caches
description: Analyzes the ClickHouse mark cache, uncompressed cache, query cache and compiled expression cache, their hit ratios and their RAM footprint. Use when cache hit ratios are poor, caches take too much RAM, mark counts look excessive, or cache sizing needs tuning.
license: Apache-2.0
---

# Cache analysis and tuning

Answers "are the caches sized right and are they helping?" from `system.metrics`, `system.asynchronous_metrics`, `system.events`, `system.parts`, `system.server_settings` and `system.metric_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 12 checks: mark cache health (hit ratio and RAM share), uncompressed cache health, query cache, compiled expression cache, mark bytes per table, primary-key memory per table, cache events over time, current cache server settings, mark-cache sizing analysis, a hit-ratio diagnostic over the tables queried today, tables holding excessive marks, and the mark-cache hit ratio minute by minute for the last hour. Check caches-07 needs `system.asynchronous_metric_log` and caches-12 needs `system.metric_log`; skip them when those tables are absent.
- `reference.md` — background (settings, sizing, anti-patterns); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- caches-01 and caches-02 return two verdict columns, `hit_severity` and `size_severity`. Copy both; a cache can be well sized and still useless, or effective and still too large.
- Mark cache hit ratio below 0.7 is `Moderate`, below 0.5 `Major`, below 0.3 `Critical`. The causes are, in order: the cache is too small for the working set, queries touch many different tables, or the workload is many small queries against cold data. Use caches-10 to tell these apart before resizing.
- Mark cache above 15 percent of RAM is a finding even with a perfect hit ratio. Fix the cause in this order: raise `index_granularity` on the tables in caches-11, let merges reduce the number of tiny parts, drop unused tables, and only then lower `mark_cache_size`. Never lower `index_granularity` to shrink the cache; a smaller granularity produces more marks, not fewer.
- caches-09 gives the target: ideal mark cache is min(total marks on disk, 15 percent of RAM). If total marks already exceed that, the cache cannot hold the working set and the schema is the problem.
- An uncompressed cache hit ratio near zero with many misses is `Moderate`, not `Critical`. Size 0 (disabled) is a legitimate production choice; the cache only pays off for repeated small point reads with `use_uncompressed_cache` enabled per query or per profile.
- caches-08 lists server settings only. `mark_cache_size` and `uncompressed_cache_size` are server settings; the query cache size lives in the server config as `<query_cache><max_size_in_bytes>` and may therefore be absent from the result. `use_query_cache` and `use_uncompressed_cache` are query-level settings and never appear here.
- Query cache misses dominated by non-deterministic or one-off queries are expected. The query cache only helps identical, repeated, deterministic queries.
- caches-06 primary-key memory is not a cache and is not evictable. Report it separately from cache sizing.

## Deep-dive statements

Marks per table inside one database, to find what fills the mark cache:

```sql
SELECT table, count() AS parts, sum(marks) AS marks, formatReadableSize(sum(marks_bytes)) AS marks_size, formatReadableSize(sum(bytes_on_disk)) AS data_size FROM system.parts WHERE active AND database = '{database}' GROUP BY table ORDER BY sum(marks_bytes) DESC LIMIT 20;
```

The `index_granularity` actually in force for one table, to confirm before recommending a change:

```sql
SELECT database, table, engine, create_table_query FROM system.tables WHERE database = '{database}' AND name = '{table}';
```

Largest query cache entries, when caches-03 shows the cache filling up:

```sql
SELECT substring(query, 1, 120) AS query_preview, formatReadableSize(result_size) AS result_size, stale, shared, expires_at FROM system.query_cache ORDER BY result_size DESC LIMIT 20;
```

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Caches are a large share of total RAM, or the server is near its memory limit → load skill `altinity-expert-clickhouse-memory`
- Poor hit ratio together with high disk read IO → load skill `altinity-expert-clickhouse-storage`
- Excessive marks from small `index_granularity` or a wide ORDER BY → load skill `altinity-expert-clickhouse-schema`
- Many tiny parts inflating the mark count → load skill `altinity-expert-clickhouse-merges`
- Query cache misses or repeated expensive queries → load skill `altinity-expert-clickhouse-reporting`
