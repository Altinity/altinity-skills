-- Altinity Deploy ClickHouse — post-deploy smoke test (read-only)
-- Run all queries below. Each block is independent; on UNKNOWN_TABLE, skip
-- and note the table is unavailable in this build/version.

------------------------------------------------------------------------
-- 1. Server identity and uptime
------------------------------------------------------------------------
SELECT
    hostName()                         AS hostname,
    version()                          AS version,
    getMacro('cluster')                AS cluster_macro,
    getMacro('shard')                  AS shard_macro,
    getMacro('replica')                AS replica_macro,
    uptime()                           AS uptime_seconds,
    formatReadableTimeDelta(uptime())  AS uptime_human;

------------------------------------------------------------------------
-- 2. Cluster topology (clustered installs)
------------------------------------------------------------------------
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    is_local,
    errors_count
FROM system.clusters
ORDER BY cluster, shard_num, replica_num
LIMIT 100;

------------------------------------------------------------------------
-- 3. Keeper / ZooKeeper connectivity
------------------------------------------------------------------------
-- Reachable if this returns rows; errors here indicate Keeper is unreachable.
SELECT name, value, ctime, mtime
FROM system.zookeeper
WHERE path = '/'
LIMIT 10;

------------------------------------------------------------------------
-- 4. Replica health (only meaningful if Replicated* tables exist)
------------------------------------------------------------------------
SELECT
    database,
    table,
    is_readonly,
    is_session_expired,
    future_parts,
    parts_to_check,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    absolute_delay,
    last_queue_update_exception
FROM system.replicas
ORDER BY (is_readonly, queue_size) DESC
LIMIT 50;

------------------------------------------------------------------------
-- 5. Errors in the last hour
------------------------------------------------------------------------
SELECT
    name,
    value,
    last_error_time,
    last_error_message
FROM system.errors
WHERE last_error_time >= now() - INTERVAL 1 HOUR
ORDER BY last_error_time DESC
LIMIT 50;

------------------------------------------------------------------------
-- 6. Live metrics sample
------------------------------------------------------------------------
SELECT metric, value
FROM system.metrics
WHERE metric IN (
    'TCPConnection',
    'HTTPConnection',
    'Query',
    'BackgroundMergesAndMutationsPoolTask',
    'MemoryTracking',
    'ReplicatedFetch',
    'ReplicatedSend',
    'PartsActive',
    'PartMutation'
)
ORDER BY metric;

------------------------------------------------------------------------
-- 7. Disks and storage
------------------------------------------------------------------------
SELECT
    name,
    path,
    formatReadableSize(free_space)  AS free,
    formatReadableSize(total_space) AS total,
    round(100.0 * (total_space - free_space) / total_space, 1) AS used_pct,
    type,
    is_read_only
FROM system.disks
ORDER BY name;

------------------------------------------------------------------------
-- 8. Async metrics — system load signals
------------------------------------------------------------------------
SELECT metric, value
FROM system.asynchronous_metrics
WHERE metric IN (
    'OSMemoryTotal',
    'OSMemoryAvailable',
    'CGroupMemoryUsed',
    'CGroupMaxCPU',
    'LoadAverage1',
    'jemalloc.resident',
    'MaxPartCountForPartition'
)
ORDER BY metric;
