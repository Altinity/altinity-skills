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
    user,
    secure
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;
```

Redact internal hostnames if needed.

The `secure` column of `system.clusters` is present on 24.x/25.x (it has existed for many releases) and is the SQL-visible signal for interserver transport: `secure = 0` on a shard/replica means that distributed connection is plaintext. Read it — do not report it as "absent in this build" or defer interserver-transport findings to config when the column is right there. (`secure` reflects the cluster definition; whether the port itself is TLS-enforced is confirmed separately, see `16-keeper-and-interserver-security.md`.)

Risk signals:

- plaintext cluster connections where secure transport is expected (`secure = 0`).
- shared high-privilege user for distributed access.
- cluster credentials visible to too many users through `system.clusters`.
- inconsistent `secure` flags.

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
