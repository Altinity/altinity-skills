---
name: altinity-expert-clickhouse-ingestion
description: Diagnoses ClickHouse INSERT performance, batch sizing, part creation patterns and materialized-view overhead on inserts. Use for slow inserts, failed inserts, micro-batching, high part creation rate, Buffer table flushes and data pipeline issues.
license: Apache-2.0
---

# INSERT and ingestion performance

Answers "why are inserts slow, failing, or creating too many parts" from `system.query_log`, `system.part_log`, `system.query_views_log`, `system.kafka_consumers`, `system.processes` and `system.text_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 14 checks: Kafka consumer health and scheduling capacity, running and recent insert activity, part creation rate per table, insert vs merge balance, slow inserts, materialized-view overhead on inserts, failed inserts, batch size distribution, Kafka engine ingestion, Kafka messages in the log, Buffer table flush patterns and current insert-related settings. 2 of them need `system.part_log`, 1 needs `system.query_views_log`, 1 needs `system.text_log`.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Deep-dive statements

When a slow insert has a known `query_id`, break its duration down by materialized view. Substitute `{query_id}` with the id taken from check ingestion-07 or ingestion-08.

```sql
SELECT
    view_name,
    view_duration_ms,
    read_rows,
    written_rows,
    status,
    exception
FROM system.query_views_log
WHERE query_id = '{query_id}'
ORDER BY view_duration_ms DESC;
```

## Interpretation rules

- Average `written_rows` below 1000 per insert is micro-batching: the client is paying part-creation cost per row. Recommend batching to 10k-1M rows per INSERT, or enabling `async_insert` when the client cannot batch. Check ingestion-10 returns `batch_status`, not `severity`; treat "Seriously under-batched" as Major and "Could improve" as Moderate.
- Many `NewPart` events with few `MergeParts` events in the same window (ingestion-06) means merges are not keeping up with ingestion, not that inserts are too slow. The insert side is healthy; the merge side is the finding.
- When `system.query_views_log` shows view duration dominating the insert duration (ingestion-08), the fix is the materialized view query, not the insert. Name the slowest views and their share of the insert time.
- Buffer tables add flush latency of their own: rows are visible only after a flush, and a large Buffer adds memory and a loss window on restart. Flush patterns in ingestion-13 explain insert-to-visibility delay that query_log alone does not show.
- Checks marked `@requires table:system.part_log` are skipped when part_log is disabled. Say so explicitly instead of concluding that part creation is normal; without part_log the part creation rate and the insert/merge balance are unknown.
- Failed inserts (ingestion-09) with TOO_MANY_PARTS or "Too many parts" text are a merge backlog symptom, not an insert bug. MEMORY_LIMIT_EXCEEDED on an insert usually comes from a materialized view or from a very large single batch.
- Kafka checks (ingestion-01, -02, -11, -12) only summarize here. Rising poll or commit age, or a non-empty exception array, is the trigger to move to the Kafka skill rather than to drill down in this one.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Kafka consumer lag, consumer exceptions, rebalances, or consumers above pool size → load skill `altinity-expert-clickhouse-kafka`
- Part creation outpacing merges, TOO_MANY_PARTS, many parts per partition → load skill `altinity-expert-clickhouse-merges`
- Materialized view query itself is slow or reads too much → load skill `altinity-expert-clickhouse-reporting`
- Inserts failing with MEMORY_LIMIT_EXCEEDED or high peak memory → load skill `altinity-expert-clickhouse-memory`
- Partition key too granular, wide tables, or materialized view design problems → load skill `altinity-expert-clickhouse-schema`
- Insert latency tracking disk or write throughput → load skill `altinity-expert-clickhouse-storage`
- Inserts blocked on replicated tables or `insert_quorum` waits → load skill `altinity-expert-clickhouse-replication`
