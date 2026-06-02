# Encryption at rest, storage credentials, and backups

Use this section for data-at-rest protection, credentials embedded in storage configuration, and backup destinations. Most of this is config-level; state SQL-only gaps clearly.

## Check: disks and storage policies

```sql
SELECT
    name,
    type,
    path,
    is_encrypted,
    keep_free_space
FROM system.disks
ORDER BY name;
```

Column names vary by version; inspect with `DESCRIBE TABLE system.disks` if `is_encrypted` is absent.

Risk signals:

- external/object-storage disks (`s3`, `azure`, `web`, `hdfs`) whose credentials are defined inline in `storage_configuration` rather than in a named collection.
- no encrypted disk (`type = encrypted`) for sensitive datasets where at-rest encryption is required.
- local disks on volumes without OS/filesystem-level encryption (not verifiable from SQL — note as a gap).

## Check: storage credentials in configuration

Disk credentials (`access_key_id`, `secret_access_key`, `account_key`, connection strings) live in `storage_configuration` in `config.xml`/`config.d`. Request config and check whether credentials are inline vs. referenced from a named collection. Cross-reference `12-secrets-named-collections-credentials.md`. Redact per `01-scope-and-safety.md`.

## Check: encryption codecs

Column-level encryption uses `CODEC(AES_128_GCM_SIV)` / `AES_256_GCM_SIV` with keys from `encryption_codecs` in config.

```sql
SELECT
    database,
    table,
    name,
    type,
    compression_codec
FROM system.columns
WHERE positionCaseInsensitive(compression_codec, 'AES') > 0
ORDER BY database, table, name;
```

Note that encryption codec keys are config-only and never shown.

## Check: backup destinations

Backups are triggered by `BACKUP`/`RESTORE` (do not run them during an audit). Review their destinations and credentials from history:

```sql
SELECT
    name,
    status,
    error,
    start_time,
    end_time
FROM system.backups
ORDER BY start_time DESC
LIMIT 50;
```

Look in query logs for `BACKUP ... TO Disk(...)` / `TO S3(...)` and check destination exposure.

Risk signals:

- backups written to public or weakly-scoped object storage.
- backup credentials embedded in `BACKUP`/`RESTORE` statements (visible in query logs — redact).
- no encryption on backup destinations holding sensitive data.
- `RESTORE` privileges granted broadly (can overwrite data or restore stale credentials/users).

Separate at-rest confidentiality (encryption, storage-credential hygiene) from backup integrity/availability. Most of this is config-level: from SQL you can confirm encrypted disks and AES codecs were/were not observed, but `storage_configuration` and `encryption_codecs` keys require config.
