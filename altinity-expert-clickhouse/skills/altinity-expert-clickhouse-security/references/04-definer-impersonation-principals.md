# Definer, impersonation, and security principal checks

Use this section for `SQL SECURITY DEFINER`, `EXECUTE AS`, `IMPERSONATE`, and no-password principal analysis.

## Key model

`no_password` (and `no_authentication`) means ClickHouse accepts that user over the **native and HTTP protocols with no credential at all** — it is a real login path, not "no access" and not a disabled account. An OAuth/JWT/SSO proxy in front of ClickHouse does **not** gate this: if the native (9440/9000) or HTTP port is reachable from a source the host ACL admits, the passwordless login succeeds directly and bypasses the proxy. Names and roles are not authentication — do **not** assume a `user@domain` identity or `oauth_*` role membership makes it safe.

> Field-verified on an Altinity demo server: a `no_password` user named like an OAuth identity, `host_ip = ::/0`, logged in from the public internet with an empty password and held a writer role. The OAuth front-end did not protect the native port.

So a no_password account is a **live anonymous-login hole** whenever its host ACL admits a reachable source — *unless* you can affirmatively show it is a non-login principal. Treat it as a principal only with evidence:

- it is referenced **only** as a `SQL SECURITY DEFINER` / `IMPERSONATE` target, and/or
- `system.session_log` shows **zero** `LoginSuccess` for it, and/or
- its host ACL excludes reachable sources (localhost / operator subnet only — `::/0` does not).

Verify, do not infer — the burden of proof is on "safe", not on "vulnerable".

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

- **Confirm reachability — do not assume a proxy gates it.** An OAuth/SSO front-end does not close the native/HTTP port. `::/0` is safe only if the network perimeter actually blocks the port, which is not SQL-verifiable (see `05`); assume reachable until proven otherwise. With authorization, an actual passwordless connection attempt is the definitive test.

Rate:

- **High by default — Critical if admin-equivalent (gate on reachability, `05`)** — a no_password account whose host ACL admits reachable sources (`::/0` or broad) and that holds meaningful grants. Anyone who reaches the port connects as it with no credential. Default `::/0` to reachable unless the perimeter is proven closed; the OAuth/proxy layer does not close it.
- **Info / OK** — only when verified as a non-login principal: a definer/impersonation target with zero `LoginSuccess`, or a host ACL restricted to non-reachable sources. Grants matched to that definer/impersonation purpose are expected.

## Confirm exploitability (authorized only)

The definitive test of a `no_password` hole is a single passwordless connection as that exact account, from the relevant network position — **only with explicit owner authorization** (`01`). It is verification, not guessing: one named account, no password/user iteration. Read the response:

- **Auth rejected** — `AUTHENTICATION_FAILED` / `Code 516 (... password is incorrect, or there is no user with such name)` → not exploitable as no_password (has a credential, or is gated/absent).
- **Auth passed** — login succeeds, **or** a *post-authentication* error such as `Code 81: Database ... does not exist` (a missing `default_database`) → the credentials were accepted: this is a **live passwordless login**. Do not mistake a post-auth error for a failed login.
- **No ClickHouse response** — connection dropped, `SSL connection unexpectedly closed`, or timeout → the port is not reachable from that position (perimeter-gated); the `::/0` ACL is not exploitable from there (`05`).

## Remediation for a no_password login hole

- **Definer/impersonation principal:** set a strong password (or restrict `host_ip` off `::/0`). The `SQL SECURITY DEFINER` mechanism uses the principal's grants, not a live login — the views keep working — so prefer this over dropping when objects depend on it.
- **Before dropping or altering**, confirm the account is not your own session identity or a management/automation login (operator, MCP, BI service). Removing it can lock you or those tools out — verified the hard way.
- **Operator-managed (Kubernetes/CHI) deployments:** apply the fix in the CHI users config, not just SQL — the operator may revert SQL-only user changes on its next reconciliation.

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
