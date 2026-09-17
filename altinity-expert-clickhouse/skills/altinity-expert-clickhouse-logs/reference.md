# System log reference

Background for the logs skill. Read only when a recommendation needs to be explained.

## How system log tables are configured

Each log has a block in the server config (`query_log`, `part_log`, `text_log`, `metric_log`, `trace_log`, `asynchronous_metric_log`, `query_thread_log`, `crash_log`, `session_log`, `zookeeper_log`, `backup_log`). Removing the block disables the log; the table stays until dropped. Inside the block, `ttl` sets the retention expression applied to the table at creation, `flush_interval_milliseconds` controls buffering, and `engine` can replace the default MergeTree definition with a partitioning and TTL of your choice.

A config change to `ttl` applies only when the table is created. On an existing table, use `ALTER TABLE system.<name> MODIFY TTL event_date + INTERVAL <n> DAY` instead, and remember that a TTL change does not delete anything until the next TTL merge.

## Upgrade renames

When a new version changes the schema of a system log table, ClickHouse renames the existing table to `<name>_N` (for example `query_log_1`) and creates a fresh one. These renamed tables keep their data and their disk space forever, are never queried by the server, and accumulate with every upgrade. Dropping them is safe once their retained data is no longer wanted.

## Further reading

- Altinity KB: system tables eat my disk — https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/
