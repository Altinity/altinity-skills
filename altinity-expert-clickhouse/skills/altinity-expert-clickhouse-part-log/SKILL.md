---
name: altinity-expert-clickhouse-part-log
description: Diagnoses part lifecycle problems from system.part_log - part creation, merges, mutations, downloads, removals and moves. Use when there are too many parts or micro-batch inserts, merge backlog or slow merges, mutation storms from ALTER UPDATE or DELETE, unusual DownloadPart replication churn, unexpected RemovePart spikes, or Keeper znode growth tied to part activity.
license: Apache-2.0
---

# Part lifecycle diagnostics

Answers "what is happening to parts, how fast, and is anything failing?" from `system.part_log`, read as rate (events per minute), volume (rows and bytes) and errors.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 11 checks: part_log coverage sanity, part activity timeline by minute, NewPart rate per table, merge balance of new parts versus merges, merge duration distribution, MutatePart rate, outstanding mutation backlog, DownloadPart spikes, RemovePart spikes, MovePart spikes, and part_log rows with a non-zero error. Ten of the eleven need `system.part_log`; only part-log-07 reads `system.mutations` instead. If `system.part_log` does not exist, skip every other check and report that part_log is not enabled, since no part-lifecycle conclusion can be drawn without it.
- `reference.md` — background (event types, part lifecycle, settings); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- This pack computes no `severity`. Grade findings yourself with the rules below and say which rule you applied.
- part-log-01 first: if the oldest event is more recent than the requested window, part_log was enabled recently or its TTL is short. Say so, and treat every rate below as covering the shorter window.
- Micro-batching: more than 60 NewPart events per minute for one table (more than one part per second), or an average part under 1 MB or under 10,000 rows, means inserts are too small. Each part costs a merge, marks and file handles.
- NewPart rate much higher than the MergeParts rate (part-log-04) means the part count is growing and merges are falling behind. That ends in TOO_MANY_PARTS whatever the current part count looks like.
- Merge duration (part-log-05): p95 far above p50, or p95 growing over the window, means merge pressure. Distinguish the causes by bytes merged: large p95 with large bytes is normal big-merge work, large p95 with small bytes means the disk or the merge pool is the constraint.
- MutatePart storms (part-log-06) mean ALTER UPDATE or ALTER DELETE is rewriting many parts. Each mutation rewrites whole parts, so a frequent small mutation costs far more IO than the rows it touches. Recurring mutations usually indicate a design that should use a ReplacingMergeTree, a CollapsingMergeTree or a lightweight delete instead.
- DownloadPart spikes (part-log-08) mean the replica fetched parts instead of merging locally: replica restart, lag catch-up, network or disk trouble, or parts lost and refetched. Sustained downloads on a healthy replica point at replication, not at ingestion.
- RemovePart spikes (part-log-09) come from TTL cleanup, DROP or DETACH PARTITION, mutation cleanup, or the ordinary removal of source parts after a merge. Correlate with MergeParts in the same minutes before calling it data loss.
- MovePart spikes (part-log-10) mean storage policy movement, tiering or manual moves. Unexpected moves usually mean a TTL TO VOLUME or TTL TO DISK rule fired.
- part-log-11 rows are always findings: a non-zero `error` is a failed merge, mutation or fetch. Report the exception text and count, and treat a repeating error on one table as `Major` or worse.

## Deep-dive statements

Full event breakdown for one table named by an earlier check:

```sql
SELECT event_type, count() AS events, sum(rows) AS rows_sum, formatReadableSize(sum(size_in_bytes)) AS bytes_sum, round(avg(duration_ms)) AS avg_ms, countIf(error != 0) AS errors FROM system.part_log WHERE event_time > now() - INTERVAL 24 HOUR AND database = '{database}' AND table = '{table}' GROUP BY event_type ORDER BY events DESC;
```

Insert batch size distribution for one table, to confirm micro-batching:

```sql
SELECT count() AS new_parts, quantiles(0.5, 0.9, 0.99)(rows) AS rows_p50_p90_p99, quantiles(0.5, 0.9, 0.99)(size_in_bytes) AS bytes_p50_p90_p99 FROM system.part_log WHERE event_time > now() - INTERVAL 1 HOUR AND event_type = 'NewPart' AND database = '{database}' AND table = '{table}';
```

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- High NewPart rate or micro-batched inserts → load skill `altinity-expert-clickhouse-ingestion`
- Merges falling behind, slow merges, or merge errors → load skill `altinity-expert-clickhouse-merges`
- High MutatePart rate or an outstanding mutation backlog → load skill `altinity-expert-clickhouse-mutations`
- Many DownloadPart events or fetch errors → load skill `altinity-expert-clickhouse-replication`
- Slow merges with low throughput, or MovePart activity between volumes → load skill `altinity-expert-clickhouse-storage`
- Table design encouraging tiny parts or frequent mutations → load skill `altinity-expert-clickhouse-schema`
- part_log missing or its retention too short → load skill `altinity-expert-clickhouse-logs`
