# Audit logging and log integrity checks

Use this section before relying on query-log conclusions.

## Check: logging settings baseline

```sql
SELECT
    name,
    value,
    changed
FROM system.settings
WHERE name IN
(
    'log_queries',
    'log_query_settings',
    'log_queries_probability',
    'log_formatted_queries'
)
ORDER BY name;
```

`log_query_settings` controls whether changed settings are written into `system.query_log.Settings` and OpenTelemetry span logs.

## Check: profiles disabling query settings logging

```sql
SELECT
    profile_name,
    user_name,
    role_name,
    setting_name,
    value,
    writability,
    inherit_profile
FROM system.settings_profile_elements
WHERE setting_name = 'log_query_settings'
  AND value IN ('0', 'false', 'False')
ORDER BY
    profile_name,
    user_name,
    role_name;
```

## Check: writable audit settings

```sql
SELECT
    profile_name,
    user_name,
    role_name,
    setting_name,
    value,
    writability,
    inherit_profile
FROM system.settings_profile_elements
WHERE setting_name IN ('log_queries', 'log_query_settings')
  AND writability != 'CONST'
ORDER BY
    profile_name,
    user_name,
    role_name,
    setting_name;
```

Risk signals:

- `log_queries = 0`
- `log_query_settings = 0`
- `log_queries_probability < 1`
- users can disable logging settings.
- logs are only local and cluster-wide collection is missing.

## Check: runtime evidence of missing settings logging

```sql
SELECT
    user,
    count() AS queries,
    countIf(notEmpty(Settings)) AS queries_with_logged_settings,
    countIf(positionCaseInsensitive(query, 'SET ') > 0 OR positionCaseInsensitive(query, ' SETTINGS ') > 0) AS queries_that_appear_to_change_settings,
    max(event_time) AS last_seen
FROM system.query_log
WHERE event_time >= now() - INTERVAL 30 DAY
  AND type IN ('QueryFinish', 'ExceptionBeforeStart', 'ExceptionWhileProcessing')
GROUP BY user
HAVING queries_that_appear_to_change_settings > 0
   AND queries_with_logged_settings = 0
ORDER BY queries_that_appear_to_change_settings DESC;
```

Do not conclude disabled logging from this alone. Possible causes include no real setting changes, sampling, local-only logs, or missing columns.

## Check: session log availability

```sql
SELECT
    type,
    count() AS events,
    min(event_time) AS first_seen,
    max(event_time) AS last_seen
FROM system.session_log
WHERE event_time >= now() - INTERVAL 30 DAY
GROUP BY type
ORDER BY type;
```

When settings logging is off, state the investigative impact: changed `readonly`, limit, and table-function settings will not be reconstructable from `query_log`.
