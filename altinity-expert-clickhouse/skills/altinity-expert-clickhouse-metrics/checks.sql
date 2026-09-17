-- Real-time metrics checks (cluster-wide: one row set per host via hostName()).
-- Severity is computed in SQL: Critical / Major / Moderate / OK.
-- Statements with `@requires version...` headers are alternatives for the same
-- check: run the one matching the server version and skip the other.

-- @check metrics-01 Saturation summary per host: memory, running queries, connections
WITH
    am AS
    (
        SELECT
            hostName() AS host,
            maxIf(value, metric = 'MemoryResident') AS mem_resident,
            maxIf(value, metric = 'OSMemoryTotal') AS mem_total
        FROM clusterAllReplicas('{cluster}', system.asynchronous_metrics)
        WHERE metric IN ('MemoryResident', 'OSMemoryTotal')
        GROUP BY host
    ),
    m AS
    (
        SELECT
            hostName() AS host,
            toFloat64(sumIf(value, metric = 'Query')) AS running_queries,
            toFloat64(sumIf(value, metric LIKE '%Connection')) AS connections
        FROM clusterAllReplicas('{cluster}', system.metrics)
        WHERE metric = 'Query' OR metric LIKE '%Connection'
        GROUP BY host
    ),
    ss AS
    (
        SELECT
            hostName() AS host,
            maxIf(toFloat64OrZero(value), name = 'max_connections') AS max_connections,
            maxIf(toFloat64OrZero(value), name = 'max_concurrent_queries') AS max_concurrent_queries
        FROM clusterAllReplicas('{cluster}', system.server_settings)
        WHERE name IN ('max_connections', 'max_concurrent_queries')
        GROUP BY host
    )
SELECT host, resource, current, capacity, pct, severity
FROM
(
    SELECT
        host,
        'Memory (resident vs total RAM)' AS resource,
        formatReadableSize(mem_resident) AS current,
        formatReadableSize(mem_total) AS capacity,
        round(100.0 * mem_resident / nullIf(mem_total, 0), 1) AS pct,
        multiIf(pct > 90, 'Critical', pct > 80, 'Major', pct > 70, 'Moderate', 'OK') AS severity
    FROM am

    UNION ALL

    SELECT
        m.host AS host,
        'Running queries vs max_concurrent_queries' AS resource,
        toString(running_queries) AS current,
        toString(max_concurrent_queries) AS capacity,
        round(100.0 * running_queries / nullIf(max_concurrent_queries, 0), 1) AS pct,
        multiIf(pct > 90, 'Critical', pct > 75, 'Major', pct > 50, 'Moderate', 'OK') AS severity
    FROM m
    INNER JOIN ss ON ss.host = m.host

    UNION ALL

    SELECT
        m.host AS host,
        'Connections vs max_connections' AS resource,
        toString(connections) AS current,
        toString(max_connections) AS capacity,
        round(100.0 * connections / nullIf(max_connections, 0), 1) AS pct,
        multiIf(pct > 90, 'Critical', pct > 75, 'Major', pct > 50, 'Moderate', 'OK') AS severity
    FROM m
    INNER JOIN ss ON ss.host = m.host
)
ORDER BY host, resource;

-- @check metrics-02 Load average vs CPU cores per host (per-core metric names, before 26.8)
-- @requires version<26.8
SELECT
    host,
    round(load_1m, 2) AS load_1m,
    round(load_15m, 2) AS load_15m,
    cpu_count,
    round(100.0 * load_1m / nullIf(cpu_count, 0), 1) AS pct_1m,
    multiIf(load_15m > 2 * cpu_count, 'Critical', load_15m > cpu_count, 'Major', load_1m > cpu_count, 'Moderate', 'OK') AS severity
FROM
(
    SELECT
        hostName() AS host,
        maxIf(value, metric = 'LoadAverage1') AS load_1m,
        maxIf(value, metric = 'LoadAverage15') AS load_15m,
        countIf(metric LIKE 'OSIdleTimeCPU%' AND match(metric, '\\d$')) AS cpu_count
    FROM clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    WHERE metric IN ('LoadAverage1', 'LoadAverage15') OR metric LIKE 'OSIdleTimeCPU%'
    GROUP BY host
)
ORDER BY host;

-- @check metrics-02 Load average vs CPU cores per host (key_values map, 26.8+)
-- @requires version>=26.8
SELECT
    host,
    round(load_1m, 2) AS load_1m,
    round(load_15m, 2) AS load_15m,
    cpu_count,
    round(100.0 * load_1m / nullIf(cpu_count, 0), 1) AS pct_1m,
    multiIf(load_15m > 2 * cpu_count, 'Critical', load_15m > cpu_count, 'Major', load_1m > cpu_count, 'Moderate', 'OK') AS severity
FROM
(
    SELECT
        hostName() AS host,
        maxIf(value, metric = 'LoadAverage1') AS load_1m,
        maxIf(value, metric = 'LoadAverage15') AS load_15m,
        maxIf(length(key_values), metric = 'OSIdleTimeCPU') AS cpu_count
    FROM clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    WHERE metric IN ('LoadAverage1', 'LoadAverage15', 'OSIdleTimeCPU')
    GROUP BY host
)
ORDER BY host;

-- @check metrics-03 Replication metrics per host
SELECT
    host,
    readonly_replicas,
    round(max_absolute_delay_s) AS max_absolute_delay_s,
    sum_queue_size,
    max_inserts_in_queue,
    max_merges_in_queue,
    multiIf(
        readonly_replicas > 0, 'Critical',
        max_absolute_delay_s > 3600 OR sum_queue_size > 1000, 'Major',
        max_absolute_delay_s > 300 OR sum_queue_size > 200, 'Moderate',
        'OK') AS severity
FROM
(
    SELECT
        hostName() AS host,
        maxIf(value, metric = 'ReplicasMaxAbsoluteDelay') AS max_absolute_delay_s,
        maxIf(value, metric = 'ReplicasSumQueueSize') AS sum_queue_size,
        maxIf(value, metric = 'ReplicasMaxInsertsInQueue') AS max_inserts_in_queue,
        maxIf(value, metric = 'ReplicasMaxMergesInQueue') AS max_merges_in_queue
    FROM clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    WHERE metric IN ('ReplicasMaxAbsoluteDelay', 'ReplicasSumQueueSize', 'ReplicasMaxInsertsInQueue', 'ReplicasMaxMergesInQueue')
    GROUP BY host
) AS a
INNER JOIN
(
    SELECT hostName() AS host, sumIf(value, metric = 'ReadonlyReplica') AS readonly_replicas
    FROM clusterAllReplicas('{cluster}', system.metrics)
    WHERE metric = 'ReadonlyReplica'
    GROUP BY host
) AS m ON m.host = a.host
ORDER BY host;

-- @check metrics-04 Max parts per partition vs parts_to_delay_insert / parts_to_throw_insert
SELECT
    p.host AS host,
    max_parts_in_partition,
    parts_to_delay_insert,
    parts_to_throw_insert,
    multiIf(max_parts_in_partition > parts_to_throw_insert, 'Critical',
            max_parts_in_partition > parts_to_delay_insert, 'Major',
            max_parts_in_partition > parts_to_delay_insert * 0.7, 'Moderate',
            'OK') AS severity
FROM
(
    SELECT hostName() AS host, maxIf(value, metric = 'MaxPartCountForPartition') AS max_parts_in_partition
    FROM clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    WHERE metric = 'MaxPartCountForPartition'
    GROUP BY host
) AS p
INNER JOIN
(
    SELECT
        hostName() AS host,
        maxIf(toFloat64OrZero(value), name = 'parts_to_delay_insert') AS parts_to_delay_insert,
        maxIf(toFloat64OrZero(value), name = 'parts_to_throw_insert') AS parts_to_throw_insert
    FROM clusterAllReplicas('{cluster}', system.merge_tree_settings)
    WHERE name IN ('parts_to_delay_insert', 'parts_to_throw_insert')
    GROUP BY host
) AS t ON t.host = p.host
ORDER BY host;

-- @check metrics-05 Background pool utilization per host
WITH
    ['MergesAndMutations', 'Fetches', 'Move', 'Common', 'Schedule', 'BufferFlushSchedule', 'MessageBrokerSchedule', 'DistributedSchedule'] AS pool_tokens,
    ['pool', 'fetches_pool', 'move_pool', 'common_pool', 'schedule_pool', 'buffer_flush_schedule_pool', 'message_broker_schedule_pool', 'distributed_schedule_pool'] AS setting_tokens
SELECT
    m.host AS host,
    extract(m.metric, '^Background(.*)Task') AS pool_name,
    m.active_tasks,
    s.pool_size,
    round(100.0 * m.active_tasks / nullIf(s.pool_size, 0), 1) AS utilization_pct,
    multiIf(utilization_pct > 99, 'Major', utilization_pct > 90, 'Moderate', 'OK') AS severity
FROM
(
    SELECT
        hostName() AS host,
        metric,
        value AS active_tasks,
        concat('background_', lower(transform(extract(metric, '^Background(.*)PoolTask'), pool_tokens, setting_tokens, '')), '_size') AS setting_name
    FROM clusterAllReplicas('{cluster}', system.metrics)
    WHERE metric LIKE 'Background%PoolTask'
) AS m
INNER JOIN
(
    SELECT hostName() AS host, name, toFloat64OrZero(value) AS pool_size
    FROM clusterAllReplicas('{cluster}', system.server_settings)
    WHERE name LIKE 'background%pool_size'
) AS s ON s.host = m.host AND s.name = m.setting_name
WHERE s.pool_size > 0
ORDER BY utilization_pct DESC, host;

-- @check metrics-06 Failure and throttling counters since server start
SELECT
    hostName() AS host,
    event,
    value,
    multiIf(
        event IN ('RejectedInserts', 'ReplicatedPartFailedFetches', 'ZooKeeperHardwareExceptions', 'QueryMemoryLimitExceeded') AND value > 0, 'Major',
        event IN ('DelayedInserts', 'FailedQuery', 'FailedInsertQuery', 'DistributedConnectionFailTry', 'ZooKeeperUserExceptions') AND value > 100, 'Moderate',
        'OK') AS severity
FROM clusterAllReplicas('{cluster}', system.events)
WHERE event IN ('FailedQuery', 'FailedSelectQuery', 'FailedInsertQuery', 'RejectedInserts', 'DelayedInserts',
                'ReplicatedPartFailedFetches', 'DistributedConnectionFailTry', 'DistributedConnectionFailAtAll',
                'ZooKeeperHardwareExceptions', 'ZooKeeperUserExceptions', 'QueryMemoryLimitExceeded', 'ReplicatedDataLoss')
  AND value > 0
ORDER BY severity, value DESC, host;

-- @check metrics-07 Memory over the last 6 hours (15-minute buckets)
-- @requires table:system.asynchronous_metric_log
SELECT
    hostName() AS host,
    toStartOfFifteenMinutes(event_time) AS ts,
    formatReadableSize(avg(value)) AS avg_resident,
    formatReadableSize(max(value)) AS max_resident
FROM clusterAllReplicas('{cluster}', system.asynchronous_metric_log)
WHERE metric = 'MemoryResident'
  AND event_time > now() - INTERVAL 6 HOUR
GROUP BY host, ts
ORDER BY host, ts
LIMIT 200;

-- @check metrics-08 Load average over the last 6 hours (15-minute buckets)
-- @requires table:system.asynchronous_metric_log
SELECT
    hostName() AS host,
    toStartOfFifteenMinutes(event_time) AS ts,
    round(avgIf(value, metric = 'LoadAverage1'), 2) AS load_1m,
    round(avgIf(value, metric = 'LoadAverage15'), 2) AS load_15m
FROM clusterAllReplicas('{cluster}', system.asynchronous_metric_log)
WHERE metric IN ('LoadAverage1', 'LoadAverage15')
  AND event_time > now() - INTERVAL 6 HOUR
GROUP BY host, ts
ORDER BY host, ts
LIMIT 200;

-- @check metrics-09 Query rate over the last hour (5-minute buckets)
-- @requires table:system.metric_log
SELECT
    hostName() AS host,
    toStartOfFiveMinutes(event_time) AS ts,
    sum(ProfileEvent_Query) AS queries,
    sum(ProfileEvent_SelectQuery) AS selects,
    sum(ProfileEvent_InsertQuery) AS inserts,
    sum(ProfileEvent_FailedQuery) AS failed
FROM clusterAllReplicas('{cluster}', system.metric_log)
WHERE event_time > now() - INTERVAL 1 HOUR
GROUP BY host, ts
ORDER BY host, ts
LIMIT 200;

-- @check metrics-10 Block device queue depth (per-device metric names, before 26.8)
-- @requires version<26.8
SELECT
    hostName() AS host,
    metric AS device_metric,
    value AS in_flight_ops,
    multiIf(value > 245, 'Critical', value > 200, 'Major', value > 128, 'Moderate', 'OK') AS severity
FROM clusterAllReplicas('{cluster}', system.asynchronous_metrics)
WHERE metric LIKE 'BlockInFlightOps%'
  AND value > 0
ORDER BY value DESC, host;

-- @check metrics-10 Block device queue depth (key_values map, 26.8+)
-- @requires version>=26.8
SELECT
    hostName() AS host,
    concat(metric, '_', device) AS device_metric,
    in_flight_ops,
    multiIf(in_flight_ops > 245, 'Critical', in_flight_ops > 200, 'Major', in_flight_ops > 128, 'Moderate', 'OK') AS severity
FROM clusterAllReplicas('{cluster}', system.asynchronous_metrics)
ARRAY JOIN mapKeys(key_values) AS device, mapValues(key_values) AS in_flight_ops
WHERE metric = 'BlockInFlightOps'
  AND in_flight_ops > 0
ORDER BY in_flight_ops DESC, host;

-- @check metrics-11 Uptime and version per host
SELECT
    hostName() AS host,
    formatReadableTimeDelta(uptime()) AS uptime,
    version() AS version,
    if(uptime() < 3600, 'Moderate', 'OK') AS severity,
    if(uptime() < 3600, 'Server restarted less than an hour ago: check crash_log / text_log', '') AS note
FROM clusterAllReplicas('{cluster}', system.one)
ORDER BY host;

-- @check metrics-12 Prometheus endpoint configuration
SELECT
    hostName() AS host,
    name,
    value
FROM clusterAllReplicas('{cluster}', system.server_settings)
WHERE name LIKE 'prometheus%'
ORDER BY host, name;
