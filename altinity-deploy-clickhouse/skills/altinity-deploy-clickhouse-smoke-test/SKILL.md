---
name: altinity-deploy-clickhouse-smoke-test
description: Runs post-deploy smoke tests against a freshly deployed ClickHouse to validate the install. Checks connectivity, version, basic INSERT/SELECT roundtrip, system health, and replication when clustered. Use after any deploy skill completes, or to verify an existing install before declaring it ready.
author: Altinity Inc
version: 0.0.1
license: Apache-2.0
---

# Smoke Test — Post-Deploy Validation

Confirm that a freshly deployed ClickHouse is actually serving traffic, accepting writes, and (for clustered installs) replicating. Don't declare a deployment successful without a clean run of this skill.

---

## Action Mode

Hybrid:

- All `SELECT` queries from `checks.sql` run automatically.
- The write roundtrip `CREATE TABLE` / `INSERT` / `SELECT` / `DROP TABLE` requires explicit user confirmation. The test database is named `_altinity_smoke_test` and is dropped at the end. Print the exact SQL before asking.

If the user declines the write roundtrip, run the read-only checks only and clearly mark the report as "read-only smoke test."

---

## Step 1 — Verify Inputs

The deploy skill that called this one should pass:

- **Endpoint** — host, HTTP port (8123), native port (9000)
- **User / password**
- **Topology** — single-node or clustered (shards × replicas)
- **Cluster name** — only for clustered installs (the value of the `cluster` macro or a name from `system.clusters`)
- **Deployment intent** — production or development

If invoked standalone, ask the user for these.

---

## Step 2 — Connectivity

Run automatically:

```sql
SELECT
    hostName()      AS hostname,
    version()       AS version,
    getMacro('cluster') AS cluster_macro,
    getMacro('shard')   AS shard_macro,
    getMacro('replica') AS replica_macro,
    formatReadableTimeDelta(uptime()) AS uptime
```

If this fails, stop and report. The deploy did not produce a working server.

---

## Step 3 — Read-Only Health Checks

Run all queries from `checks.sql`. They cover:

1. Server uptime and version.
2. `system.clusters` — confirm expected shards/replicas if clustered.
3. `system.zookeeper` — confirm Keeper / ZooKeeper connectivity.
4. `system.replicas` — confirm no read-only replicas if replicated tables exist.
5. `system.errors` over the last hour — flag any non-trivial errors that occurred during boot.
6. `system.metrics` — sample of memory/connections/queue depth.
7. `system.disks` — confirm disks are mounted and writable.

Report each block with a severity tag: `OK`, `Minor`, `Moderate`, `Major`, `Critical`.

---

## Step 4 — Write Roundtrip

After confirmation, run the following in order. Stop at the first failure.

```sql
CREATE DATABASE IF NOT EXISTS _altinity_smoke_test;

CREATE TABLE _altinity_smoke_test.ping
(
    ts DateTime DEFAULT now(),
    n  UInt64
)
ENGINE = MergeTree
ORDER BY ts;

INSERT INTO _altinity_smoke_test.ping (n)
SELECT number FROM numbers(1000);

SELECT count() AS rows, max(n) AS max_n
FROM _altinity_smoke_test.ping;
-- expect: rows = 1000, max_n = 999

DROP TABLE _altinity_smoke_test.ping;
DROP DATABASE _altinity_smoke_test;
```

For clustered deployments, also test a `Replicated*` table when the cluster name is known:

```sql
CREATE DATABASE IF NOT EXISTS _altinity_smoke_test
ON CLUSTER '{cluster}';

CREATE TABLE _altinity_smoke_test.ping_repl
ON CLUSTER '{cluster}'
(
    ts DateTime DEFAULT now(),
    n  UInt64
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/_altinity_smoke_test/ping_repl', '{replica}')
ORDER BY ts;

INSERT INTO _altinity_smoke_test.ping_repl (n)
SELECT number FROM numbers(1000);

-- Wait briefly for replication, then check from each replica.
SELECT
    hostName(),
    count() AS rows
FROM clusterAllReplicas('{cluster}', _altinity_smoke_test.ping_repl)
GROUP BY hostName();

DROP TABLE _altinity_smoke_test.ping_repl ON CLUSTER '{cluster}' SYNC;
DROP DATABASE _altinity_smoke_test ON CLUSTER '{cluster}' SYNC;
```

If `getMacro('cluster')` returned empty in Step 2, skip the `Replicated*` block and note "single-node, replication test skipped."

---

## Step 5 — Production-Only Extra Checks

When deployment intent is **production**, also check:

- At least 2 replicas per shard reported in `system.clusters`.
- Default user is not passwordless — `SELECT name, auth_type FROM system.users WHERE name = 'default'`.
- Memory and CPU limits visible to the server look reasonable (`SELECT * FROM system.asynchronous_metrics WHERE metric IN ('OSMemoryTotal','CGroupMaxCPU')`).
- No `[Major]` or `[Critical]` rows in the report.

If any of these fail, mark the smoke test **Failed** even if the write roundtrip succeeded.

---

## Report

Produce a single summary the deploy skill can include in its own output:

- Connection coordinates and version
- Topology summary (single-node / N shards × M replicas)
- Read-only checks: per-block status
- Write roundtrip: passed / skipped / failed
- Replicated roundtrip: passed / skipped / failed
- Production extras (production intent only): passed / failed
- Overall: **PASS** / **PASS (read-only)** / **FAIL**

A `FAIL` result blocks declaring the deployment successful.
