---
name: altinity-expert-clickhouse-security
description: Read-only ClickHouse security audit of users, roles, grants, row policies, settings profiles, quotas, named collections, table functions and engines, executable UDFs, TLS and network exposure, Keeper and interserver security, audit logging, password hash hygiene, and SQL SECURITY DEFINER. Use when assessing security posture or finding over-privileged or exposed access.
license: Apache-2.0
---

# ClickHouse security audit

A professional, read-only security audit from `system.users`, `system.grants`, `system.roles`, `system.row_policies`, `system.settings_profile_elements`, `system.quotas`, `system.named_collections`, `system.functions`, `system.clusters` and supplied configuration files.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Core behavior

- Work as a senior ClickHouse security reviewer. Prefer read-only SQL and metadata inspection.
- Never run destructive SQL and never attempt online password guessing.
- Never print secrets, password hashes, salts, private keys, access keys, tokens, or recovered password candidates.
- Correlate findings. Do not flag a setting without considering grants, network exposure, user intent, version and observed query behavior.
- State explicitly what could not be verified from the access you had.
- Give remediation only when asked, and then minimally. For grant changes use the least-privilege, role-based method of the grants skill: the smallest scoped statements, roles over users, never a broad `*.*` grant.

## Query packs

- `checks.sql` — 20 checks: server identity, full `SHOW ACCESS` dump, user inventory with auth method and host ACL, roles and role graph, grant posture per principal, admin-equivalent and access-management holders, security-sensitive privileges, column-scoped grants, row policies, settings profiles and elements, quotas, named collection names, user-defined and executable functions, secure ports, cluster topology and the distributed user, external-engine tables and DEFINER views, logging and auth-audit baseline. Local node only; cluster-wide checks live in `references/15-cluster-distributed-security.md`.
- `references/` — 20 depth files, indexed below. Load only the ones a finding points at.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

Establish scope before judging anything: live SQL access versus exported `system.*` data versus supplied `users.xml` and `config.xml`; single node or cluster; ClickHouse version and deployment model. Then run `checks.sql` as the first pass and add supplied config snippets and recent `system.query_log` and `system.session_log` extracts as needed.

- Report each finding with title, severity, confidence, evidence summary, why it matters, what was not verifiable, and only then a suggested confirmation or remediation.
- `session_log_exists = 0` (security-20) means login and authentication auditing is off. Table absence is the signal; no further query is needed.
- `VALID UNTIL` is not a `system.users` column on current versions. Read expiration from `SHOW CREATE USER` or the `SHOW ACCESS` dump instead of reporting it as absent.
- Named collection values are masked by the server. List names only and never select values; a masked value is not evidence that the secret is safe.
- A grant that looks excessive may be justified by an application's real workload. Check `system.query_log` for whether the privilege is actually exercised before calling it over-privileged.
- Version matters for source, engine and definer behavior. Check `references/14-version-specific-security-checks.md` before asserting that a privilege is or is not required.
- Column-scoped SELECT grants are bypassable through views, row policies on other tables, and table functions. Treat them as a control only when the bypass paths are also closed.

## Reference index

- `references/01-scope-and-safety.md`: safe execution rules, evidence handling, redaction.
- `references/02-identity-authentication.md`: users, auth methods, default user, expiration, multiple auth methods.
- `references/03-users-roles-grants-rbac.md`: RBAC, grants, admin-equivalent permissions.
- `references/04-definer-impersonation-principals.md`: `SQL SECURITY DEFINER`, `EXECUTE AS`, no-password principals.
- `references/05-network-exposure-and-tls.md`: host restrictions, ports, TLS, exposure.
- `references/06-table-functions-external-sources.md`: table functions, `SOURCES` grants, exfiltration paths.
- `references/07-table-engines-and-external-integrations.md`: external table engines, persistent integrations.
- `references/08-row-column-policy-security.md`: row policies, column grants, bypass patterns.
- `references/09-settings-profiles-constraints-quotas.md`: settings profiles, constraints, quotas, readonly.
- `references/10-audit-logging-and-log-integrity.md`: query and session logs, `log_query_settings`, observability gaps.
- `references/11-query-log-threat-hunting.md`: suspicious behavior from logs.
- `references/12-secrets-named-collections-credentials.md`: named collections, secret handling, hardcoded credentials.
- `references/13-password-hash-hygiene.md`: hash inventory, duplicate hashes, weak hash matching, safe reporting.
- `references/14-version-specific-security-checks.md`: version-aware checks.
- `references/15-cluster-distributed-security.md`: cluster-wide consistency and distributed security.
- `references/16-keeper-and-interserver-security.md`: Keeper exposure and ACLs, interserver authentication.
- `references/17-executable-udf-and-code-execution.md`: executable UDFs and server-side command execution.
- `references/18-encryption-at-rest-and-backups.md`: encrypted disks, storage credentials, `BACKUP`/`RESTORE` destinations.
- `references/19-http-interface-surface.md`: HTTP handlers, Play UI, CORS, default-credential access over HTTP.
- `references/20-reporting-severity-and-output-format.md`: severity rubric and final report structure.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

Grade severity with the rubric in `references/20-reporting-severity-and-output-format.md`, and add a confidence and a "not verifiable" note to each finding.

## Redaction

Never print secrets, hashes, salts, keys, tokens or connection strings, in findings or in quoted evidence. The full redaction list and placeholder conventions are in `references/01-scope-and-safety.md`; apply them to everything you output.

## Next skills

- A specific query fails with ACCESS_DENIED or NOT_ENOUGH_PRIVILEGES, or a legitimate operation needs the minimal grant → load skill `altinity-expert-clickhouse-grants`
- Query or session log tables are missing, truncated or without TTL → load skill `altinity-expert-clickhouse-logs`
- Keeper or interserver exposure needs replication-side confirmation → load skill `altinity-expert-clickhouse-replication`
- Suspicious query volume or unexplained load from an account → load skill `altinity-expert-clickhouse-reporting`
