---
name: altinity-expert-clickhouse-logs
description: Checks ClickHouse system log tables for freshness, TTL, disk footprint, upgrade leftovers and crash records. Use when system tables eat the disk, query_log or part_log has no recent data, retention for system.*_log needs review, or the server appears to have crashed.
license: Apache-2.0
---

# System log table health

Answers "are the system logs usable and are they eating the disk?" from `system.tables`, `system.parts`, `system.disks`, `system.query_thread_log` and `system.crash_log`. Other skills depend on these tables, so run this first when a pack returns no data.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 6 checks emitting Altinity ids A0.2.01 through A0.2.08: query_log and part_log freshness, query_log data older than 30 days, system log tables without TTL, system logs using more than 20 percent of a disk, `system.*_logN` leftovers from version upgrades, query_thread_log still enabled, and recent crash_log records. Every statement returns rows only when a rule is broken, so an empty result is OK. Check A0.2.01 needs `system.part_log`, A0.2.07 needs `system.query_thread_log` and A0.2.08 needs `system.crash_log`; skip them when those tables are absent.
- `reference.md` — background (settings, sizing, anti-patterns); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- No fresh records in query_log or part_log (A0.2.01, A0.2.02) means the log is disabled or the server restarted recently, not that the server is idle. Report it as a blocker for the skills that need those tables rather than as a healthy result.
- A system log table with no TTL (A0.2.04) grows until the disk fills. Recommended retention, applied with `ALTER TABLE system.<name> MODIFY TTL event_date + INTERVAL <n> DAY`:

| Table | Retention | Notes |
|-------|-----------|-------|
| query_log | 7-30 days | The main forensic table; keep 30 days if disk allows. |
| query_thread_log | disable, or 3 days | One row per thread per query. Very verbose and rarely needed. |
| part_log | 14-30 days | Needed for merge, mutation and ingestion root cause analysis. |
| trace_log | 3-7 days | Large; only useful while profiling. |
| text_log | 7-14 days | Needed to read errors and warnings in context. |
| metric_log | 7-14 days | One row per second per host; useful for trending. |
| asynchronous_metric_log | 7-14 days | Low volume. |
| crash_log | 90 days or more | Tiny and rarely written; keep it long. |

- `system.*_log1`, `*_log2` and similar (A0.2.06) are leftovers: on upgrade ClickHouse renames an incompatible log table and starts a new one. They are never read again and should be dropped once the old data is no longer needed.
- query_thread_log enabled (A0.2.07) is a finding on any busy server. Disable it in the server config unless a specific investigation needs per-thread data.
- Recent crash_log rows (A0.2.08) mean the server crashed, not merely restarted. Correlate with uptime and with warnings in `system.text_log` before attributing any other finding to the same incident.
- Changing TTL on a system log table only affects future cleanup. Reclaim existing space with `TRUNCATE TABLE system.<name>` or by dropping old partitions.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- System logs occupy a large share of a disk, or the disk is near full → load skill `altinity-expert-clickhouse-storage`
- part_log is present and fresh, and part or merge activity needs analysis → load skill `altinity-expert-clickhouse-part-log`
- Crash records or repeated restarts → load skill `altinity-expert-clickhouse-metrics`
- query_log is healthy and slow or failing queries need analysis → load skill `altinity-expert-clickhouse-reporting`
- Overall server health is still unknown → load skill `altinity-expert-clickhouse-overview`
