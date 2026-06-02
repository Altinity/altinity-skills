# Password hash hygiene

Use this section only when the user has legitimate administrative access to exported auth metadata or configuration. Keep this strictly defensive.

## Safety rules

- Do not print password hashes, salts, plaintext passwords, or cracked candidates.
- Do not perform online password guessing against ClickHouse.
- Do not run large-scale cracking.
- Optional offline denylist matching is acceptable only against a small, local, known-weak list and should report only the affected user and risk category, not the matched password.

## Check: hash and auth inventory

Use `system.users` first:

```sql
SELECT
    name,
    auth_type,
    valid_until,
    host_ip,
    host_names,
    host_names_regexp
FROM system.users
ORDER BY name;
```

If config/access files are supplied, inventory:

- plaintext password entries.
- `password_sha256_hex`
- `password_double_sha1_hex`
- salted `sha256_hash`
- `bcrypt_hash`
- `scram_sha256`
- multiple auth methods.

## Check: plaintext and empty passwords

Always read the account's host ACL (`host_ip`/`host_names`) before rating a plaintext/empty password — severity is gated by reachability, not by the auth method alone:

- `plaintext_password` (or `<password>…</password>`) on an account reachable from broad/untrusted hosts (`::/0`, `0.0.0.0/0`): **High** (Critical if the account is also a superuser / has access-management or broad grants).
- the same account **host-restricted** to internal pod IPs, localhost, or a narrow allowlist (not `::/0`): **Medium** — the plaintext credential is recoverable from `users.xml`/the operator secret, but its blast radius is bounded by the host ACL. This is the common operator-managed `default` pattern; note "Critical if the host scope is ever relaxed" rather than rating it High outright.
- `<password></password>` (empty): Critical only if it permits direct login from reachable hosts; otherwise Medium.
- a known test/throwaway environment lowers severity further.

Do not classify `no_password` as password weakness. Use `04-definer-impersonation-principals.md`.

## Check: duplicate hashes

Compare hashes across users without printing them.

Reliable for:

- unsalted `password_sha256_hex`
- unsalted `password_double_sha1_hex`
- plaintext entries
- identical hash+salt pairs.

Less reliable:

- salted SHA256 where same password produces different salts.
- bcrypt because each hash normally uses a unique salt.

Finding example:

`Two users share the same stored password hash. This likely means shared credentials or cloned credentials. Severity is higher because one user has admin grants.`

## Check: small weak-password denylist

For unsalted SHA256 and double SHA1, compare against a small denylist such as:

```text
empty
password
qwerty
123456
123456789
admin
clickhouse
default
changeme
test
password123
```

Report:

`User X appears to use a known weak password from the local denylist. The candidate value is not shown.`

## Check: algorithm risk

Classify:

- bcrypt: preferred for local password hashes.
- SHA256: acceptable but faster to brute force if hashes are compromised.
- double SHA1: compatibility-only; ask why it is needed.
- plaintext: high concern.
- no password/no authentication: principal-design question, not password hygiene.

## Check: password complexity policy

If config is available, inspect `password_complexity` rules. If SQL-only, mark as not verifiable.

## Correlate with exposure

Password findings become severe when combined with:

- broad host access.
- admin grants.
- default user.
- recent login failures.
- no TLS or exposed plaintext ports.
