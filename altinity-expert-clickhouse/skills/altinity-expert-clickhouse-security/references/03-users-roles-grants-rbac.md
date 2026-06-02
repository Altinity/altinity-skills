# Users, roles, grants, and RBAC checks

Use this section when reviewing `SHOW ACCESS`, `system.grants`, users, and roles.

## Check: collect grants

Preferred:

```sql
SHOW ACCESS;
```

If system grants are available, also inspect relevant rows:

```sql
SELECT *
FROM system.grants
ORDER BY user_name, role_name, database, table, access_type;
```

Column names may vary by version; inspect with `DESCRIBE TABLE system.grants` if needed.

## Check: admin-equivalent permissions

Flag users or roles with combinations of:

- `GRANT ALL ON *.*`
- `WITH GRANT OPTION`
- `ACCESS MANAGEMENT`
- `CREATE USER`, `ALTER USER`, `DROP USER`
- broad `CREATE`, `ALTER`, `DROP`, `TRUNCATE`
- broad `SYSTEM`
- broad `SOURCES`: `FILE`, `URL`, `S3`, `REMOTE`, `MYSQL`, `POSTGRES`, `JDBC`, `ODBC`, `AZURE`
- `INTROSPECTION`
- `ALLOW SQL SECURITY NONE`
- `IMPERSONATE ON *`

## Counting and attribution rules

Apply these before reporting grant findings, or counts will be inflated and admins will be flagged for being admins:

- **Do not double-count `ALL`-implied privileges.** `GRANT ALL ON *.*` already implies `SYSTEM`, `INTROSPECTION`, `SOURCES`/`S3`/`URL`/`FILE`/`REMOTE`, `displaySecretsInShowAndSelect`, `NAMED COLLECTION ADMIN`, and the DDL/access-management privileges. When you report "N principals have SYSTEM/SOURCES/INTROSPECTION", count only those who hold it **without** `ALL`; otherwise you are re-listing the same admins under every derived privilege.
- **Deduplicate identities.** One human often has several principals — e.g. a local user `name` and an SSO/OAuth identity `name@example.com`, or a personal user plus a role. Note the likely link and report once, rather than as separate findings.
- **Distinguish expected admins and service accounts.** `ALL` on `clickhouse_operator` (the ClickHouse/Altinity Kubernetes operator), a break-glass admin, or a named service role is usually intentional. The finding is the *unexpected* `ALL`-holder, or an admin set that is larger than the operating model justifies — not the existence of admins. Ask for ownership context when intent is unclear.
- **Gate severity on reachability.** Pair every powerful grant with the principal's `host_ip`/`host_names` and auth method (see `05-network-exposure-and-tls.md` and `02-identity-authentication.md`). The same `ALL` + grant option is Critical on `::/0` with plaintext auth and far lower when locked to localhost/operator with strong auth.
- **Merge same-principal findings.** If one account combines weak auth, `ALL`, and broad grant option, report it as one correlated finding with combined blast radius, not three.
- **Authority comes from grants, not settings.** Read/write capability is decided by RBAC (`SELECT` vs `INSERT`/`ALTER`/`CREATE`/`DROP`), not by `readonly`/`allow_ddl`. Do **not** credit a `readonly` profile as a mitigation that lowers a grant finding — it is a mutable, per-session settings overlay, and "grant broad, then clamp with `readonly`" is a design smell, not a control. The finding is the over-broad grant; right-size it. Treat `readonly=2` only as effective-behavior context (a grant may be currently inert) and as a risk *amplifier* (`SET` + `CREATE TEMPORARY TABLE` + `SOURCES` → table functions; see `09`).

## Check: privilege inheritance

Look for:

- users with all roles enabled by default.
- powerful roles granted to low-privilege users.
- role chains that make a user admin-equivalent.
- grants assigned to roles that look like application or BI roles.

## Check: grant option blast radius

`WITH GRANT OPTION` is high risk when combined with broad privileges. The user can delegate permissions beyond the original operational intent.

Severity escalation:

- broad privileges + grant option: critical/high.
- object-level select + grant option: medium, depends on data sensitivity.
- admin role with grantees_any: high.

## Stating impact

Never write "too many grants". State the reachable outcome: create users, delegate privileges, read sensitive system metadata, create external data paths, drop/mutate production objects, or bypass row-policy designs.
