---
name: altinity-expert-clickhouse-overview
description: Fast ClickHouse server health snapshot (object counts, memory, disks, replication summary, system log TTLs, error rates, background pools, detached parts) that routes to the specialist skills. Use as the entry point for "is the server healthy" or when the problem area is not yet known.
license: Apache-2.0
---

# Health overview and routing

Answers "is this server healthy, and which area needs a deeper look?" from `system.metrics`, `system.asynchronous_metrics`, `system.parts`, `system.disks`, `system.tables`, `system.query_log`, `system.errors` and `system.text_log`. It is single-host by design; per-replica divergence belongs to the specialist skills.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 14 checks: object counts, memory vs RAM, primary-key and dictionary RAM, disk usage, replication summary, system log TTL and size, hourly query error rate, part_log errors, `system.errors` top codes, detached parts, recent warnings in `text_log`, background pool utilization.
- `metrics.sql` — 13 alert checks (ids `A3.0.x`) that return rows only when a threshold is breached; an empty result is OK. Checks A3.0.4 and A3.0.5 have two version-specific alternatives (`@requires version<26.8` / `version>=26.8`): run the one matching the server version.
- `ddl_queue.sql` — 1 check on the ON CLUSTER DDL queue; `@requires keeper`.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- `metrics.sql` checks that return no rows are OK; list their ids in the OK line. `Minor` rows are informational, not findings.
- A system log table without TTL (overview-07) is a finding; quote its size from overview-08 next to it. Route to the logs skill only when the largest untended table exceeds a few GiB or the disk is above 70 percent.
- Error rate (overview-09): say whether failures are steady or a spike, and name the top error codes from overview-11. Ignore codes caused by this diagnostic session itself (UNKNOWN_IDENTIFIER, UNKNOWN_TABLE, SYNTAX_ERROR).
- Object counts (overview-01) and part counts are server-wide. When the largest part counts or sizes come from `system.*` tables, say so instead of blaming user tables.
- Detached parts (overview-12) with reasons `broken*`, `unexpected*`, `ignored*` indicate replication or disk problems; `clone` and `covered-by-broken` are usually safe to remove.
- Background pool utilization (overview-14) above 90 percent for MergesAndMutations means merges are throttled by capacity, not necessarily by data volume.
- With `has_keeper = 0`, mark replication and DDL queue checks as not applicable rather than OK.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Read-only replicas, replica delay, replication queue growth, Keeper errors in text_log → load skill `altinity-expert-clickhouse-replication`
- Memory above 80 percent of RAM, large primary-key or dictionary RAM, MEMORY_LIMIT_EXCEEDED errors → load skill `altinity-expert-clickhouse-memory`
- Disk above 80 percent or large system log tables → load skill `altinity-expert-clickhouse-storage` (disk) or `altinity-expert-clickhouse-logs` (log TTL)
- Many parts per partition, TOO_MANY_PARTS, saturated MergesAndMutations pool, part_log merge errors → load skill `altinity-expert-clickhouse-merges`
- High query error rate or slow SELECTs → load skill `altinity-expert-clickhouse-reporting`
- Slow or failing INSERTs, high NewPart rate → load skill `altinity-expert-clickhouse-ingestion`
- Kafka consumers above pool size or Kafka warnings in text_log → load skill `altinity-expert-clickhouse-kafka`
- Dictionary load failures or high dictionary RAM → load skill `altinity-expert-clickhouse-dictionaries`
- Stuck or failing mutations in part_log errors → load skill `altinity-expert-clickhouse-mutations`
- ACCESS_DENIED or authentication errors in system.errors → load skill `altinity-expert-clickhouse-grants`
- Load, connection or pool saturation over time → load skill `altinity-expert-clickhouse-metrics`
- Schema anti-patterns suspected (partitioning, ORDER BY, materialized views) → load skill `altinity-expert-clickhouse-schema`
