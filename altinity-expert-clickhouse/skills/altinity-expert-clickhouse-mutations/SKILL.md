---
name: altinity-expert-clickhouse-mutations
description: Diagnoses ClickHouse mutations - ALTER UPDATE, ALTER DELETE, MATERIALIZE and column changes. Use for stuck mutations, mutations that never finish, latest_fail_reason errors, growing mutation queues and slow ALTER operations.
license: Apache-2.0
---

# Mutation tracking and analysis

Answers "why is this mutation stuck or slow" from `system.mutations`, `system.merges`, `system.parts`, `system.replication_queue` and `system.part_log`. Mutations rewrite whole parts in the background; they are not transactional row updates.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 11 checks: current mutation status, per-table mutation summary, stuck mutation detection by age, recently completed mutations, mutation duration per table, failed mutations in the part log, mutations executing right now, parts still awaiting mutation, mutation versus merge competition for the background pool, mutation creation rate and a breakdown by mutation command type. 3 of them need `system.part_log`.
- `reference.md` — background (settings, sizing, anti-patterns); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Deep-dive statements

Once a stuck mutation is identified, these three statements say what is blocking it. Substitute `{database}` and `{table}` with the table from check mutations-03.

Merges competing for the same table, since a mutation cannot start on a part that is being merged.

```sql
SELECT hostName() AS host, database, table, is_mutation, elapsed, progress, num_parts, result_part_name
FROM clusterAllReplicas('{cluster}', system.merges)
WHERE database = '{database}' AND table = '{table}';
```

The replication queue for the same table, since on a replicated table a mutation is a queue entry that can retry forever.

```sql
SELECT hostName() AS host, type, create_time, is_currently_executing, num_tries, last_exception
FROM clusterAllReplicas('{cluster}', system.replication_queue)
WHERE database = '{database}' AND table = '{table}'
ORDER BY create_time
LIMIT 20;
```

Per-part mutation version. `data_version` is the mutation version a part has been brought to, so a spread of values means the mutation applied to some parts only.

```sql
SELECT hostName() AS host, name, active, level, data_version, modification_time
FROM clusterAllReplicas('{cluster}', system.parts)
WHERE database = '{database}' AND table = '{table}' AND active
ORDER BY data_version DESC, modification_time DESC
LIMIT 30;
```

## Interpretation rules

- A finding is: more than 10 pending mutations on a table, a mutation older than one hour, or a non-empty `latest_fail_reason`. Any one of the three is enough; quote `mutation_id`, age and the fail reason as evidence.
- A non-empty `latest_fail_reason` with a rising `num_tries` means the mutation is retrying, not progressing. Read the exception text first: memory limits, missing columns and type errors need different fixes, and the mutation will never succeed on its own.
- Frequent small ALTER UPDATE statements are the common cause of a growing queue. Each one creates a mutation that rewrites every matching part. Recommend batching many row updates into one mutation, or moving to a ReplacingMergeTree or CollapsingMergeTree model where updates become inserts.
- ALTER DELETE without a WHERE clause, or one matching most rows, rewrites the whole table. Recommend a TTL or DROP PARTITION instead; both are metadata-level and near instant by comparison.
- Many concurrent mutations on the same table serialize anyway and starve merges (check mutations-09). Recommend running them one at a time rather than issuing them in parallel.
- To cancel a stuck mutation the user may run `KILL MUTATION` with a WHERE clause naming the database, table and `mutation_id` from check mutations-01. Do not run it yourself. A killed mutation leaves the table partially mutated: some parts carry the new data and some do not, and there is no automatic rollback.
- Checks marked `@requires table:system.part_log` are skipped when part_log is disabled. Without it, mutation duration and past failures are unknown; say so rather than reporting that mutations completed cleanly.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Mutation blocked by active merges, or the background pool saturated → load skill `altinity-expert-clickhouse-merges`
- Mutation failing with MEMORY_LIMIT_EXCEEDED or high peak memory → load skill `altinity-expert-clickhouse-memory`
- Mutation slow on large parts with disk or IO saturation → load skill `altinity-expert-clickhouse-storage`
- Mutation stuck in the replication queue, or applied on one replica only → load skill `altinity-expert-clickhouse-replication`
- Frequent updates suggesting the table should be Replacing or Collapsing → load skill `altinity-expert-clickhouse-schema`
- Mutation exceptions needing the full server log text → load skill `altinity-expert-clickhouse-logs`
