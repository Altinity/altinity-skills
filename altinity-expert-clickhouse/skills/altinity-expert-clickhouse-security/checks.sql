-- altinity-expert-clickhouse-security — safe, read-only evidence collection (fast first pass).
-- Local node only; cluster-wide checks live in references/15. Nothing here modifies state.
-- Some columns vary by version; if a query errors, DESCRIBE TABLE system.<table> and adjust.
-- For depth on any result, load the matching references/NN-*.md file.

-- 1. Identity of the server and the audit
SELECT version() AS version, hostName() AS host, uptime() AS uptime_s, currentUser() AS audit_user;

-- 2. Full access dump (authoritative; redact secrets before sharing)
SHOW ACCESS;

-- 3. User inventory: auth method, host ACL, default roles (references/02, 05, 13)
--    Expiration (VALID UNTIL) is not a system.users column on current versions; read it from
--    SHOW CREATE USER / SHOW ACCESS when needed.
SELECT
    name, auth_type,
    host_ip, host_names, host_names_regexp, host_names_like,
    default_roles_all, default_roles_list, default_roles_except
FROM system.users
ORDER BY name;

-- 4. Roles and role graph (references/03)
SELECT name FROM system.roles ORDER BY name;
SELECT user_name, role_name, granted_role_name, granted_role_is_default, with_admin_option
FROM system.role_grants
ORDER BY user_name, role_name, granted_role_name;

-- 5. Grant posture overview per principal (references/03)
SELECT
    coalesce(user_name, '') AS user,
    coalesce(role_name, '') AS role,
    countIf(database IS NULL) AS global_grants,
    max(grant_option) AS any_grant_option,
    groupUniqArray(access_type) AS access_types
FROM system.grants
GROUP BY user, role
ORDER BY any_grant_option DESC, length(access_types) DESC
LIMIT 200;

-- 6. Admin-equivalent and access-management holders (references/03)
SELECT user_name, role_name, grant_option
FROM system.grants
WHERE access_type IN ('ALL', 'ACCESS MANAGEMENT')
ORDER BY grant_option DESC, user_name, role_name;

-- 7. Security-sensitive privileges: external sources, code/secret/introspection, definer (references/03, 06, 12, 17)
SELECT user_name, role_name, access_type, grant_option
FROM system.grants
WHERE access_type IN (
    'SOURCES','S3','URL','FILE','REMOTE','MYSQL','POSTGRES','HDFS','AZURE','MONGO','ODBC','JDBC','SQLITE','REDIS','KAFKA',
    'READ','WRITE','TABLE ENGINE','SYSTEM','INTROSPECTION',
    'NAMED COLLECTION ADMIN','displaySecretsInShowAndSelect','SET DEFINER','ALLOW SQL SECURITY NONE','IMPERSONATE','CREATE TEMPORARY TABLE'
)
ORDER BY access_type, grant_option DESC, user_name
LIMIT 500;

-- 8. Column-scoped SELECT grants vs sensitive-column exposure (references/08)
SELECT user_name, role_name, database, table, column, access_type
FROM system.grants
WHERE column IS NOT NULL
ORDER BY database, table, column
LIMIT 200;

-- 9. Row policies (references/08)
SELECT name, short_name, database, table, select_filter, is_restrictive, apply_to_all, apply_to_list, apply_to_except
FROM system.row_policies
ORDER BY database, table, name;

-- 10. Settings profiles and the security-relevant elements (references/09)
SELECT name, storage, num_elements, apply_to_all, apply_to_list, apply_to_except
FROM system.settings_profiles
ORDER BY name;
SELECT profile_name, user_name, role_name, setting_name, value, min, max, writability, inherit_profile
FROM system.settings_profile_elements
WHERE setting_name IN (
    'readonly','allow_ddl','log_queries','log_query_settings','allow_introspection_functions',
    'max_memory_usage','max_execution_time','max_concurrent_queries_for_user',
    'format_display_secrets_in_show_and_select','query_cache_share_between_users'
)
ORDER BY profile_name, user_name, role_name, setting_name;

-- 11. Quotas (references/09)
SELECT name, storage, keys, durations, apply_to_all, apply_to_list, apply_to_except
FROM system.quotas
ORDER BY name;

-- 12. Named collections — names only; secrets are masked, never select values (references/12)
SELECT name FROM system.named_collections ORDER BY name;

-- 13. User-defined / executable functions = code-execution surface (references/17)
SELECT name, origin, create_query FROM system.functions WHERE origin != 'System' ORDER BY origin, name;

-- 14. Server-level secret-display gate (references/09, 12).
--     NOTE: ports / listen_host / TLS are NOT in system.server_settings — they are config-only;
--     confirm tcp_port_secure / https_port / listen_host from config.xml (references/05).
SELECT name, value, changed
FROM system.server_settings
WHERE name = 'display_secrets_in_show_and_select';

-- 15. Cluster topology and the user used for distributed access (references/15, 16).
--     Interserver transport security (TLS) is NOT exposed here; confirm <secure> in remote_servers config.
SELECT cluster, shard_num, replica_num, host_name, port, is_local, user
FROM system.clusters
ORDER BY cluster, shard_num, replica_num;

-- 16. Persistent external-engine tables and any SQL SECURITY DEFINER/NONE views (references/04, 07)
--     Redact create_table_query before sharing — it can contain credentials.
SELECT database, name, engine
FROM system.tables
WHERE engine IN ('MySQL','PostgreSQL','MongoDB','SQLite','S3','URL','Kafka','RabbitMQ','HDFS','JDBC','ODBC','EmbeddedRocksDB','MaterializedPostgreSQL')
   OR positionCaseInsensitive(create_table_query, 'SQL SECURITY') > 0
ORDER BY database, name;

-- 17. Logging/auth-audit baseline (references/10, 11).
SELECT name, value, changed FROM system.settings
WHERE name IN ('log_queries','log_query_settings','log_queries_probability') ORDER BY name;
-- Table existence is the key signal: session_log_exists = 0 means login/auth auditing is OFF.
-- (Selecting from a missing log table errors, so probe existence here; get row counts from references/10,11.)
SELECT
    countIf(name = 'query_log')   AS query_log_exists,
    countIf(name = 'session_log') AS session_log_exists
FROM system.tables
WHERE database = 'system';
