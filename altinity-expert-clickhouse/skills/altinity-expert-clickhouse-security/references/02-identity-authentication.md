# Identity and authentication checks

Use this section to evaluate ClickHouse user authentication posture. Do not treat authentication method alone as risk; correlate with host restrictions, grants, and intended role.

## Check: authentication method inventory

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
ORDER BY name;
```

`system.users` has no `valid_until` column on current versions (expiration became per-auth-method). Read expiration from `SHOW CREATE USER <name>` / `SHOW ACCESS` (the `VALID UNTIL` clause), not from `system.users`.

Classify:

- `plaintext_password`: high concern because plaintext storage is avoidable.
- `sha256_password` / `sha256_hash`: acceptable but weaker than bcrypt if hashes are compromised.
- `double_sha1_password` / `double_sha1_hash`: usually compatibility-driven; ask why it is needed.
- `bcrypt_password` / `bcrypt_hash`: preferred local password storage.
- `ldap`, `kerberos`, `ssl_certificate`, `ssh_key`, `jwt`, `http`: evaluate the external mechanism and local fallback methods.
- `no_password` / `no_authentication`: neutral by itself. See `04-definer-impersonation-principals.md`.

## Check: default user posture

Focus on `default` because it is commonly overused.

Risk signals:

- broad host access.
- admin-equivalent grants.
- local password auth with weak method.
- used by applications and administrators simultaneously.
- used for inter-node communication without clear isolation.

Do not recommend deleting or disabling `default` blindly. First confirm internode usage, automation, and cluster configuration.

## Check: credential expiration

Expiration is the `VALID UNTIL` clause shown by `SHOW CREATE USER <name>` / `SHOW ACCESS` (not a `system.users` column on current versions). Look for it there.

Risk signals:

- human users with no expiration policy.
- expired credentials still configured.
- multiple auth methods where a weak fallback lacks expiration.

## Check: multiple authentication methods

A user with multiple auth methods can authenticate through any listed method. One weak fallback can undermine a strong primary method.

Risk examples:

- `bcrypt_password` plus `plaintext_password`.
- external auth plus local password fallback with broad hosts.
- certificate/SSH plus no-password fallback.

Rate an auth method only together with host restriction and grants: `sha256_password` from a narrow IP with read-only grants is low; `plaintext_password` from broad hosts with grant option is high.
