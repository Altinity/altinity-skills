---
name: altinity-expert-clickhouse-storage
description: Diagnoses ClickHouse disk usage, compression efficiency, part sizes, storage policies and IO throughput. Use when disks fill up, data grows faster than expected, compression looks poor, IO or merges are slow, or detached and tiny parts accumulate.
license: Apache-2.0
---

# Storage and disk usage analysis

Answers "where is the disk going, is the data compressed well, and is the disk keeping up?" from `system.disks`, `system.parts`, `system.columns`, `system.detached_parts`, `system.storage_policies`, `system.asynchronous_metrics`, `system.query_log` and `system.part_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 19 checks: disk free space with severity, size by database and by table, usage by path, overall and per-table compression ratio, columns compressing worse than 2x, part size distribution, small-part detection, Wide vs Compact part mix, disk IO metrics, recent IO from the query log, the heaviest IO queries, system log disk usage, detached parts with reasons, storage policies and the tables using them, what grew in the last hour, and merge throughput as a proxy for disk speed. Check storage-19 needs `system.part_log`; skip it when that table is absent.
- `reference.md` — background (settings, sizing, anti-patterns); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- storage-01 grades free space: above 80 percent used is `Moderate`, above 85 `Major`, above 90 `Critical`. Treat `Major` as act-today. MergeTree needs free space at least as large as the biggest merge it will run, so a disk at 90 percent stops merging long before it stops accepting inserts.
- Compression ratio below 2 (storage-06, storage-07) means the column type or codec is wrong, not that the data is incompressible. Add an explicit codec: `ZSTD` for general data, `Delta, ZSTD` for sequential integers, `DoubleDelta, ZSTD` for timestamps, and `LowCardinality(String)` for repetitive strings. A ratio between 2 and 5 is normal; above 5 is good.
- storage-09 returns only tables where more than half the parts are under 10 MB and there are more than 10 parts. That is either merge backlog or micro-batched inserts, never a storage problem by itself.
- storage-10 Wide vs Compact: parts smaller than `min_bytes_for_wide_part` (10 MiB by default) are stored Compact, one file for all columns. Many Wide tiny parts means the threshold was lowered and every part now costs one file pair per column. A large table stored entirely Compact means the threshold was raised and per-column reads lost their granularity.
- storage-15 detached parts: reasons starting with `broken`, `unexpected`, `noquorum` or `ignored` point at corruption, failed operations or replication and need investigation before removal. `clone` and `covered-by-broken` are leftovers that are safe to drop once disk space is needed.
- storage-18 lists what grew in the last hour. Compare it with storage-03: a table that is small overall but top of this list is the one that will fill the disk.
- storage-19 reports merge throughput in bytes per second. Sustained throughput far below the rest of the tables on the same disk indicates a slow or saturated device; object-storage disks are legitimately slower and should be compared only against each other.
- storage-14 large system log tables are a retention problem, not a capacity problem. Do not recommend adding disk for them.

## Deep-dive statements

Per-column compressed size and codec for one table, to target codec changes:

```sql
SELECT name AS column, type, compression_codec, formatReadableSize(sum(data_compressed_bytes)) AS compressed, formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed, round(sum(data_uncompressed_bytes) / nullIf(sum(data_compressed_bytes), 0), 2) AS ratio FROM system.columns WHERE database = '{database}' AND table = '{table}' GROUP BY column, type, compression_codec ORDER BY sum(data_compressed_bytes) DESC;
```

Size per partition for one table, to decide what to drop or move:

```sql
SELECT partition, count() AS parts, sum(rows) AS rows, formatReadableSize(sum(bytes_on_disk)) AS size, min(min_date) AS from_date, max(max_date) AS to_date FROM system.parts WHERE active AND database = '{database}' AND table = '{table}' GROUP BY partition ORDER BY partition;
```

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Poor compression, wrong column types, or partitioning that produces tiny parts → load skill `altinity-expert-clickhouse-schema`
- Many small parts, merge backlog, or slow merge throughput → load skill `altinity-expert-clickhouse-merges`
- High write IO or micro-batched inserts → load skill `altinity-expert-clickhouse-ingestion`
- System log tables among the largest objects → load skill `altinity-expert-clickhouse-logs`
- Detached parts with `broken` or `noquorum` reasons → load skill `altinity-expert-clickhouse-replication`
- Part creation, merge and removal rates over time → load skill `altinity-expert-clickhouse-part-log`
- Caches or primary keys competing for RAM on the same host → load skill `altinity-expert-clickhouse-memory`
