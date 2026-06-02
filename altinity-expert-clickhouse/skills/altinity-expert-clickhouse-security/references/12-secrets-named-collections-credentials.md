# Secrets, named collections, and credential exposure

Use this section when auditing named collections, DDL text, external integrations, and query logs.

## Redaction rule

Never print raw secrets. Apply the canonical redaction list in `01-scope-and-safety.md`. This section deals directly with credential material, so redact before showing any DDL, named collection, or query-log row.

## Check: named collection controls

If visible via configuration or access output, inspect:

```text
named_collection_control
show_named_collections
show_named_collections_secrets
allow_named_collection_override_by_default
named_collections_storage
```

A named collection that **masks its secret fields** (e.g. `system.named_collections` shows `host`, `password`, `user` as hidden) is the recommended, secure way to hold external credentials — it is the alternative to credentials-in-DDL that this skill promotes. **Its mere existence is not a finding; report it as Info/OK (good control).** Elevate only when one of the risk signals below shows the masking can be defeated.

Risk signals (these, not the collection's existence, drive severity):

- non-admin users can manage named collections (`NAMED COLLECTION ADMIN`).
- users can view named collection secrets — correlate with the secret-display chain in `09`: the server gate `display_secrets_in_show_and_select = 1` (from `system.server_settings`) **and** the `format_display_secrets_in_show_and_select` session setting **and** the `displaySecretsInShowAndSelect` privilege. A masked collection plus a satisfied chain is the real Medium/High risk; if the server gate is `0`, the masking holds and this is a latent risk, not an active one.
- override allowed by default when collections are used to hide credentials.
- unencrypted local named collection storage for sensitive credentials.
- external source grants plus named collection secret visibility.

## Check: hardcoded credentials in DDL

```sql
SELECT
    database,
    name,
    engine,
    create_table_query
FROM system.tables
WHERE positionCaseInsensitive(create_table_query, 'password') > 0
   OR positionCaseInsensitive(create_table_query, 'access_key') > 0
   OR positionCaseInsensitive(create_table_query, 'secret') > 0
   OR positionCaseInsensitive(create_table_query, 'token') > 0
   OR positionCaseInsensitive(create_table_query, '://') > 0
ORDER BY database, name;
```

Before showing results, redact secrets from `create_table_query`.

## Check: secrets in query logs

Search query logs only when necessary and redact aggressively.

```sql
SELECT
    event_time,
    user,
    address,
    query
FROM system.query_log
WHERE event_time >= now() - INTERVAL 30 DAY
  AND (
      positionCaseInsensitive(query, 'password') > 0
      OR positionCaseInsensitive(query, 'access_key') > 0
      OR positionCaseInsensitive(query, 'secret') > 0
      OR positionCaseInsensitive(query, 'token') > 0
  )
ORDER BY event_time DESC
LIMIT 100;
```

Report by category, never by value: "credential-like material in `db.table` DDL (redacted); prefer named collections with non-overridable secret fields and restricted visibility."
