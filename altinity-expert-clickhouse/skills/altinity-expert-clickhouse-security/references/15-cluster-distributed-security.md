# Cluster and distributed security checks

Use this section for multi-node ClickHouse systems. For the coordination and inter-node layers (ZooKeeper/Keeper exposure and ACLs, `interserver_http_credentials`), see `16-keeper-and-interserver-security.md`.

## Scope warning

Do not assume cluster names. Ask for the cluster name or inspect local node only. If only one node is available, state that cluster-wide consistency is not verified.

## Check: local cluster definitions

```sql
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    host_address,
    port,
    is_local,
    user
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;
```

Redact internal hostnames if needed.

`system.clusters` does **not** expose a `secure` column on current versions (24.x/25.x) — do not query it and do not infer interserver TLS from this table. Interserver transport security is the `<secure>` flag in the `remote_servers` config plus `interserver_https_port`; confirm it from `config.xml` (see `16-keeper-and-interserver-security.md`). If a report says "the `secure` column is absent in this build," that is correct, not an oversight.

Risk signals:

- shared high-privilege user for distributed access (the `user` column).
- cluster credentials visible to too many users through `system.clusters`.
- plaintext interserver transport — confirmed from config (`16`), not from this table.

## Check: distributed DDL exposure

Search grants for:

```text
CLUSTER
ON CLUSTER
```

Risk signals:

- users can run `ON CLUSTER` DDL broadly.
- cluster grant missing while distributed DDL is expected; may indicate inconsistent behavior by version/config.
- app users with cluster-wide DDL.

## Check: cluster table functions

Correlate source grants with:

- `s3Cluster`
- `urlCluster`
- `remote`
- `remoteSecure`
- `cluster`
- `clusterAllReplicas`

Risk signals:

- non-admin users can query all replicas' system logs.
- cluster functions expose data beyond intended database grants.
- broad `REMOTE` grants.

## Check: consistency across replicas

When a cluster name is provided, compare users/grants/profiles across replicas. Prefer summarized hashes/counts and do not print secrets.

Example pattern:

```sql
SELECT
    hostName() AS host,
    count() AS users
FROM clusterAllReplicas('<cluster>', system.users)
GROUP BY host
ORDER BY host;
```

Do not run this until the cluster name is known and the user approves cluster-wide read queries.

Mark each finding as local-node vs. cluster-wide; single-node observations are "not proven consistent across replicas".
