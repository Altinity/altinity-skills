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

With explicit owner authorization, a single connection attempt resolves the `::/0` reachability question SQL cannot answer: any ClickHouse auth response (even a rejection) proves the port is reachable from that position, whereas a dropped/closed TLS connection (`SSL connection unexpectedly closed`) or timeout means the port is not exposed there (perimeter-gated). Field example: identical `::/0` `no_password` accounts were a live public hole on one cluster (native port answered) and inert on another (native port refused the TLS connection, fronted by an OAuth/nginx perimeter). Interpreting the auth response itself is covered in `04`.

## Check: ports, listeners, and TLS — config-only

Listener and port configuration is **not** exposed in `system.server_settings`. On current versions (verified on 25.8) that table does **not** contain `listen_host`, `tcp_port`, `tcp_port_secure`, `http_port`, `https_port`, `mysql_port`, `postgresql_port`, `grpc_port`, or `interserver_http(s)_port`. So:

- Do not rate TLS/port exposure from SQL, and do not treat "ports not visible in `system.server_settings`" as an oversight — it is the expected state. A report that says ports/TLS/`listen_host` are not SQL-verifiable is correct.
- Confirm `tcp_port_secure`, `https_port`, plaintext-port exposure, `listen_host`, and `openSSL` from `config.xml` / `config.d` (request them).
- The one security-relevant server setting that *is* in `system.server_settings` is `display_secrets_in_show_and_select` (see `09` and `12`):

```sql
SELECT name, value, changed
FROM system.server_settings
WHERE name = 'display_secrets_in_show_and_select';
```

The gRPC port and any Prometheus metrics endpoint are additional exposed surfaces (also config-only). The HTTP interface (handlers, Play UI, CORS) is covered in `19-http-interface-surface.md`; interserver authentication in `16-keeper-and-interserver-security.md`.

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
