-- =============================================================================
-- Kafka Consumer Exception Drill-Down (Targeted)
-- Use only for problematic Kafka tables to avoid noisy output.
-- Replace {cluster}, {db}, {kafka_table} with actual values.
-- =============================================================================
SELECT
    hostName() AS host,
    database,
    table,
    consumer_id,
    is_currently_used,
    dateDiff('second', last_poll_time, now()) AS last_poll_age_s,
    dateDiff('second', last_commit_time, now()) AS last_commit_age_s,
    num_messages_read,
    num_commits,
    length(assignments.topic) AS assigned_partitions,
    length(exceptions.text) AS exception_count,
    exceptions.text[-1] AS last_exception
FROM clusterAllReplicas('{cluster}', system.kafka_consumers)
WHERE database = '{db}'
  AND table = '{kafka_table}'
ORDER BY is_currently_used DESC, last_poll_age_s DESC
LIMIT 50
;

-- =============================================================================
-- Consumption Speed (Snapshot-Based)
-- Measures real-time consumption rate by comparing two snapshots.
-- Step 1: Take snapshot. Step 2: Wait. Step 3: Calculate rate.
-- =============================================================================

-- Step 1: Take a snapshot
CREATE TEMPORARY TABLE kafka_consumers_dump AS
SELECT now64(3) AS ts, * FROM system.kafka_consumers;

-- Step 2: Wait (adjust sleep duration as needed)
SELECT sleepEachRow(1) FROM numbers(60) SETTINGS max_block_size=1, max_threads=1 FORMAT Null;

-- Step 3: Calculate consumption rate
SELECT
    database,
    table,
    dateDiff('ms', old.ts, now64(3)) / 1000 AS time_since_dump,
    new.num_messages_read - old.num_messages_read AS delta_num_messages_read,
    delta_num_messages_read / time_since_dump AS per_sec
FROM system.kafka_consumers AS new
LEFT JOIN kafka_consumers_dump AS old USING (database, table, consumer_id)
ORDER BY per_sec
;

-- =============================================================================
-- rdkafka_stat Queries
-- PREREQUISITE: rdkafka_stat is NOT enabled by default in ClickHouse.
-- Add to Kafka engine config to enable:
--
--   <kafka>
--       <statistics_interval_ms>10000</statistics_interval_ms>
--   </kafka>
--
-- Once enabled, system.kafka_consumers will have an rdkafka_stat column
-- (String type) containing detailed JSON statistics from librdkafka.
-- =============================================================================

-- Total Consumer Lag per Table
WITH JSONExtract(
    rdkafka_stat,
    'Tuple(
        topics Map(String, Tuple(
            partitions Map(String, Tuple(
                partition Int64,
                consumer_lag Int64
            ))
        ))
    )'
) AS parsed_json,
    tupleElement(parsed_json, 'topics') AS topics_map,
    arrayMap(
        (topic) -> arrayMap(
            (partition) -> (
                topic,
                partition,
                tupleElement(tupleElement(topics_map[topic], 'partitions')[partition], 'consumer_lag')
            ),
            mapKeys(tupleElement(topics_map[topic], 'partitions'))
        ),
        mapKeys(topics_map)
    ) AS topics_details_tmp,
    arrayFlatten(topics_details_tmp) AS topics_details,
    arrayFilter(t -> t.3 <> -1, topics_details) AS lags,
    arraySum(arrayMap(t -> t.3, lags)) AS total_lag
SELECT
    hostName() AS host,
    database,
    table,
    total_lag
FROM clusterAllReplicas('{cluster}', system.kafka_consumers)
ORDER BY total_lag DESC
;

-- Detailed Lag per Partition
WITH JSONExtract(
    rdkafka_stat,
    'Tuple(
        topics Map(String, Tuple(
            partitions Map(String, Tuple(
                partition Int64,
                consumer_lag Int64,
                committed_offset Int64,
                hi_offset Int64,
                lo_offset Int64
            ))
        ))
    )'
) AS parsed_json,
    tupleElement(parsed_json, 'topics') AS topics_map
SELECT
    hostName() AS host,
    database,
    table,
    topic,
    partition,
    tupleElement(partition_data, 'consumer_lag') AS consumer_lag,
    tupleElement(partition_data, 'committed_offset') AS committed_offset,
    tupleElement(partition_data, 'hi_offset') AS hi_offset
FROM clusterAllReplicas('{cluster}', system.kafka_consumers)
ARRAY JOIN
    mapKeys(topics_map) AS topic,
    mapValues(topics_map) AS topic_data
ARRAY JOIN
    mapKeys(tupleElement(topic_data, 'partitions')) AS partition,
    mapValues(tupleElement(topic_data, 'partitions')) AS partition_data
WHERE tupleElement(partition_data, 'consumer_lag') <> -1
ORDER BY consumer_lag DESC
;

-- Broker Connection Health
WITH JSONExtract(
    rdkafka_stat,
    'Tuple(
        brokers Map(String, Tuple(
            state String,
            stateage Int64,
            tx Int64,
            rx Int64,
            txerrs Int64,
            rxerrs Int64,
            connects Int64,
            disconnects Int64
        ))
    )'
) AS parsed_json,
    tupleElement(parsed_json, 'brokers') AS brokers_map
SELECT
    hostName() AS host,
    database,
    table,
    broker,
    tupleElement(broker_data, 'state') AS state,
    tupleElement(broker_data, 'rx') AS received_bytes,
    tupleElement(broker_data, 'tx') AS transmitted_bytes,
    tupleElement(broker_data, 'txerrs') AS tx_errors,
    tupleElement(broker_data, 'rxerrs') AS rx_errors,
    tupleElement(broker_data, 'connects') AS connects,
    tupleElement(broker_data, 'disconnects') AS disconnects
FROM clusterAllReplicas('{cluster}', system.kafka_consumers)
ARRAY JOIN
    mapKeys(brokers_map) AS broker,
    mapValues(brokers_map) AS broker_data
ORDER BY tx_errors + rx_errors DESC
;
