---
name: altinity-expert-clickhouse-grants
description: Diagnose and resolve ClickHouse grant and authentication errors, especially after upgrades. Use when queries fail with ACCESS_DENIED/NOT_ENOUGH_PRIVILEGES, AUTHENTICATION_FAILED/WRONG_PASSWORD/REQUIRED_PASSWORD, or ON CLUSTER privilege errors; when system.* or INFORMATION_SCHEMA access is denied; or when grant behavior changes after version upgrades.
license: Apache-2.0
---

## Diagnostics

Run all queries from `checks.sql` in this skill's directory and analyze the results.

## Propose Minimal Grants
Provide the smallest set of `GRANT` statements that match observed `needed_grant` values. Prefer role-based grants when the user already uses roles.

Example pattern:
```sql
-- Direct grants
GRANT SELECT ON system.processes TO user_x;
GRANT SELECT ON INFORMATION_SCHEMA.COLUMNS TO svc_y;
GRANT CLUSTER ON *.* TO svc_z;

-- Role-based grants (preferred)
GRANT SELECT ON system.processes TO role_analytics;
GRANT role_analytics TO user_x;
```

Scope to the narrowest object that resolves the error: `db.table` (or a column list) over `db.*`, and `db.*` over `*.*`.

## Security-sensitive grants — scope tightly
Some privileges are exfiltration / SSRF / privilege-escalation surfaces. If the failing query needs one, grant the **narrowest** form and to a role, never broadly on `*.*`:

- `SOURCES` / `S3` / `URL` / `FILE` / `REMOTE` (and `READ`/`WRITE` on 25.7+) — external read/write; broad grants enable data exfiltration and SSRF. Grant the specific source needed, not the `SOURCES` umbrella.
- `SYSTEM`, `INTROSPECTION` — operational/internal exposure; scope to the specific subcommand.
- `ACCESS MANAGEMENT`, `WITH GRANT OPTION`, `displaySecretsInShowAndSelect`, `NAMED COLLECTION ADMIN`, `ALLOW SQL SECURITY NONE`, `IMPERSONATE` — privilege-escalation/secret-exposure; do not grant these to fix a routine `ACCESS_DENIED` without explicit justification.

A grant that resolves an error but is broader than needed becomes a future audit finding — see the `altinity-expert-clickhouse-security` skill.

## Post-Upgrade Compatibility Checks
Verify `access_control_improvements` settings, which can change privilege requirements:

- `select_from_system_db_requires_grant`
- `select_from_information_schema_requires_grant`
- `on_cluster_queries_require_cluster_grant`

If these are enabled post-upgrade, users may require new explicit grants for `system.*`, `INFORMATION_SCHEMA.*`, or `CLUSTER`. The same `access_control_improvements` flags (plus the version-gated source/engine/definer changes) are covered from the audit side in `altinity-expert-clickhouse-security` → `references/14-version-specific-security-checks.md`; keep the two in sync.

## Related skills
This is the reactive **remediation** skill — it makes a legitimately-blocked operation work with the minimal grant. Its counterpart is `altinity-expert-clickhouse-security`, the proactive read-only **audit** skill: use that to review who has *too much* access, find exfiltration paths, weak auth, and exposure. Fixing an error here → grant minimally; reviewing posture → use security.
