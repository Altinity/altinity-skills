---
name: altinity-expert-clickhouse-connection
description: Establishes how to reach ClickHouse (MCP tool or clickhouse-client), the cluster name for clusterAllReplicas('{cluster}', ...) query packs, the default 24-hour time window, and the shared report header. Use first, before any other altinity-expert-clickhouse skill.
license: Apache-2.0
---

# Connection, cluster and time window

Run this before any other `altinity-expert-clickhouse-*` skill. It produces the facts every later skill reuses: connection mode, cluster name (or single node), ClickHouse version, Keeper presence, time window.

## Step 1: choose the connection mode

Check your available tools in this order and stop at the first match:

1. **MCP mode**: a tool whose name contains `clickhouse` and one of `query`, `execute`, `sql` (for example `clickhouse_execute_query`, `mcp__clickhouse__execute_query`). Send exactly one SQL statement per call. If several ClickHouse MCP servers exist, ask the user which one to use.
2. **Exec mode**: a shell tool plus `clickhouse-client` (or `clickhouse client`). Use only the connection flags the user provided (`--host`, `--port`, `--user`, `--password`, `--secure`); do not guess credentials from environment variables. Run one statement per invocation with `--query "<statement>"`. Never use `--queries-file` or `--multiquery`.
3. **Neither**: stop and ask the user how to reach ClickHouse. Do not install software and do not write helper scripts.

## Step 2: verify connectivity and collect header facts

Run this one statement. It works on a standalone server (no macro, no Keeper) and on a cluster:

```sql
SELECT
    hostName() AS hostname,
    version() AS version,
    (SELECT substitution FROM system.macros WHERE macro = 'cluster') AS cluster_macro,
    (SELECT groupUniqArray(cluster) FROM system.clusters WHERE NOT is_local) AS candidate_clusters,
    (SELECT count() FROM system.tables WHERE database = 'system' AND name = 'zookeeper_connection') AS has_keeper,
    formatReadableTimeDelta(uptime()) AS uptime,
    formatReadableSize((SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal')) AS os_memory_total
```

If it fails with an authentication or network error, stop and ask for the connection details. Do not retry with guessed credentials.

## Step 3: decide the cluster mode

- `cluster_macro` is not empty → **cluster mode**. Leave `'{cluster}'` in every query pack exactly as written; the server expands the macro.
- `cluster_macro` is empty and `candidate_clusters` is not empty → ask the user which cluster to use, then replace `'{cluster}'` with that name in each statement before running it.
- Both empty → **single-node mode**. Replace `clusterAllReplicas('{cluster}', system.<table>)` with `system.<table>` in each statement before running it.

`has_keeper = 0` means no Keeper/ZooKeeper: skip every statement marked `-- @requires keeper` and report replication and ON CLUSTER checks as not applicable.

## Step 4: fix the time window

- If the user gave a time range, use it exactly.
- Otherwise use the last 24 hours (`event_time >= now() - INTERVAL 24 HOUR`). Packs already use relative windows; do not widen them without asking.

## How to run the query packs (applies to every skill)

1. Read each pack file from the skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and `has_keeper = 0`, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as decided in Step 3. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue with the next statement. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Report header

Start every report with this table, filled from Step 2:

| Connection mode | Cluster | ClickHouse version | Keeper | Time window |
|---|---|---|---|---|
| MCP or clickhouse-client | macro value, chosen cluster, or "single node" | version | yes/no | window used |

## Next skills

- Unknown problem area or general health check → load skill `altinity-expert-clickhouse-overview`
- Known symptom → load the matching specialist skill (memory, merges, replication, ingestion, reporting, storage, ...)
