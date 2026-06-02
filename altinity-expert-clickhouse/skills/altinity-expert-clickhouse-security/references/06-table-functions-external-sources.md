# Table functions and external source checks

Use this section for `url`, `s3`, `file`, `remote`, `remoteSecure`, `mysql`, `postgresql`, `jdbc`, `odbc`, `azureBlobStorage`, `hdfs`, `sqlite`, `redis`, and cluster variants.

## Security model

External-source table functions can create read/write paths outside normal table grants. They can be used for import, export, lateral movement, SSRF-like access, or local file exposure depending on grants and config.

ClickHouse uses `SOURCES` privileges for external data sources. In newer versions, source grants may distinguish `READ` and `WRITE`.

## Check: grants for external sources

Use `SHOW ACCESS` and search for:

```text
FILE
URL
S3
AZURE
HDFS
JDBC
ODBC
MYSQL
POSTGRES
REMOTE
SQLITE
REDIS
KAFKA
RABBITMQ
NATS
MONGO
```

Risk signals:

- broad `GRANT S3 ON *.*`
- broad `GRANT URL ON *.*`
- broad `GRANT FILE ON *.*`
- `READ, WRITE ON <source>` to non-admin users.
- source grants combined with `CREATE TEMPORARY TABLE`.

## Check: effective ability to use table functions

Many table functions also require `CREATE TEMPORARY TABLE`. Detect risky combinations:

```text
CREATE TEMPORARY TABLE + URL/S3/FILE/REMOTE/MYSQL/POSTGRES/JDBC/ODBC
```

Also consider `readonly = 2`, which allows `SET` and `CREATE TEMPORARY TABLE`; `readonly = 1` is more restrictive.

## Check: observed usage

```sql
SELECT
    user,
    address,
    normalized_query_hash,
    used_table_functions,
    count() AS queries,
    max(event_time) AS last_seen,
    any(query) AS sample_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 30 DAY
  AND notEmpty(used_table_functions)
GROUP BY
    user,
    address,
    normalized_query_hash,
    used_table_functions
ORDER BY queries DESC
LIMIT 100;
```

If `used_table_functions` is unavailable, use conservative query-text matching:

```sql
SELECT
    user,
    address,
    normalized_query_hash,
    count() AS queries,
    max(event_time) AS last_seen,
    any(query) AS sample_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 30 DAY
  AND match(lower(query), '\\b(s3|s3cluster|url|urlcluster|file|remote|remotesecure|mysql|postgresql|jdbc|odbc|azureblobstorage|hdfs|sqlite|redis)\\s*\\(')
GROUP BY
    user,
    address,
    normalized_query_hash
ORDER BY queries DESC
LIMIT 100;
```

## Cluster variants

Check `s3Cluster`, `urlCluster`, and other `-Cluster` functions. Treat older versions as higher risk if permission validation behavior is unclear. Use grants and logs as evidence — never test by running a table function.
