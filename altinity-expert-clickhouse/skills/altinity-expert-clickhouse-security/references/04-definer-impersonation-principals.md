# Definer, impersonation, and security principal checks

Use this section for `SQL SECURITY DEFINER`, `EXECUTE AS`, `IMPERSONATE`, and no-password principal analysis.

## Key model

`no_password` (and `no_authentication`) means **passwordless authentication is permitted** — it is not "no access" and not a disabled account. It is also not automatically a finding. In practice such an account is almost always one of three things, and severity comes from *which*, never from `auth_type = no_password` or `host_ip = ::/0` alone:

- **Security principal** — the identity a `SQL SECURITY DEFINER` view / materialized view runs as, or an `IMPERSONATE` target. It is never the connecting user; its grants exist to back those views/targets.
- **Externally-authenticated identity** — in OAuth/JWT/SSO or proxy-fronted deployments (e.g. Altinity Cloud), `no_password` in `system.users` is a placeholder for auth delegated to the proxy/SSO. Signals: identities like `user@domain`, OAuth/SSO-derived role names. The `::/0` host ACL is gated by the perimeter, not by ClickHouse.
- **A genuine passwordless login hole** — an account anyone can authenticate as with no credential from any allowed host. This is the only case that is a finding on its own.

Do not headline "no-password users" as the finding, and do not treat broad host + grants as sufficient — that describes a normal definer/OAuth principal too.

## Check: no-password principals

```sql
SELECT
    name,
    auth_type,
    host_ip,
    host_names,
    host_names_regexp,
    host_names_like,
    default_roles_all,
    default_roles_list,
    default_roles_except
FROM system.users
WHERE has(auth_type, 'no_password')
   OR has(auth_type, 'no_authentication')
ORDER BY name;
```

Determine which case it is before rating:

- **Is it a definer/impersonation principal?** Cross-check it against the DEFINER views and `IMPERSONATE` targets below. If views run as it, or it is an impersonation target, it is a principal — its grants are its purpose.
- **Does it ever log in directly?** If `system.session_log` exists, check for actual logins:

```sql
SELECT user, client_address, count() AS logins, max(event_time) AS last_login
FROM system.session_log
WHERE type = 'LoginSuccess'
  AND user IN ('<no_password_user_1>', '<no_password_user_2>')
GROUP BY user, client_address
ORDER BY logins DESC;
```

Zero `LoginSuccess` events → it is not used as a login identity; treat it as a principal regardless of the host ACL. (If `session_log` is absent/empty, say so and fall back to the definer/delegated-auth determination.)

- **Is auth delegated?** `user@domain` / SSO role names + a proxy-fronted deployment mean the `::/0` is gated by the perimeter (see `05`), not a passwordless hole.

Rate:

- **Info / OK** — a definer or impersonation principal, an externally-authenticated/OAuth identity, or any no-password account with no observed direct logins. Broad host and write/`SOURCES` grants matched to its definer/impersonation purpose are expected here, not a finding.
- **Finding (gate severity on reachability, `05`)** — only when the account is a *direct login identity* (observed or plausible `LoginSuccess`), reachable, and carries grants beyond what a principal role needs. The risk to state is "anyone can connect as this account with no credential" — not the word `no_password`.

## Check: views using definer security

```sql
SELECT
    database,
    name,
    engine,
    create_table_query
FROM system.tables
WHERE positionCaseInsensitive(create_table_query, 'SQL SECURITY DEFINER') > 0
   OR positionCaseInsensitive(create_table_query, 'DEFINER') > 0
ORDER BY database, name;
```

Risk signals:

- definer has more grants than needed by the view query.
- definer is an admin or default user.
- view exposes sensitive columns or unfiltered rows.
- caller-facing role has broad `SELECT` on many definer views.
- materialized view definer has unexpected `INSERT` privileges.

## Check: SQL SECURITY NONE

`SQL SECURITY NONE` is deprecated and dangerous. Creating such views requires `ALLOW SQL SECURITY NONE`; flag principals with this privilege.

Search in `SHOW ACCESS` for:

```text
ALLOW SQL SECURITY NONE
```

## Check: impersonation

Inspect `SHOW ACCESS` for:

```text
IMPERSONATE
```

Risk signals:

- `IMPERSONATE ON *`.
- impersonation granted to app users or BI users.
- impersonation target has admin-equivalent grants.
- `access_control_improvements.allow_impersonate_user` enabled without clear controls.
