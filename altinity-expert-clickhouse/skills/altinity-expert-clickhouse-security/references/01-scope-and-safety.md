# Scope and safety

Use this section first for any live-system audit.

## Non-negotiable rules

- Use read-only SQL only.
- Do not run `CREATE`, `ALTER`, `DROP`, `TRUNCATE`, `INSERT`, `OPTIMIZE`, `SYSTEM`, `KILL`, `BACKUP`, `RESTORE`, or `SET` unless the user explicitly asks for a remediation command and understands it is not an audit probe.
- Do not run network probes through table functions.
- Do not use table functions to test whether exfiltration is possible.
- Do not attempt online password guessing or authentication attempts.
- Do not print secrets, password hashes, salts, or credential candidates.

## Initial evidence checklist

Collect when available:

```sql
SELECT version();
```

```sql
SHOW ACCESS;
```

```sql
SELECT name, value, changed
FROM system.settings
WHERE name IN
(
    'log_queries',
    'log_query_settings',
    'readonly',
    'allow_ddl'
)
ORDER BY name;
```

If cluster-wide checks are needed, prefer existing cluster topology supplied by the user. Do not guess cluster names. Ask for the cluster name, or inspect only local node data.

## Evidence confidence

Use these confidence labels:

- `high`: direct metadata evidence from SQL/config/logs.
- `medium`: strong pattern, but inherited roles/profiles or cluster coverage may be incomplete.
- `low`: inferred from partial DDL text, samples, or missing logs.
- `unknown`: cannot be verified with available access.

## Redaction (canonical)

This is the single source of truth for redaction; other sections refer here. When showing evidence, redact:

- password hashes and salts
- secrets in URLs and named collections
- cloud access keys and secret keys
- SAS tokens and signed URLs
- private keys
- bearer tokens and JWTs
- connection strings (including JDBC/ODBC) containing credentials
- internal hostnames, if the user asks for sanitized output

Use placeholders such as `<redacted_hash>`, `<redacted_secret>`, `<redacted_key>`, and `<internal_host>`.

## Reporting limitations

Always state SQL-only gaps, such as:

- cannot verify `listen_host`, TLS certificate configuration, or named collection storage without config access.
- cannot confirm full cluster posture from one node.
- cannot validate password strength from salted/bcrypt hashes except through safe offline denylist matching.
- cannot know whether broad grants are intentional without ownership context.

## Auditor privilege affects what is observed

State the identity and privilege level the audit ran as. A highly-privileged auditor sees a complete `SHOW ACCESS` and full system tables, but settings read from the live session reflect that session, not other users' enforced policy (see `09-settings-profiles-constraints-quotas.md`). A low-privilege auditor may see only a partial picture and should say so. Note the auditing identity in the report so session-derived readings are interpreted correctly.
