---
name: altinity-expert-clickhouse-merges
description: Diagnose ClickHouse merge performance, part backlog, merge memory, and "too many parts" errors. Use when merges look stopped or slow, parts pile up, TOO_MANY_PARTS or parts_to_throw_insert is hit, or merges fail with MEMORY_LIMIT_EXCEEDED.
license: Apache-2.0
---

# Merge health and part backlog

Answers "are merges running, for which tables, and what is holding them back?" from `system.merges`, `system.part_log` and `system.parts`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 8 checks: current merge activity with memory, algorithm and type (merges-01), active merge memory per host and cluster-wide (merges-02, merges-03), merge success/failure trend by hour (merges-04), table-level merge verdict (merges-05), merge reason and algorithm matrix (merges-06), peak merge RAM per table (merges-07), part-count offenders (merges-08). Checks merges-04 through merges-07 need `system.part_log`.
- `reference.md` — background (merge and TTL settings, ad-hoc query safeguards); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

Run the checks in id order: current merges first (merges-01), then the historical trend (merges-04), then the table-level verdict (merges-05), then reason and algorithm (merges-06), then RAM now and peak (merges-02, merges-03, merges-07), then part-count offenders (merges-08).

- End the report with exactly one verdict: `PROVED` (no successful merge anywhere in the window), `DECLINED` (merges are succeeding cluster-wide), or `PARTIAL` (specific tables are blocked while others still merge).
- If any table has successful merges in the same window, the verdict is `PARTIAL` or `DECLINED`, never a global merge stop.
- A table with `merge_ok = 0` and repeated `MEMORY_LIMIT_EXCEEDED` is a table-level block, not a cluster-wide one.
- If merges are 100 percent `Horizontal`, say the planner chose horizontal merges. Do not claim the vertical algorithm is disabled unless the merge tree settings prove it.
- When the largest part counts in merges-08 come from `system.*` tables, call out the alert-source mismatch so the finding is not misattributed to business tables.
- Peak RAM from merges-07 is historical: a high peak with no current merge means the problem already happened, not that it is happening now.
- `system.part_log` missing: merges-04 through merges-07 are skipped, so a cluster-wide merge stop is not provable. Say "not provable without part_log" instead of choosing a verdict.

Structural causes worth naming when the evidence supports them:

- A single hot partition (`partition_id = 'all'`) makes every merge re-read the whole table; recommend time-based partitioning.
- A heavy `TTL ... GROUP BY ... SET ...` on a hot ingestion table serializes merges; move the rollup to a materialized view or a batch table and keep the base-table TTL delete-only.
- Repeated large horizontal merges that fail with OOM point at row width and part size, not at pool capacity.
- Persistent part growth with healthy merges means inserts outpace merges: fix the insert batch size and frequency, not the merge settings.

## Deep-dive statements

Insert versus merge rate for one table over the last hour. Negative `net_reduction` sustained across minutes means inserts outpace merges.

```sql
SELECT
    toStartOfMinute(event_time) AS minute,
    countIf(event_type = 'NewPart') AS new_parts,
    countIf(event_type = 'MergeParts') AS merges,
    countIf(event_type = 'MergeParts') - countIf(event_type = 'NewPart') AS net_reduction
FROM system.part_log
WHERE database = '{database}'
  AND table = '{table}'
  AND event_time > now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute DESC
LIMIT 60;
```

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

State the `PROVED`/`DECLINED`/`PARTIAL` verdict in the first line of the Findings section.

## Next skills

- Merges fail with MEMORY_LIMIT_EXCEEDED or peak merge RAM is close to the limit → load skill `altinity-expert-clickhouse-memory`
- Slow merges with normal disk throughput, or partitioning and ORDER BY look wrong → load skill `altinity-expert-clickhouse-schema`
- Slow merges with high disk IO or a full disk → load skill `altinity-expert-clickhouse-storage`
- Merge queue blocked behind mutations, or MutatePart errors → load skill `altinity-expert-clickhouse-mutations`
- Replication lag or a growing replication queue alongside merge problems → load skill `altinity-expert-clickhouse-replication`
- Part creation rate is the driver rather than merge capacity → load skill `altinity-expert-clickhouse-ingestion`
- Detailed per-part history needed → load skill `altinity-expert-clickhouse-part-log`
