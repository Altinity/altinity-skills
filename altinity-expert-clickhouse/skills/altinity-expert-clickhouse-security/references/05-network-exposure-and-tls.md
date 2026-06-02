# Network exposure and TLS checks

Use this section to combine user host restrictions with server exposure and TLS configuration.

## Check: user host restrictions

```sql
SELECT
    name,
    auth_type,
    host_ip,
    host_names,
    host_names_regexp,
    host_names_like
FROM system.users
ORDER BY name;
```

Risk signals:

- `::/0`
- `0.0.0.0/0`
- broad private ranges for admin users without justification.
- permissive hostname regex.
- empty or unexpected host restrictions.

Do not flag broad private ranges automatically for cluster/service users; correlate with grants and network architecture.

### Reachability is a required input to every auth/privilege finding

`host_ip`/`host_names` is SQL-visible, so there is no excuse for rating an authentication or grant finding without it. Before assigning severity to a weak-auth or powerful-grant finding (sections `02`, `03`, `13`), join it to the principal's host restriction:

- weak/powerful account on `::/0` or `0.0.0.0/0`: treat as reachable from untrusted networks → escalate.
- same account restricted to `127.0.0.1`, an operator subnet, or a narrow allowlist: lower severity; state that perimeter beyond the host clause is not SQL-verifiable.

If a finding cannot state the principal's host restriction, that is a gap to report, not an omission to ignore.

## Check: server settings visible from SQL

```sql
SELECT
    name,
    value,
    changed
FROM system.server_settings
WHERE name IN
(
    'listen_host',
    'tcp_port',
    'tcp_port_secure',
    'http_port',
    'https_port',
    'mysql_port',
    'postgresql_port',
    'grpc_port',
    'prometheus.port',
    'interserver_http_port',
    'interserver_https_port'
)
ORDER BY name;
```

On modern builds (24.x and 25.x) these port settings — including `tcp_port_secure` and `https_port` — **are** present in `system.server_settings`; run the query and read the values. Only defer TLS/port findings to `config.xml` if the query genuinely returns nothing for them. "Not present in `system.server_settings` on this build" is almost always a sign the query was not run, not that the build lacks the rows — do not claim TLS/ports are unverifiable on a current version without first querying. (On older 23.x builds some rows, e.g. `listen_host`, may be absent — then request `config.xml` / `config.d`.)

Also consider the gRPC port (`grpc_port`) and any Prometheus metrics endpoint as additional exposed surfaces: an open `grpc_port` is another authenticated entry point, and an unauthenticated Prometheus endpoint can leak metric and label data. The HTTP interface (handlers, Play UI, CORS) is covered in `19-http-interface-surface.md`; interserver authentication is covered in `16-keeper-and-interserver-security.md`.

## TLS posture

Flag as not verifiable from SQL-only unless secure ports and OpenSSL config are visible. If config is supplied, check:

- `tcp_port_secure`
- `https_port`
- `openSSL`
- whether plaintext ports remain exposed externally.
- whether interserver traffic uses secure settings.

## Risk escalation

High-risk combination:

```text
broad host access + plaintext/no weak auth + admin grants + plaintext port exposed
```

Medium-risk combination:

```text
broad host access + read-only grants + query/resource limits present
```
