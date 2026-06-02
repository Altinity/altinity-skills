# Keeper / ZooKeeper and interserver security

Use this section for the coordination and inter-node layers of a cluster. These are common gaps in SQL-only audits because the relevant configuration is rarely visible from `system.*`.

## Why this matters

ClickHouse Keeper (or external ZooKeeper) holds replication metadata, the distributed DDL queue, and parts of the access-control state. An exposed or unauthenticated Keeper lets an attacker read or rewrite replication state across the whole cluster. Interserver ports move data and DDL between replicas; if they are unauthenticated or plaintext, a host on the network can impersonate a replica or read replicated traffic.

## Check: Keeper/ZooKeeper visibility from SQL

```sql
SELECT
    name,
    value
FROM system.zookeeper
WHERE path = '/'
LIMIT 50;
```

If this succeeds for a low-privilege user, note that `system.zookeeper` read access exposes coordination metadata. Reading it requires `SELECT` on `system.zookeeper`; flag broad grants of it.

Keeper connection config is usually only in `config.xml`/`config.d`. Request it and check:

```text
zookeeper          (node host/port, secure flag, identity/digest auth)
keeper_server      (tcp_port, tcp_port_secure, server_id, raft_configuration)
```

## Risk signals

- Keeper/ZooKeeper reachable from outside the cluster network (no firewalling, bound to a public interface).
- No digest/`identity` authentication on the `<zookeeper>` connection or no ACLs on znodes.
- Plaintext Keeper traffic where `secure`/`tcp_port_secure` is expected.
- `system.zookeeper` readable by application or BI users.
- Mixed secure/insecure Keeper endpoints across nodes.

## Check: interserver authentication

Interserver credentials are config-only. Request `config.xml` and check:

```text
interserver_http_credentials   (user/password for replica-to-replica fetches)
interserver_http_port          (plaintext)
interserver_https_port         (TLS)
interserver_http_host
```

## Risk signals

- `interserver_http_port` exposed without `interserver_http_credentials` configured — any host that can reach the port can fetch parts.
- Plaintext interserver port reachable from untrusted networks while no `interserver_https_port` is used.
- Interserver credentials shared with, or identical to, an application/admin SQL user.
- Inconsistent interserver auth across replicas.

Unless `system.zookeeper` exposure is directly observed, state that Keeper/interserver posture is config-only and request `config.xml`/`config.d` to confirm Keeper authentication, znode ACLs, and `interserver_http_credentials`.
