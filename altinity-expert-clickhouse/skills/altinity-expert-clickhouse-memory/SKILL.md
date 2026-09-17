---
name: altinity-expert-clickhouse-memory
description: Diagnoses ClickHouse RAM usage, memory limits, OOM errors and the allocation breakdown across queries, caches, dictionaries and primary keys. Use when MEMORY_LIMIT_EXCEEDED appears, the server is killed by the OOM killer, memory grows steadily, or GROUP BY and JOIN queries run out of memory.
license: Apache-2.0
---

# Memory usage and OOM diagnostics

Answers "where is the RAM going, and what will OOM next?" from `system.asynchronous_metrics`, `system.metrics`, `system.dictionaries`, `system.parts`, `system.server_settings` and `system.query_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 15 checks: RAM total vs ClickHouse resident, component breakdown (dictionaries, Memory/Set/Join tables, primary keys, caches), allocation audit, top memory consumers among queries, dictionaries, Memory-engine tables and primary keys, memory over time, MEMORY_LIMIT_EXCEEDED exceptions, a query plus part_log memory timeline, server memory settings, memory used by non-ClickHouse processes, and high-memory GROUP BY and JOIN query shapes. Check memory-08 needs `system.asynchronous_metric_log` and memory-11 needs `system.part_log`; skip them when those tables are absent.
- `reference.md` — background (settings, sizing, anti-patterns); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- memory-01 grades ClickHouse resident against total RAM (`Critical` above 90 percent, `Major` above 80). Compare it with memory-13 before blaming queries.
- A large gap between `MemoryTracking` and `MemoryResident` means untracked allocations: caches, allocator fragmentation, or memory jemalloc has not returned to the OS. Tuning per-query limits will not close that gap; check cache sizes and consider a restart or `SYSTEM JEMALLOC PURGE`.
- memory-13 `Critical` means other processes occupy the RAM reserved by `max_server_memory_usage_to_ram_ratio`. Fix the colocation or lower the ratio; raising ClickHouse limits makes the OOM killer more likely, not less.
- memory-10 rows are exception code 241 (MEMORY_LIMIT_EXCEEDED). Read the limit named in the message: a per-query limit points at the query, a total-server limit points at concurrency or at the resident baseline from memory-02.
- High memory from aggregations (memory-14): set `max_bytes_before_external_group_by` to spill to disk, lower `max_threads` to cut per-thread hash tables, and reduce GROUP BY cardinality.
- High memory from JOINs (memory-15): set `max_bytes_in_join`, switch `join_algorithm` to `partial_merge` or `auto`, and put the smaller table on the right side of the join.
- Large `primary_key_bytes_in_memory` (memory-02, memory-07) is a schema problem: too many columns in ORDER BY or an `index_granularity` that is too small. It is loaded for every active part and never evicted.
- Large dictionary allocation (memory-02, memory-05) is permanent RAM. `complex_key_hashed` and `flat` layouts dominate; a `cache` or `direct` layout trades RAM for latency.
- Memory-engine tables (memory-06) and large `Set`/`Join` tables hold everything in RAM with no spill path. Treat any multi-GiB entry here as a design finding.

## Deep-dive statements

Live per-query memory, to catch the consumer while it is still running:

```sql
SELECT query_id, user, round(elapsed, 1) AS elapsed_s, formatReadableSize(memory_usage) AS memory, substring(query, 1, 120) AS query_preview FROM system.processes ORDER BY memory_usage DESC LIMIT 10;
```

Primary-key RAM and mark count for one table named by memory-07:

```sql
SELECT database, table, formatReadableSize(sum(primary_key_bytes_in_memory)) AS pk_ram, sum(marks) AS marks, count() AS parts FROM system.parts WHERE active AND database = '{database}' AND table = '{table}' GROUP BY database, table;
```

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Merge or mutation memory dominates the timeline → load skill `altinity-expert-clickhouse-merges`
- Dictionaries hold a large share of RAM or fail to load → load skill `altinity-expert-clickhouse-dictionaries`
- Mark or uncompressed cache is a large share of resident memory → load skill `altinity-expert-clickhouse-caches`
- Primary-key RAM is high, or ORDER BY and granularity need rework → load skill `altinity-expert-clickhouse-schema`
- Individual queries OOM and need rewriting or limits → load skill `altinity-expert-clickhouse-reporting`
- Memory saturation over time, load average or pool saturation → load skill `altinity-expert-clickhouse-metrics`
