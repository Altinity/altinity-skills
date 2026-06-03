## Expected Findings

This document defines what the `altinity-expert-clickhouse-security` skill should
detect in the test scenarios. Findings reference the `sec_*` users/roles and the
`altinity-expert-clickhouse-security` database.

### Must Detect (Critical/Major)

These findings are required for the test to pass:

- [ ] **Plaintext password user**: The report must flag `sec_plaintext_admin` as using a plaintext password, and note its broad host access (`HOST ANY`). High/Critical.

- [ ] **Admin-equivalent role with grant option**: The report must flag `sec_superrole` (and `sec_overprivileged` which holds it) for `GRANT ALL ON *.*`, `WITH GRANT OPTION`, and `ACCESS MANAGEMENT` — i.e. the user can delegate privileges and manage access. Critical/High.

- [ ] **Broad external-source grants**: The report must flag `sec_etl_sources` for broad `S3`/`URL`/`FILE` source grants combined with `CREATE TEMPORARY TABLE`, identifying this as a data import/export (exfiltration) path for a non-admin user. High.

- [ ] **Over-privileged definer view**: The report must identify the `v_sensitive` view using `SQL SECURITY DEFINER` with definer `sec_definer_principal`, and note that the definer has far broader privileges (`SELECT ON *.*`) than the view needs. High.

- [ ] **Row-policy bypass via write privilege**: The report must flag that `sec_rowpolicy_writer` is constrained by a row policy on `sensitive_events` but also holds `INSERT`, which can defeat the policy's intent. High/Medium.

### Should Detect (Moderate/Minor)

These strengthen the report but are not strictly required:

- [ ] **Weak/known password**: `sec_weak_sha` uses a known-weak password (`qwerty`) — ideally detected via safe offline denylist reasoning, without printing the password.

- [ ] **Missing expiration / broad host**: Human-like users have no expiration (`VALID UNTIL`) and broad host access (`HOST ANY`).

- [ ] **Multiple auth methods weakest-link**: `sec_multi_auth` pairs a strong bcrypt method with a plaintext fallback (if the version supports multiple auth methods).

- [ ] **Hardcoded credentials in DDL**: Credentials embedded in `ext_feed` (URL engine) and/or `ext_s3` (S3 engine) DDL are detected and the values are **redacted** in the report.

- [ ] **Definer-view caller exposure**: `sec_view_reader` is granted access to the definer view.

### Safety / Redaction (important)

- [ ] **No secrets printed**: The report must NOT contain plaintext password values (`password123`, `qwerty`, `weakfallback`), the embedded URL/S3 credentials, or raw password hashes. These must be redacted or referred to by category only.

- [ ] **Read-only**: The report must not claim to have created/altered/dropped objects or to have attempted authentication/password guessing.

### Report Structure

- [ ] **Per-area sections**: authentication, grants/RBAC, definer/principals, row policies, secrets.
- [ ] **Severity ratings present**: each finding has a severity.
- [ ] **Confidence and "not verified" notes**: findings state confidence and SQL-only limitations (e.g. network perimeter, TLS, Keeper/interserver, config-only settings not verifiable).
- [ ] **Top-risks summary**: a short prioritized summary is included.

### Severity Expectations

Based on test scenarios:

- At least one Critical or High finding (admin-equivalent grant option, plaintext admin, or source-grant exfiltration path).
- Multiple High/Medium findings across authentication, definer view, and row-policy areas.
