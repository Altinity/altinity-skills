# Query log threat hunting

Use this section to identify observed suspicious behavior. Only use after checking log integrity.

## Check: failed privilege probes

```sql
SELECT
    user,
    missing_privileges,
    count() AS denied_attempts,
    max(event_time) AS last_seen,
    any(query) AS sample_query
FROM system.query_log
WHERE event_time >= now() - INTERVAL 30 DAY
  AND notEmpty(missing_privileges)
GROUP BY
    user,
    missing_privileges
ORDER BY denied_attempts DESC
LIMIT 100;
```

Risk signals:

- repeated attempts for `SYSTEM`, `SOURCES`, `FILE`, `URL`, `S3`, `CREATE USER`, `GRANT`.
- denied attempts followed by successful similar queries from another user.
- probes from unusual addresses.

## Check: login failures

```sql
SELECT
    user,
    client_address,
    auth_type,
    count() AS failures,
    min(event_time) AS first_seen,
    max(event_time) AS last_seen
FROM system.session_log
WHERE type = 'LoginFailure'
  AND event_time >= now() - INTERVAL 7 DAY
GROUP BY
    user,
    client_address,
    auth_type
ORDER BY failures DESC
LIMIT 100;
```

Look for credential stuffing, brute force, or misconfigured clients.

## Check: security-relevant DDL and access changes

```sql
SELECT
    event_time,
    user,
    address,
    query_kind,
    query
FROM system.query_log
WHERE event_time >= now() - INTERVAL 30 DAY
  AND type IN ('QueryFinish', 'ExceptionBeforeStart', 'ExceptionWhileProcessing')
  AND match(lower(query), '\\b(create|alter|drop|grant|revoke|attach)\\s+(user|role|row policy|settings profile|quota|view|materialized view|named collection)\\b')
ORDER BY event_time DESC
LIMIT 200;
```

## Check: data export patterns

Look for `INSERT INTO FUNCTION`, external table functions, object storage writes, large result sets, or unusual output formats.

```sql
SELECT
    user,
    address,
    count() AS queries,
    sum(read_rows) AS read_rows,
    sum(result_rows) AS result_rows,
    max(event_time) AS last_seen,
    any(query) AS sample_query
FROM system.query_log
WHERE event_time >= now() - INTERVAL 30 DAY
  AND type = 'QueryFinish'
  AND (
      positionCaseInsensitive(query, 'INSERT INTO FUNCTION') > 0
      OR notEmpty(used_table_functions)
  )
GROUP BY user, address
ORDER BY read_rows DESC
LIMIT 100;
```

## Check: executable UDF usage

This finds observed use. To assess the capability itself (which commands are configured, who can call them), see `17-executable-udf-and-code-execution.md`.

```sql
SELECT
    user,
    used_executable_user_defined_functions,
    count() AS queries,
    max(event_time) AS last_seen,
    any(query) AS sample_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 30 DAY
  AND notEmpty(used_executable_user_defined_functions)
GROUP BY
    user,
    used_executable_user_defined_functions
ORDER BY queries DESC;
```

Label these as `observed behavior`, distinct from `configuration risk`, and redact secrets in any sampled query text.
