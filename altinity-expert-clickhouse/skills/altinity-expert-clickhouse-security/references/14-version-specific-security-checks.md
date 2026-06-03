# Version-specific security checks

Use this section after collecting `SELECT version()`.

## Check: collect version

```sql
SELECT version();
```

Use exact version in findings. If mixed-version cluster is possible, collect per replica when a cluster name is provided.

The `access_control_improvements` flags below (`select_from_system_db_requires_grant`, `select_from_information_schema_requires_grant`, `on_cluster_queries_require_cluster_grant`, `table_engines_require_grant`, `enable_read_write_grants`, …) are the same ones the `altinity-expert-clickhouse-grants` skill checks from the remediation side after upgrades — keep the two lists in sync.

## 24.2 and newer: view security

ClickHouse 24.2 added `DEFINER` and `SQL SECURITY` support for views/materialized views. For older versions, view security behavior and materialized view permission semantics may differ.

Check:

- use of `SQL SECURITY DEFINER`
- use of deprecated `SQL SECURITY NONE`
- default view security settings:
  - `default_normal_view_sql_security`
  - `default_materialized_view_sql_security`
  - `default_view_definer`

## 24.4 and newer: table engine grants

Table engines became grantable, but enforcement may depend on `table_engines_require_grant` for backward compatibility.

Check:

- version >= 24.4
- `table_engines_require_grant`
- `TABLE ENGINE` grants
- broad `CREATE TABLE` with dangerous engines.

## 25.7 and newer: source read/write grants

Source grants can distinguish `READ` and `WRITE` when `access_control_improvements.enable_read_write_grants` is enabled.

For older versions or disabled read/write split, old-style source grants may effectively allow both read and write. Treat broad source grants conservatively.

## 25.8 and newer: table-function permission fixes

Check for fixes around Azure, cluster variants, and local Iceberg/DeltaLake permission validation. On older versions, treat broad source grants and cluster-variant functions as higher risk if observed.

For exact current behavior or bug status, verify against official docs/changelog/GitHub before making strong claims. Use version-aware language (e.g. "on this version, old-style source grants are treated conservatively because read/write separation is unavailable or unconfirmed").
