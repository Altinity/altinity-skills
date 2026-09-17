---
name: altinity-expert-clickhouse-replication
description: Diagnose ClickHouse replication health, Keeper connectivity, read-only replicas, replica lag, replication queue backlog and slow fetches. Use for replication lag, read-only replica problems, growing replication queues, failed fetches, or Keeper/ZooKeeper session and latency errors.
license: Apache-2.0
---

# Replication and Keeper health

Answers "are the replicas connected, in sync, and draining their queues?" from `system.zookeeper_connection`, `system.replicas`, `system.replication_queue`, `system.replicated_fetches`, `system.events` and `system.text_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `triage.sql` — 2 checks: Keeper/ZooKeeper session status per host (replication-triage-01, `@requires keeper`), and the graded replication overview from `system.replicas` (replication-triage-02). Start here.
- `queue.sql` — 2 checks: graded queue size per table and host (replication-queue-01), and the individual queue tasks carrying an exception or a postpone reason (replication-queue-02).
- `fetches.sql` — 2 checks: fetches in flight with elapsed time and progress (replication-fetches-01), and recent `DownloadPart` activity (replication-fetches-02, needs `system.part_log`).
- `keeper.sql` — 2 checks: average Keeper round-trip latency per host derived from `ZooKeeperWaitMicroseconds` over `ZooKeeperTransactions` (replication-keeper-01), and Keeper errors and warnings from the last 24 hours (replication-keeper-02, needs `system.text_log`).

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- When the connection skill reported `has_keeper = 0`, this whole skill is not applicable. Say so and stop: without Keeper there are no replicated tables to diagnose.
- `is_readonly = 1` or `is_session_expired = 1` is Critical. The replica has lost its Keeper session and accepts no writes. Check Keeper connectivity first, then free disk space, then the server log.
- `active_replicas < total_replicas` means replicas are registered in Keeper but not alive. Name which hosts are missing and look for restarts, network partitions or a stopped server.
- Lag grading comes from the SQL: `absolute_delay` above 300 seconds or `queue_size` above 200 is Moderate; above 3600 seconds or above 1000 entries it is Major. Quote both numbers together, since a large queue with no delay means the replica is catching up and a large delay with an empty queue means it is not receiving work.
- Queue entries with a non-empty `last_exception` or `postpone_reason` identify the stuck table and the task type. Read `type` to route: `GET_PART` points at fetches, `MERGE_PARTS` at merges, `MUTATE_PART` at mutations.
- A high `num_tries` or `num_postponed` with a recent `last_exception_time` means the task is still retrying. The same values with an old exception time mean it already recovered.
- Many long-running fetches, or repeated `DownloadPart` errors in the part log, are themselves a cause of lag rather than a symptom. Check network throughput and the source replica before touching replication settings.
- A rising `avg_latency_us` in replication-keeper-01 correlates with lag and with read-only replicas. Treat slow Keeper as the root cause when latency is high on every host at once, and as a local problem when only one host is slow.
- Keeper latency is computed from cumulative counters since server start, so compare hosts against each other rather than against an absolute threshold.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- `part_mutations_in_queue` is high, or queue tasks fail with `MUTATE_PART` errors → load skill `altinity-expert-clickhouse-mutations`
- `merges_in_queue` is high, or queue tasks fail with `MERGE_PARTS` errors → load skill `altinity-expert-clickhouse-merges`
- Heavy `DownloadPart` churn or repeated fetch failures need per-part history → load skill `altinity-expert-clickhouse-part-log`
- Keeper errors need the full server log context, or `system.text_log` is missing → load skill `altinity-expert-clickhouse-logs`
- Replicas go read-only because a disk is full → load skill `altinity-expert-clickhouse-storage`
- Inserts fail or stall on replicated tables → load skill `altinity-expert-clickhouse-ingestion`
