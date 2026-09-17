---
name: altinity-expert-clickhouse-metrics
description: Resource saturation from system.metrics, system.events and system.asynchronous_metrics - memory, load average, connections, running queries, background pools, parts per partition, block device queues - plus short history. Use when the server feels slow or overloaded, queries queue or get rejected, or load and connection trends are needed.
license: Apache-2.0
---

# Real-time metrics and saturation

Answers "which resource is saturated right now, and was it saturated an hour ago?" from `system.metrics`, `system.events`, `system.asynchronous_metrics`, `system.metric_log` and `system.asynchronous_metric_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 12 checks (ids metrics-01 to metrics-12) in 14 statements: saturation summary for memory, running queries and connections; load average versus CPU cores; replication metrics; max parts per partition versus the insert thresholds; background pool utilization; failure and throttling counters since start; memory and load average over the last 6 hours; query rate over the last hour; block device queue depth; uptime and version; Prometheus endpoint configuration. Checks metrics-02 and metrics-10 exist twice with complementary `@requires version<26.8` and `@requires version>=26.8` headers: run only the one matching the server version. Checks metrics-07 and metrics-08 need `system.asynchronous_metric_log`, metrics-09 needs `system.metric_log`.
- `reference.md` — background (settings, sizing, anti-patterns); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- Saturation percentages and their severities are computed in SQL. Copy them. The rules below say what a saturated resource means.
- Load average above the CPU core count sustained over 15 minutes means the host is CPU bound, not merely busy. A high 1-minute load with a normal 15-minute load is a spike and usually needs no action.
- Running queries approaching `max_concurrent_queries` means new queries will queue and then fail with TOO_MANY_SIMULTANEOUS_QUERIES. Fix the slow queries first; raising the limit converts rejections into memory pressure.
- Connections approaching `max_connections` surface on the client side as connection timeouts, not as ClickHouse errors. Check for connection-pool leaks before raising the limit.
- Block device in-flight operations above 128 mean the disk queue is saturated and every read waits behind it. Above 200 the device is the bottleneck regardless of what ClickHouse is doing.
- Max parts per partition above `parts_to_delay_insert` is already slowing inserts; above `parts_to_throw_insert` inserts fail with TOO_MANY_PARTS. Both are merge problems, not insert problems.
- Non-zero `RejectedInserts` or `DelayedInserts` in metrics-06 confirms insert throttling caused by part counts.
- Non-zero `ZooKeeperHardwareExceptions` means lost Keeper sessions, which stall replication and ON CLUSTER DDL. `ZooKeeperUserExceptions` are mostly benign (node exists, node missing).
- metrics-06 counters are cumulative since server start, so read them together with uptime from metrics-11. A large counter on a host with months of uptime may be historical.
- Uptime below one hour means the server restarted inside the observed window. Check `system.crash_log` and `system.text_log` for the cause before trusting any counter or rate in this report.
- metrics-12 reporting no Prometheus endpoint is a monitoring gap, not a server fault. Report it as `Minor`.

## Deep-dive statements

Find every metric, asynchronous metric and event whose name matches a pattern, when a check points at something the packs do not cover:

```sql
SELECT 'metrics' AS source, metric AS name, toString(value) AS value, description FROM system.metrics WHERE metric ILIKE '%{pattern}%' UNION ALL SELECT 'asynchronous_metrics', metric, toString(value), description FROM system.asynchronous_metrics WHERE metric ILIKE '%{pattern}%' UNION ALL SELECT 'events', event, toString(value), description FROM system.events WHERE event ILIKE '%{pattern}%' ORDER BY source, name;
```

Plot one asynchronous metric over the last 6 hours in 15-minute buckets:

```sql
SELECT toStartOfFifteenMinutes(event_time) AS ts, round(avg(value), 2) AS avg_value, round(max(value), 2) AS max_value FROM system.asynchronous_metric_log WHERE event_time > now() - INTERVAL 6 HOUR AND metric = '{metric}' GROUP BY ts ORDER BY ts;
```

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Memory saturation, or MEMORY_LIMIT_EXCEEDED among the counters → load skill `altinity-expert-clickhouse-memory`
- Readonly replicas, replica delay, queue growth or Keeper hardware exceptions → load skill `altinity-expert-clickhouse-replication`
- Parts per partition near the delay or throw thresholds, or a saturated MergesAndMutations pool → load skill `altinity-expert-clickhouse-merges`
- Rejected or delayed inserts → load skill `altinity-expert-clickhouse-ingestion`
- High load average or many running queries traced to specific queries → load skill `altinity-expert-clickhouse-reporting`
- Disk queue saturation or slow devices → load skill `altinity-expert-clickhouse-storage`
- Recent restart or crash to explain → load skill `altinity-expert-clickhouse-logs`
- Part creation, merge and removal rates behind the counters → load skill `altinity-expert-clickhouse-part-log`
