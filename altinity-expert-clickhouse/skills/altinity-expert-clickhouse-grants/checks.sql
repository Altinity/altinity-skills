-- @check grants-01 Access and authentication errors in system.errors (24h)
SELECT
  code,
  name,
  value AS count,
  last_error_time,
  substring(last_error_message, 1, 200) AS last_error_message
FROM system.errors
WHERE last_error_time >= now() - INTERVAL 24 HOUR
  AND (name ILIKE '%ACCESS_DENIED%'
       OR name ILIKE '%AUTH%'
       OR name ILIKE '%PASSWORD%')
ORDER BY last_error_time DESC
LIMIT 50
;

-- @check grants-02 Missing privileges from failed queries (exception_code 497, 24h)
SELECT
  missing_privileges,
  count(),
  groupUniqArray(exception),
  groupUniqArray(initial_user)
FROM clusterAllReplicas('{cluster}', system.query_log)
WHERE event_time > now() - INTERVAL 24 HOUR
  AND exception_code = 497
GROUP BY 1
ORDER BY 2
;

-- Current grants for affected users
-- @check grants-03 Current grants for affected users
WITH users AS (
  SELECT DISTINCT user
  FROM system.query_log
  WHERE event_time >= now() - INTERVAL 24 HOUR
    AND type > 2
    AND exception_code = 497
)
SELECT
  user_name AS user,
  access_type,
  database,
  table,
  column,
  is_partial_revoke
FROM system.grants
WHERE user_name IN (SELECT user FROM users)
ORDER BY user, access_type, database, table, column
;
-- Roles assigned to affected users
-- @check grants-04 Roles assigned to affected users
WITH users AS (
  SELECT DISTINCT user
  FROM system.query_log
  WHERE event_time >= now() - INTERVAL 24 HOUR
    AND type > 2
    AND exception_code = 497
)
SELECT user_name AS user, role_name, granted_role_name, granted_role_is_default
FROM system.role_grants
WHERE user_name IN (SELECT user FROM users)
ORDER BY user, role_name, granted_role_name;