# Reporting, severity, and output format

Use this section when producing the final audit output.

## Finding format

For each finding, include:

- `Severity`: critical, high, medium, low, info.
- `Confidence`: high, medium, low, unknown.
- `Evidence`: concise, redacted, and **reproducible** — see evidence rules below.
- `Why it matters`: specific ClickHouse impact.
- `Scope`: local node, cluster-wide, supplied config, or sampled logs.
- `Not verified`: relevant gaps.
- `Suggested confirmation`: safe next check.
- `Remediation`: only if user asked or after diagnosis is accepted.

## Evidence rules

Evidence must let the reader reproduce the finding without the audit session. State the query (or its identifying clause) and the source object, plus the redacted result that matters.

- Cite the **SQL query and the source** (`system.users`, `system.grants`, a server setting, `config.xml`), e.g. `SELECT name, auth_type FROM system.users WHERE has(auth_type,'plaintext_password') → default (users_xml), demo (local_directory)`.
- **Never** cite the conversation/transcript: no `turn 5 lines 13-21`, no message indices, no tool-output line numbers. Those are meaningless once the session ends.
- Quote the specific rows/values that triggered the finding (redacted), not a count alone.
- If a finding rests on a server setting or config, name the exact setting and its value.

## Severity rubric

Critical:

- direct unauthenticated/admin access from broad networks.
- admin-equivalent grants to exposed weakly authenticated users.
- source/table-function write paths enabling obvious exfiltration by non-admin users.
- SQL SECURITY NONE creation ability by untrusted users.
- broad impersonation into admin/security principals.
- executable UDF (server-side command execution) callable by non-trusted users.
- unauthenticated/exposed Keeper or interserver port reachable from untrusted networks.

High:

- broad source grants to non-admin users.
- plaintext password on an account with sensitive grants **reachable from broad/untrusted hosts** (`::/0`).
- `WITH GRANT OPTION` on broad privileges.
- audit logging disabled for privileged users.
- definer user has excessive privileges and exposed views.
- storage/backup credentials in cleartext config or DDL, or backups to weakly-scoped destinations.
- unauthenticated dynamic HTTP query handler or Play UI reachable from untrusted networks.

Medium:

- plaintext password / superuser `default` that is **host-restricted** (not `::/0`) to internal/known addresses — bounded blast radius; flag "Critical if host scope is relaxed". Do not rate this High solely on the plaintext/superuser facts when the host ACL contains it.
- missing quotas/constraints for app or BI users.
- broad read-only access without resource limits.
- old-style source grants where read/write split is unavailable.
- named collection override risk without confirmed secret exposure.

Low:

- hardening gaps with limited blast radius.
- unused risky features with no grants or observed usage.
- documentation/ownership gaps.

Info:

- expected no-password definer principal with minimal grants.
- named collection that correctly masks its secret fields (a good control; elevate only if secret-display capability/grants or non-admin `NAMED COLLECTION ADMIN` can reveal it).
- `ALL` held by an expected operator/break-glass/service account.
- good controls observed.
- checks not applicable.

## Correlate before assigning severity

Severity is a property of the correlated situation, not of a single setting or grant. Apply these before finalizing findings, or severities will be both inflated and fragmented:

- **Merge same-principal findings.** Plaintext auth + `ALL` + broad `WITH GRANT OPTION` on one account is one correlated finding (often Critical), not three separate Highs. Report the account, then the combined blast radius.
- **Do not double-count `ALL`-implied privileges.** `ALL` already implies `SYSTEM`, `INTROSPECTION`, `SOURCES`/`S3`/`URL`/`FILE`, etc. Counting the `ALL`-holders again under each derived privilege inflates findings. Report derived privileges only for principals that hold them *without* `ALL`. See `03-users-roles-grants-rbac.md`.
- **Deduplicate identities.** The same human often appears as multiple principals (e.g. a local user and an SSO/OAuth identity like `name` and `name@example.com`). Note the likely link instead of reporting each as a separate finding. See `03`.
- **Distinguish expected admins/service accounts.** `ALL` on `clickhouse_operator`, a break-glass admin, or a named service role is usually by design. Flag the *unexpected* holders and the *size* of the admin set, not the existence of admins. Ask for ownership context when unsure.
- **Gate auth/privilege severity on reachability.** A weak/powerful account locked to localhost or an operator subnet is far lower severity than the same account on `::/0`. Always fold in `host_ip`/`host_names` from `system.users` (it is SQL-visible) before rating. See `05-network-exposure-and-tls.md`.
- **A correct security control is not a finding.** A named collection that masks its secrets, an expected no-password definer principal, or present row policies are good controls — report them as Info/OK and elevate only when a correlated weakness (e.g. secret-display capability, write privileges) defeats them. See `12-secrets-named-collections-credentials.md`.
- **Authority = grants, not settings.** Decide read/write capability from RBAC grants, not `readonly`/`allow_ddl`. Don't credit a `readonly` profile as the control that makes an over-granted account safe — that's a design smell, and `readonly` is a mutable overlay. See `03-users-roles-grants-rbac.md`.
- **Read policy from configuration, not the auditor's live session.** Settings like `max_concurrent_queries_for_user` read from the current connection reflect the auditor's own session, not other users' profiles. Read `system.settings_profile_elements`. See `09-settings-profiles-constraints-quotas.md`.

## Structure

Lead with a short **Diagnosis** that names the correlated root risk, not a single setting (e.g. "the risk is not the table function but that user X combines `CREATE TEMPORARY TABLE` with broad `URL`/`S3` grants and writable audit settings"). End with: top risks, strongest evidence, highest-confidence safe next checks, explicit unknowns. Don't restate generic checklists once findings are known. Redact per `01`; when query text contains secrets, show only a sanitized excerpt.
