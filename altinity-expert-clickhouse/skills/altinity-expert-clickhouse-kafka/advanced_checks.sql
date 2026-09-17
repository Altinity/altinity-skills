-- =============================================================================
-- Kafka Consumer Exception Drill-Down (Targeted)
-- Use only for problematic Kafka tables to avoid noisy output.
-- Replace {cluster}, {db}, {kafka_table} with actual values.
-- =============================================================================
-- @check kafka-advanced-checks-01 Kafka Consumer Exception Drill-Down (Targeted)
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
--
-- The three steps share a TEMPORARY table, so they must run in ONE client
-- session (clickhouse-client --multiquery with all three statements, or an
-- interactive session). They cannot run over MCP or as separate --query calls.
-- Set --max_execution_time above the sleep length (default sleep: 30 s).
-- =============================================================================

-- Step 1: Take a snapshot
-- @skip-matrix multi-step session recipe (temporary table)
CREATE TEMPORARY TABLE kafka_consumers_dump AS
SELECT now64(3) AS ts, * FROM system.kafka_consumers;

-- Step 2: Wait (adjust sleep duration as needed)
-- @skip-matrix multi-step session recipe (sleep)
SELECT sleepEachRow(1) FROM numbers(30) SETTINGS max_block_size=1, max_threads=1, max_execution_time=120 FORMAT Null;

-- Step 3: Calculate consumption rate
-- @skip-matrix multi-step session recipe (temporary table)
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
-- @check kafka-advanced-checks-05 Total consumer lag per table (rdkafka_stat)
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
-- (single ARRAY JOIN over a pre-flattened array: chained ARRAY JOINs over map
--  keys/values fail on ClickHouse 25.8+ with "Not found column __array_join_exp")
-- @check kafka-advanced-checks-06 Detailed Lag per Partition
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
    tupleElement(parsed_json, 'topics') AS topics_map,
    arrayFlatten(arrayMap(
        t -> arrayMap(
            p -> (t, p, tupleElement(topics_map[t], 'partitions')[p]),
            mapKeys(tupleElement(topics_map[t], 'partitions'))
        ),
        mapKeys(topics_map)
    )) AS topic_partitions
SELECT
    hostName() AS host,
    database,
    table,
    tp.1 AS topic,
    tp.2 AS partition,
    tupleElement(tp.3, 'consumer_lag') AS consumer_lag,
    tupleElement(tp.3, 'committed_offset') AS committed_offset,
    tupleElement(tp.3, 'hi_offset') AS hi_offset
FROM clusterAllReplicas('{cluster}', system.kafka_consumers)
ARRAY JOIN topic_partitions AS tp
WHERE consumer_lag <> -1
ORDER BY consumer_lag DESC
;

-- Broker Connection Health
-- librdkafka counters: tx/rx are request/response COUNTS, txbytes/rxbytes are
-- BYTES. Use the byte counters to attribute per-broker (and cross-AZ) traffic.
-- @check kafka-advanced-checks-07 Broker Connection Health
WITH JSONExtract(
    rdkafka_stat,
    'Tuple(
        brokers Map(String, Tuple(
            state String,
            stateage Int64,
            tx Int64,
            txbytes Int64,
            txerrs Int64,
            rx Int64,
            rxbytes Int64,
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
    tupleElement(broker_data, 'rxbytes') AS received_bytes,
    tupleElement(broker_data, 'txbytes') AS transmitted_bytes,
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
