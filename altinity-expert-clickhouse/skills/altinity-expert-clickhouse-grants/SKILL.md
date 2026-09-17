---
name: altinity-expert-clickhouse-grants
description: Diagnose and resolve ClickHouse grant and authentication errors, especially after upgrades. Use when queries fail with ACCESS_DENIED/NOT_ENOUGH_PRIVILEGES, AUTHENTICATION_FAILED/WRONG_PASSWORD/REQUIRED_PASSWORD, or ON CLUSTER privilege errors; when system.* or INFORMATION_SCHEMA access is denied; or when grant behavior changes after version upgrades.
license: Apache-2.0
---

# Grant and authentication errors

Finds which privilege a blocked operation is missing and computes the smallest grant that unblocks it, from `system.errors`, `system.query_log`, `system.grants` and `system.role_grants`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 4 checks: access and authentication errors in `system.errors` over 24 hours (grants-01), missing privileges from queries that failed with exception code 497 (grants-02), current grants for the affected users (grants-03), roles assigned to the affected users (grants-04).
- `reference.md` — background (privilege families, access_control_improvements defaults); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- `missing_privileges` from grants-02 is the server's own answer. Build the `GRANT` statements from those values; do not infer the privilege from the query text.
- Scope every grant to the narrowest object that clears the error: a column list or `db.table` over `db.*`, and `db.*` over `*.*`. A grant that is broader than needed clears the error today and becomes an audit finding later.
- Prefer role-based grants when grants-04 shows the user already gets privileges through roles. Granting to the existing role keeps the model consistent; granting directly to the user splits it.
- Authentication errors from grants-01 (`AUTHENTICATION_FAILED`, `WRONG_PASSWORD`, `REQUIRED_PASSWORD`) are not privilege problems. Do not propose a `GRANT` for them; the fix is the user's auth method or host ACL.
- These privileges are exfiltration, SSRF or privilege-escalation surfaces. Grant the specific one needed, to a role, never the umbrella and never on `*.*`: `SOURCES` and its members `S3`, `URL`, `FILE`, `REMOTE` (plus `READ` and `WRITE` on 25.7+); `SYSTEM` and `INTROSPECTION`, scoped to the single subcommand.
- Never grant `ACCESS MANAGEMENT`, `WITH GRANT OPTION`, `displaySecretsInShowAndSelect`, `NAMED COLLECTION ADMIN`, `ALLOW SQL SECURITY NONE` or `IMPERSONATE` to fix a routine ACCESS_DENIED. Each one is a privilege-escalation or secret-exposure path and needs explicit justification.
- After an upgrade, check the `access_control_improvements` flags `select_from_system_db_requires_grant`, `select_from_information_schema_requires_grant` and `on_cluster_queries_require_cluster_grant`. When these are enabled, users that worked before now need explicit grants on `system.*`, `INFORMATION_SCHEMA.*` or `CLUSTER`, and the error is a behavior change rather than a lost grant.

## Deep-dive statements

Minimal grants follow this shape. Emit one statement per missing privilege, using the narrowest object and a role when one exists.

```sql
GRANT SELECT ON system.processes TO role_analytics;
```

```sql
GRANT role_analytics TO user_x;
```

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- The question is who has too much access, rather than what is blocked → load skill `altinity-expert-clickhouse-security`
- Version-specific privilege changes need confirmation against the audit-side checks → load skill `altinity-expert-clickhouse-security`
- `system.query_log` is missing or truncated so failed queries cannot be found → load skill `altinity-expert-clickhouse-logs`
- ON CLUSTER statements fail or hang after the grant is in place → load skill `altinity-expert-clickhouse-replication`
