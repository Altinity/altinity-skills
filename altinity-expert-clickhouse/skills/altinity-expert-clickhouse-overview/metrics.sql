-- Alert-style checks over system.metrics / system.asynchronous_metrics (single host).
-- Every statement returns rows ONLY when something needs attention; an empty
-- result means OK for that check. Columns: id, object, severity, details, values.
--
-- Statements with `@requires version...` headers are alternatives for the same
-- check: run the one matching the server version and skip the other.

-- @check A3.0.3 Read-only replicas
WITH value AS v
SELECT
    'A3.0.3' AS id,
    'System' AS object,
    'Critical' AS severity,
    'Some replicas are read-only' AS details,
    map('readonly_replicas', v) AS values
FROM system.metrics
WHERE metric = 'ReadonlyReplica' AND v > 0;

-- @check A3.0.4 Block device in-flight IO ops (per-device metric names, before 26.8)
-- @requires version<26.8
WITH value AS v
SELECT
    'A3.0.4' AS id,
    metric AS object,
    multiIf(v > 245, 'Major', v > 200, 'Moderate', 'Minor') AS severity,
    'Block in-flight ops is high' AS details,
    map('in_flight_ops', v) AS values
FROM system.asynchronous_metrics
WHERE metric LIKE 'BlockInFlightOps%' AND v > 128;

-- @check A3.0.4 Block device in-flight IO ops (key_values map, 26.8+)
-- @requires version>=26.8
SELECT
    'A3.0.4' AS id,
    concat(metric, '_', device) AS object,
    multiIf(v > 245, 'Major', v > 200, 'Moderate', 'Minor') AS severity,
    'Block in-flight ops is high' AS details,
    map('in_flight_ops', v) AS values
FROM system.asynchronous_metrics
ARRAY JOIN mapKeys(key_values) AS device, mapValues(key_values) AS v
WHERE metric = 'BlockInFlightOps' AND v > 128;

-- @check A3.0.5 Load average vs CPU count (per-core metric names, before 26.8)
-- @requires version<26.8
WITH
    coalesce(
        nullIf(toUInt32(floor((SELECT value FROM system.asynchronous_metrics WHERE metric = 'CGroupMaxCPU'))), 0),
        nullIf((SELECT toUInt32(count()) FROM system.asynchronous_metrics WHERE metric LIKE 'OSIdleTimeCPU%' AND match(metric, '\\d$')), 0),
        1
    ) AS cpu_count,
    value AS v
SELECT
    'A3.0.5' AS id,
    metric AS object,
    multiIf(v > 10 * cpu_count, 'Critical', v > 2 * cpu_count, 'Major', v > cpu_count, 'Moderate', 'Minor') AS severity,
    format('Load average is high ({} {}, {} cores)', metric, toString(v), toString(cpu_count)) AS details,
    map('load', toString(v), 'cpu_count', toString(cpu_count)) AS values
FROM system.asynchronous_metrics
WHERE metric = 'LoadAverage15'
  AND severity != 'Minor';

-- @check A3.0.5 Load average vs CPU count (key_values map, 26.8+)
-- @requires version>=26.8
WITH
    coalesce(
        nullIf(toUInt32(floor((SELECT value FROM system.asynchronous_metrics WHERE metric = 'CGroupMaxCPU'))), 0),
        nullIf((SELECT toUInt32(length(key_values)) FROM system.asynchronous_metrics WHERE metric = 'OSIdleTimeCPU'), 0),
        1
    ) AS cpu_count,
    value AS v
SELECT
    'A3.0.5' AS id,
    metric AS object,
    multiIf(v > 10 * cpu_count, 'Critical', v > 2 * cpu_count, 'Major', v > cpu_count, 'Moderate', 'Minor') AS severity,
    format('Load average is high ({} {}, {} cores)', metric, toString(v), toString(cpu_count)) AS details,
    map('load', toString(v), 'cpu_count', toString(cpu_count)) AS values
FROM system.asynchronous_metrics
WHERE metric = 'LoadAverage15'
  AND severity != 'Minor';

-- @check A3.0.6 Replica delay
WITH value AS v
SELECT
    'A3.0.6' AS id,
    metric AS object,
    multiIf(v > 24 * 3600, 'Critical', v > 3 * 3600, 'Major', v > 1800, 'Moderate', 'Minor') AS severity,
    format('Replica delay is too big ({}, {})', metric, formatReadableTimeDelta(v)) AS details,
    map('delay_seconds', v) AS values
FROM system.asynchronous_metrics
WHERE metric IN ('ReplicasMaxAbsoluteDelay', 'ReplicasMaxRelativeDelay') AND v > 300;

-- @check A3.0.7 Max inserts in a replication queue
WITH value AS v
SELECT
    'A3.0.7' AS id,
    metric AS object,
    'Minor' AS severity,
    format('Too many inserts in a replication queue ({}, {})', metric, toString(v)) AS details,
    map('max_inserts_in_queue', v) AS values
FROM system.asynchronous_metrics
WHERE metric = 'ReplicasMaxInsertsInQueue' AND v > 100;

-- @check A3.0.8 Sum of inserts across replication queues
WITH value AS v
SELECT
    'A3.0.8' AS id,
    metric AS object,
    'Minor' AS severity,
    format('Too many inserts across replication queues ({}, {})', metric, toString(v)) AS details,
    map('sum_inserts_in_queue', v) AS values
FROM system.asynchronous_metrics
WHERE metric = 'ReplicasSumInsertsInQueue' AND v > 300;

-- @check A3.0.9 Max merges in a replication queue
-- see also merge_tree_settings max_replicated_merges_in_queue, max_replicated_mutations_in_queue
WITH value AS v
SELECT
    'A3.0.9' AS id,
    metric AS object,
    'Minor' AS severity,
    format('Too many merges in a replication queue ({}, {})', metric, toString(v)) AS details,
    map('max_merges_in_queue', v) AS values
FROM system.asynchronous_metrics
WHERE metric = 'ReplicasMaxMergesInQueue' AND v > 80;

-- @check A3.0.10 Sum of merges across replication queues
WITH value AS v
SELECT
    'A3.0.10' AS id,
    metric AS object,
    'Minor' AS severity,
    format('Too many merges across replication queues ({}, {})', metric, toString(v)) AS details,
    map('sum_merges_in_queue', v) AS values
FROM system.asynchronous_metrics
WHERE metric = 'ReplicasSumMergesInQueue' AND v > 200;

-- @check A3.0.11 Max replication queue size
WITH value AS v
SELECT
    'A3.0.11' AS id,
    metric AS object,
    multiIf(v > 1000, 'Major', v > 500, 'Moderate', 'Minor') AS severity,
    format('Replication queue is long ({}, {} tasks)', metric, toString(v)) AS details,
    map('max_queue_size', v) AS values
FROM system.asynchronous_metrics
WHERE metric = 'ReplicasMaxQueueSize' AND v > 200;

-- @check A3.0.12 Sum of replication queue sizes
WITH value AS v
SELECT
    'A3.0.12' AS id,
    metric AS object,
    multiIf(v > 5000, 'Major', v > 2000, 'Moderate', 'Minor') AS severity,
    format('Replication queues are long in total ({}, {} tasks)', metric, toString(v)) AS details,
    map('sum_queue_size', v) AS values
FROM system.asynchronous_metrics
WHERE metric = 'ReplicasSumQueueSize' AND v > 500;

-- @check A3.0.14 Parts per partition vs parts_to_delay_insert / parts_to_throw_insert
WITH
    (SELECT toUInt32(value) FROM system.merge_tree_settings WHERE name = 'parts_to_delay_insert') AS parts_to_delay_insert,
    (SELECT toUInt32(value) FROM system.merge_tree_settings WHERE name = 'parts_to_throw_insert') AS parts_to_throw_insert,
    value AS v
SELECT
    'A3.0.14' AS id,
    metric AS object,
    multiIf(v > parts_to_throw_insert, 'Critical', v > parts_to_delay_insert, 'Major', 'Moderate') AS severity,
    format('Too many parts in a partition ({} = {}, delay at {}, throw at {})', metric, toString(v), toString(parts_to_delay_insert), toString(parts_to_throw_insert)) AS details,
    map('max_parts_in_partition', v, 'parts_to_delay_insert', toFloat64(parts_to_delay_insert), 'parts_to_throw_insert', toFloat64(parts_to_throw_insert)) AS values
FROM system.asynchronous_metrics
WHERE metric = 'MaxPartCountForPartition' AND v > parts_to_delay_insert * 0.9;

-- @check A3.0.15 Resident memory vs total RAM
WITH
    (SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') AS total,
    value AS memory_resident
SELECT
    'A3.0.15' AS id,
    'Memory' AS object,
    multiIf(memory_resident > total * 0.9, 'Critical', memory_resident > total * 0.8, 'Major', 'Minor') AS severity,
    format('Memory usage is high ({} of {})', formatReadableSize(memory_resident), formatReadableSize(total)) AS details,
    map('memory_resident', memory_resident, 'memory_total', total) AS values
FROM system.asynchronous_metrics
WHERE metric = 'MemoryResident' AND memory_resident > total * 0.8;
