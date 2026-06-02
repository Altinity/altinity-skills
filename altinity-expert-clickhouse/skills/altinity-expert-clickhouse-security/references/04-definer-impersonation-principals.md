# Definer, impersonation, and security principal checks

Use this section for `SQL SECURITY DEFINER`, `EXECUTE AS`, `IMPERSONATE`, and no-password principal analysis.

## Key model

`no_password` and `no_authentication` are not automatically findings. They are often deliberate non-login principals used as security contexts for views, materialized views, JWT shadow definers, or impersonation workflows.

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

Classify:

- expected: no-password user has narrow/no login path, narrow grants, and is referenced as definer or controlled impersonation target.
- suspicious: no-password user has broad hosts, admin grants, grant option, source grants, or no visible purpose.

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
