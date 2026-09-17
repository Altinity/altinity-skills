# Grants reference

Background material for `altinity-expert-clickhouse-grants`. Read only when you
need to explain or justify a recommendation.

## Where the missing privilege comes from

ClickHouse raises exception code 497 (`ACCESS_DENIED`) with a
`missing_privileges` value in `system.query_log`. That column names the exact
privilege and object the server wanted, which is why it is preferred over
reading the query text. Older versions may leave it empty; then the exception
message itself carries the privilege name.

## Privilege families

| Family | Members | Why it is sensitive |
|---|---|---|
| `SOURCES` | `S3`, `URL`, `FILE`, `REMOTE`, `HDFS`, `MYSQL`, `POSTGRES`, `MONGO`, and on 25.7+ the `READ`/`WRITE` split | Reads from and writes to arbitrary external endpoints; enables exfiltration and SSRF |
| `INTROSPECTION` | `addressToLine`, `addressToSymbol`, `demangle` | Exposes server internals and memory layout |
| `SYSTEM` | `SYSTEM SHUTDOWN`, `SYSTEM DROP CACHE`, `SYSTEM RELOAD`, `SYSTEM MERGES`, and others | Operational control of the server |
| Access management | `ACCESS MANAGEMENT`, `WITH GRANT OPTION`, `NAMED COLLECTION ADMIN`, `IMPERSONATE`, `ALLOW SQL SECURITY NONE` | Lets the holder widen its own or another principal's access |
| Secret display | `displaySecretsInShowAndSelect` | Unmasks credentials in `SHOW CREATE` and in table function arguments |

## access_control_improvements

These server settings live in `config.xml` under `<access_control_improvements>`
and change which grants are required. Their defaults have shifted across
versions, so an upgrade can turn a working account into a denied one without any
grant being revoked.

| Setting | Effect when enabled |
|---|---|
| `select_from_system_db_requires_grant` | Reading `system.*` needs an explicit `SELECT` grant on those tables |
| `select_from_information_schema_requires_grant` | Reading `INFORMATION_SCHEMA.*` needs an explicit `SELECT` grant |
| `on_cluster_queries_require_cluster_grant` | `ON CLUSTER` statements need the `CLUSTER` privilege |
| `role_cache_expiration_time_seconds` | How long a resolved role set is cached; a fresh grant may appear delayed |

## Grant hygiene

- One statement per privilege and object keeps the change reviewable and
  reversible with a matching `REVOKE`.
- Grants to roles survive user recreation; grants to users do not.
- `is_partial_revoke = 1` in `system.grants` means a narrower revoke sits under a
  broader grant. Read the pair together before concluding what a user can do.
