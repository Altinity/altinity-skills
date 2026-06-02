Perform a read-only ClickHouse security audit of this server.

## Connection

Connect using clickhouse-client with these environment variables:
- Host: ${CLICKHOUSE_HOST}
- Port: ${CLICKHOUSE_PORT} (default: 9000)
- User: ${CLICKHOUSE_USER}
- Password: ${CLICKHOUSE_PASSWORD}
- Secure: ${CLICKHOUSE_SECURE} (if 1, add --secure)

## Task

Use the `altinity-expert-clickhouse-security` skill instructions in:
`../skills/altinity-expert-clickhouse-security/SKILL.md`
Follow that workflow and load the relevant `references/*.md` files as needed.

This is a **read-only** audit. Do not create, alter, or drop anything, do not
attempt password guessing, and never print secrets, password hashes, or
credential values — redact them.

Focus your analysis on the security-relevant objects on this server, including
the test users, roles, and grants whose names begin with `sec_`, and the
`altinity-expert-clickhouse-security` database.

## Areas to Audit

1. **Authentication** — auth methods, plaintext passwords, weak/known passwords, broad host access, missing expiration, multiple auth methods.
2. **RBAC and grants** — admin-equivalent grants, `WITH GRANT OPTION`, `ACCESS MANAGEMENT`, broad external-source (`S3`/`URL`/`FILE`) grants, `CREATE TEMPORARY TABLE` combinations.
3. **Definer views and principals** — `SQL SECURITY DEFINER` views and whether the definer is over-privileged relative to the view.
4. **Row policies** — users constrained by a row policy who also hold write privileges that can defeat it.
5. **Secrets** — credentials embedded in table DDL (must be detected and redacted).

## Output Format

Produce a markdown report with:
1. Clear section headers per area.
2. For each finding: severity, confidence, evidence (redacted), why it matters, and what could not be verified from SQL-only access.
3. A short top-risks summary.

Use the standard severity classification:
- **Critical**: direct, high-impact exposure (e.g. admin-equivalent + broad exposure, obvious exfiltration path).
- **Major/High**: serious weakness needing prompt attention.
- **Moderate/Medium**: elevated risk, depends on context.
- **Minor/Low**: hardening gaps with limited blast radius.
- **OK/Info**: expected design or good control.
