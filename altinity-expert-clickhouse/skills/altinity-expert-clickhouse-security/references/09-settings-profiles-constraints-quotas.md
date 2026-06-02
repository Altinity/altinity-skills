# Settings profiles, constraints, and quotas

Use this section to check whether users can weaken their own controls or overload the service.

## Check: profiles

```sql
SELECT
    name,
    storage,
    num_elements,
    apply_to_all,
    apply_to_list,
    apply_to_except
FROM system.settings_profiles
ORDER BY name;
```

```sql
SELECT
    profile_name,
    user_name,
    role_name,
    setting_name,
    value,
    min,
    max,
    writability,
    inherit_profile
FROM system.settings_profile_elements
ORDER BY
    profile_name,
    user_name,
    role_name,
    index;
```

## Check: important settings

Focus on:

- `readonly`
- `allow_ddl`
- `max_memory_usage`
- `max_execution_time`
- `max_rows_to_read`
- `max_bytes_to_read`
- `max_result_rows`
- `max_result_bytes`
- `max_sessions_for_user`
- `max_concurrent_queries_for_user`
- `log_queries`
- `log_query_settings`
- `allow_introspection_functions`
- `query_cache_share_between_users` (cross-user data leakage: a shared query cache can return another user's cached result rows)
- secret display (`display_secrets_in_show_and_select` / `format_display_secrets_in_show_and_select`) — see the dedicated check below.
- settings enabling experimental or external access.

### Check: secret display requires three things, not one

Revealing masked secrets through `SHOW CREATE` / `SELECT` is gated by a chain — **all three** must hold, so do not rate it on one of them alone:

1. **Server-level gate:** `display_secrets_in_show_and_select = 1`. This is the server setting (read it from `system.server_settings`), default `0`. If this is `0`, secrets are masked regardless of anything else — there is no finding.
2. **Session/format setting:** `format_display_secrets_in_show_and_select = 1`. This is the per-query/session/profile setting (read from `system.settings` / `system.settings_profile_elements`), default `0`.
3. **Privilege:** the `displaySecretsInShowAndSelect` grant, required for a principal to set #2.

```sql
SELECT name, value, changed FROM system.server_settings
WHERE name = 'display_secrets_in_show_and_select';
```

```sql
SELECT name, value, changed FROM system.settings
WHERE name = 'format_display_secrets_in_show_and_select';
```

Severity guidance:

- Server gate `0`: Info/OK even if the privilege is widely granted (the capability is dormant). Note it as a latent risk.
- Server gate `1` **and** the privilege granted to principals that can run `SHOW CREATE`/`SELECT` on secret-bearing objects (Kafka/engine DDL, storage keys, named collections — see `07` and `12`): High. Cite the exact server setting value, not just the session setting.
- Do not cite only `format_display_secrets_in_show_and_select` from `system.settings` and call it "server-wide" — that is the session setting, not the server gate.

### Read policy from profiles, not the auditor's session

A setting value read from `system.settings` reflects the **current connection** — i.e. the auditor's own session and privileges — not other users' enforced policy. Do not report a per-user limit (e.g. `max_concurrent_queries_for_user = 0`) as a finding based on the live session. Read enforced policy from `system.settings_profile_elements` (and per-user/role assignment) using the profile queries above.

## Check: risky readonly mode

`readonly = 1` allows reads and prevents settings changes.
`readonly = 2` allows reads plus `SET` and `CREATE TEMPORARY TABLE`.

Risk combination:

```text
readonly = 2 + CREATE TEMPORARY TABLE + external source grants
```

## Check: constraints

Risk signals:

- sensitive settings are writable.
- app/BI users can change query limits.
- profiles inherit from broad/default profiles that override constraints.
- `settings_constraints_replace_previous` behavior is unknown in complex inheritance.

## Check: quotas

If quota system tables are available, inspect them. Otherwise use `SHOW ACCESS` and configuration extracts.

Risk signals:

- external-facing users have no query/rows/errors limits.
- users with source grants have no bandwidth/result limits.
- high-frequency app users have no concurrency or session caps.

Separate stability risk from data-security risk: a missing memory limit is DoS; a writable `readonly`/`log_query_settings` is audit/control bypass.
