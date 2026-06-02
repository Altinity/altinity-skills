# Table engines and external integration checks

Use this section for persistent external integrations in table metadata.

## Check: external table engines

```sql
SELECT
    database,
    name,
    engine,
    create_table_query
FROM system.tables
WHERE engine IN
(
    'MySQL',
    'PostgreSQL',
    'MongoDB',
    'SQLite',
    'S3',
    'URL',
    'Kafka',
    'RabbitMQ',
    'HDFS',
    'JDBC',
    'ODBC',
    'EmbeddedRocksDB',
    'MaterializedPostgreSQL'
)
ORDER BY database, name;
```

Risk signals:

- credentials embedded directly in DDL.
- public object storage paths.
- internal hosts that expose lateral movement.
- write-capable engines owned by broad roles.
- engines using weak or plaintext transport.

## Check: table engine grant enforcement

Inspect server setting if available:

```sql
SELECT
    name,
    value,
    changed
FROM system.server_settings
WHERE name = 'access_control_improvements';
```

If the nested setting is available in config, check:

```text
access_control_improvements.table_engines_require_grant
```

If `table_engines_require_grant = false`, creating tables with specific engines may ignore table engine grants for backward compatibility. Flag when non-admin users can create tables and dangerous engines are available.

## Check: table engine grants

Search `SHOW ACCESS` for:

```text
TABLE ENGINE
```

Risk signals:

- broad `GRANT TABLE ENGINE ON *`.
- grants for external engines to non-ETL users.
- no grants visible while enforcement is off and broad `CREATE TABLE` exists.

Persistent engines are often intentional. Focus findings on exposed credentials, available write paths, owner/role vs. integration purpose, and whether table-engine grants are enforced for this version/config — not on the engine's existence.
