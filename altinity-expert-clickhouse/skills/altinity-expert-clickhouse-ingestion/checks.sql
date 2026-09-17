-- Kafka Health
-- @check ingestion-01 Kafka Health
select
    database,
    table,
    sum(is_currently_used) as active_consumers,
    count() as total_consumers,
    max(dateDiff('second', last_poll_time, now())) as max_poll_age_s,
    max(dateDiff('second', last_commit_time, now())) as max_commit_age_s,
    sum(length(exceptions.text)) as total_exceptions,
    max(length(exceptions.text)) as max_exceptions
from clusterAllReplicas('{cluster}', system.kafka_consumers)
group by database, table
order by total_exceptions desc, max_poll_age_s desc
limit 50
;

-- Kafka scheduling capacity
-- @check ingestion-02 Kafka scheduling capacity
select
    hostName() as host,
    sumIf(value, metric = 'KafkaConsumers') as kafka_consumers,
    sumIf(value, metric = 'BackgroundMessageBrokerSchedulePoolSize') as mb_pool_size
from clusterAllReplicas('{cluster}', system.metrics)
where metric in ('KafkaConsumers','BackgroundMessageBrokerSchedulePoolSize')
group by host
order by host
;

-- Current Insert Activity
-- @check ingestion-03 Current Insert Activity
select
    hostName() as host,
    query_id,
    user,
    elapsed,
    formatReadableSize(written_bytes) as written,
    written_rows,
    formatReadableSize(memory_usage) as memory,
    substring(query, 1, 80) as query_preview
from clusterAllReplicas('{cluster}', system.processes)
where query_kind = 'Insert'
order by elapsed desc, host asc
limit 20
;

-- Recent Insert Performance (Last Hour)
-- @check ingestion-04 Recent Insert Performance (Last Hour)
select
    hostName() as host,
    toStartOfFiveMinutes(event_time) as ts,
    count() as insert_count,
    round(avg(query_duration_ms)) as avg_ms,
    round(quantile(0.95)(query_duration_ms)) as p95_ms,
    sum(written_rows) as total_rows,
    formatReadableSize(sum(written_bytes)) as total_bytes
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and query_kind = 'Insert'
  and event_time > now() - interval 1 hour
group by host, ts
order by ts desc, host asc
limit 20
;

-- Part Creation Rate by Table
-- Red flags:
-- parts_created > 60 per minute (> 1/sec) → Batching too small
-- avg_rows_per_part < 10000 → Micro-batches, will cause merge pressure
-- @check ingestion-05 Part Creation Rate by Table
-- @requires table:system.part_log
select
    hostName() as host,
    database,
    table,
    toStartOfMinute(event_time) as minute,
    count() as parts_created,
    round(avg(rows)) as avg_rows_per_part,
    formatReadableSize(avg(size_in_bytes)) as avg_part_size
from clusterAllReplicas('{cluster}', system.part_log)
where event_type = 'NewPart'
  and event_time > now() - interval 1 hour
group by host, database, table, minute
order by parts_created desc, host asc
limit 30
;

-- Insert vs Merge Balance
-- If net_reduction negative → Load altinity-expert-clickhouse-merges for merge backlog analysis
-- @check ingestion-06 Insert vs Merge Balance
-- @requires table:system.part_log
select
    hostName() as host,
    database,
    table,
    countIf(event_type = 'NewPart') as new_parts,
    countIf(event_type = 'MergeParts') as merges,
    countIf(event_type = 'MergeParts') - countIf(event_type = 'NewPart') as net_reduction
from clusterAllReplicas('{cluster}', system.part_log)
where event_time > now() - interval 1 hour
group by host, database, table
having new_parts > 10
order by new_parts desc, host asc
limit 20
;

-- Slow Inserts Investigation
-- Find slowest inserts
-- @check ingestion-07 Slow Inserts Investigation
select
    hostName() as host,
    event_time,
    query_id,
    user,
    query_duration_ms,
    written_rows,
    formatReadableSize(written_bytes) as written,
    formatReadableSize(memory_usage) as peak_memory,
    arrayStringConcat(tables, ', ') as tables,
    substring(query, 1, 100) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and query_kind = 'Insert'
  and event_date = today()
order by query_duration_ms desc, host asc
limit 20
;

-- Insert with MV Overhead
-- Find slow MVs during inserts
-- When inserts feed materialized views, slow MVs cause insert delays.
-- @check ingestion-08 Insert with MV Overhead
-- @requires table:system.query_views_log
select
    hostName() as host,
    toStartOfFiveMinutes(qvl.event_time) as ts,
    qvl.view_name,
    count() as trigger_count,
    round(avg(qvl.view_duration_ms)) as avg_mv_ms,
    round(max(qvl.view_duration_ms)) as max_mv_ms,
    sum(qvl.written_rows) as rows_written_by_mv
from clusterAllReplicas('{cluster}', system.query_views_log) qvl
where qvl.event_time > now() - interval 1 hour
group by host, ts, qvl.view_name
order by avg_mv_ms desc, host asc
limit 20
;

-- Failed Inserts
-- Common exception codes:
-- 241 (MEMORY_LIMIT_EXCEEDED) → Load altinity-expert-clickhouse-memory
-- 252 (TOO_MANY_PARTS) → Load altinity-expert-clickhouse-merges
-- 319 (UNKNOWN_PACKET_FROM_CLIENT) → Client/network issue
-- @check ingestion-09 Failed Inserts
select
    hostName() as host,
    event_time,
    user,
    exception_code,
    exception,
    substring(query, 1, 150) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  and query_kind = 'Insert'
  and event_date = today()
order by event_time desc, host asc
limit 30
;

-- Batch Size Analysis
-- @check ingestion-10 Batch Size Analysis
select
    hostName() as host,
    arrayStringConcat(tables, ', ') as target_tables,
    count() as insert_count,
    round(avg(written_rows)) as avg_batch_rows,
    multiIf(avg_batch_rows > '100000', 'Good batching',
            avg_batch_rows > '10000', 'Mostly OK',
            avg_batch_rows > '1000', 'Could improve',
         'Seriously under-batched'
    ) as batch_status,
    min(written_rows) as min_batch,
    max(written_rows) as max_batch,
    round(quantile(0.5)(written_rows)) as median_batch
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and query_kind = 'Insert'
  and event_time > now() - interval 24 hour
  and written_rows > 0
  and length(tables) > 0
group by host, tables
having insert_count > 10
order by avg_batch_rows asc, host asc
limit 20
;

-- Kafka Engine Ingestion
-- Check Kafka consumer lag (if using Kafka engine)
-- @check ingestion-11 Kafka Engine Ingestion
select
    hostName() as host,
    database,
    name,
    engine,
    total_rows,
    total_bytes
from clusterAllReplicas('{cluster}', system.tables)
where engine like '%Kafka%'
;

-- Kafka-related messages in logs
-- @check ingestion-12 Kafka-related messages in logs
-- @requires table:system.text_log
select
    hostName() as host,
    event_time,
    level,
    message
from clusterAllReplicas('{cluster}', system.text_log)
where logger_name like '%Kafka%'
  and event_time > now() - interval 1 hour
order by event_time desc, host asc
limit 50
;

-- Optional Context: Buffer Table Flush Patterns
-- Buffer table status
-- @check ingestion-13 Optional Context: Buffer Table Flush Patterns
select
    hostName() as host,
    database,
    name,
    total_rows,
    total_bytes
from clusterAllReplicas('{cluster}', system.tables)
where engine = 'Buffer'
;

-- Optional Context: Check current settings for insert
-- @check ingestion-14 Optional Context: Check current settings for insert
select
    hostName() as host,
    name, value, changed
from clusterAllReplicas('{cluster}', system.settings)
where name like '%insert%'
order by name, host asc
;
