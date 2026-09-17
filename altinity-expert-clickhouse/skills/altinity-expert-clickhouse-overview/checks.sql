-- Object Counts Audit
-- @check overview-01 Object Counts Audit
select * from (
select
    'Replicated Tables' as check_name,
    (select count() from system.tables where engine like 'Replicated%') as value,
    multiIf(value > 2000, 'Critical', value > 900, 'Major', value > 200, 'Moderate', 'OK') as severity,
    'Recommend: <200, tune background_schedule_pool_size if higher' as note

union all

select
    'MergeTree Tables' as check_name,
    (select count() from system.tables where engine like '%MergeTree%') as value,
    multiIf(value > 10000, 'Critical', value > 3000, 'Major', value > 1000, 'Moderate', 'OK') as severity,
    'High count increases metadata overhead' as note

union all

select
    'Databases' as check_name,
    (select count() from system.databases) as value,
    multiIf(value > 1000, 'Critical', value > 300, 'Major', value > 100, 'Moderate', 'OK') as severity,
    'Consider consolidating if >100' as note

union all

select
    'Active Parts' as check_name,
    (select count() from system.parts where active) as value,
    multiIf(value > 120000, 'Critical', value > 90000, 'Major', value > 60000, 'Moderate', 'OK') as severity,
    'High count slows restarts and metadata ops' as note

union all

select
    'Current Queries' as check_name,
    (select count() from system.processes where is_cancelled = 0) as value,
    multiIf(value > 100, 'Major', value > 50, 'Moderate', 'OK') as severity,
    'Check max_concurrent_queries setting' as note

union all

SELECT
    'Kafka Consumers' AS check_name,
    toUInt64(consumers) AS value,
    multiIf(consumers > pool_size, 'Major',
            consumers > 20,        'Moderate',
            'OK')                  AS severity,
    concat('consumers=', toString(consumers), ' pool_size=', toString(pool_size)) AS note
FROM
(
    SELECT
        sumIf(value, metric = 'KafkaConsumers') AS consumers,
        sumIf(value, metric = 'BackgroundMessageBrokerSchedulePoolSize') AS pool_size
    FROM system.metrics
)
)
where value != 0
;
-- Resource Utilization
-- @check overview-02 Resource Utilization
SELECT
    'Memory Usage' AS resource,
    formatReadableSize(used_ram) AS used,
    formatReadableSize(total_ram) AS total,
    round(100.0 * used_ram / total_ram, 1) AS pct,
    multiIf(pct > 90, 'Critical', pct > 80, 'Major', pct > 70, 'Moderate', 'OK') AS severity
FROM
(
    SELECT
        toFloat64((SELECT value FROM system.asynchronous_metrics WHERE metric = 'MemoryResident')) AS used_ram,
        toFloat64((SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal')) AS total_ram
)
HAVING severity != 'OK'
;
-- @check overview-03 Primary key memory vs total RAM
SELECT
    'Primary Keys in RAM' AS resource,
    formatReadableSize(pk_memory) AS used,
    formatReadableSize(total_ram) AS total,
    round(100.0 * pk_memory / total_ram, 1) AS pct,
    multiIf(pct > 30, 'Critical', pct > 25, 'Major', pct > 20, 'Moderate', 'OK') AS severity
FROM
(
    SELECT
        toFloat64((SELECT sum(primary_key_bytes_in_memory) FROM system.parts)) AS pk_memory,
        toFloat64((SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal')) AS total_ram
)
HAVING severity != 'OK'
;
-- @check overview-04 Dictionaries and in-memory tables vs total RAM
SELECT
    'Dictionaries + MemTables' AS resource,
    formatReadableSize(used_bytes) AS used,
    formatReadableSize(total_ram) AS total,
    round(100.0 * used_bytes / total_ram, 1) AS pct,
    multiIf(pct > 30, 'Critical', pct > 25, 'Major', pct > 20, 'Moderate', 'OK') AS severity
FROM
(
    SELECT
        toFloat64((SELECT sum(bytes_allocated) FROM system.dictionaries))
            + toFloat64((SELECT assumeNotNull(sum(total_bytes)) FROM system.tables WHERE engine IN ('Memory', 'Set', 'Join'))) AS used_bytes,
        toFloat64((SELECT value FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal')) AS total_ram
)
HAVING severity != 'OK'
;
-- Disk Health
-- @check overview-05 Disk Health
select
    name as disk,
    path,
    formatReadableSize(total_space) as total,
    formatReadableSize(free_space) as free,
    round(100.0 * (total_space - free_space) / total_space, 1) as used_pct,
    multiIf(used_pct > 90, 'Critical', used_pct > 85, 'Major', used_pct > 80, 'Moderate', 'OK') as severity
from system.disks
where lower(type) = 'local'
order by used_pct desc
;
-- Replication Health
-- @check overview-06 Replication Health
select * from (
select
    'Readonly Replicas' as check_name,
    toFloat64((select value from system.metrics where metric = 'ReadonlyReplica')) as value,
    if(value > 0, 'Critical', 'OK') as severity

union all

select
    'Max Replica Delay' as check_name,
    toFloat64((select max(value) from system.asynchronous_metrics where metric in ('ReplicasMaxAbsoluteDelay', 'ReplicasMaxRelativeDelay'))) as value,
    multiIf(value > 86400, 'Critical', value > 10800, 'Major', value > 1800, 'Moderate', 'OK') as severity

union all

select
    'Replication Queue Size' as check_name,
    toFloat64((select value from system.asynchronous_metrics where metric = 'ReplicasSumQueueSize')) as value,
    multiIf(value > 500, 'Major', value > 200, 'Moderate', 'OK') as severity
) where value !=0;

-- System Log Health
-- @check overview-07 System Log Health
select
    format('system.{}', name) as log_table,
    engine_full like '% TTL %' as has_ttl,
    if(not has_ttl, 'Major', 'OK') as severity,
    if(not has_ttl, 'System log should have TTL to prevent disk fill', 'TTL configured') as note
from system.tables
where database = 'system' and name like '%_log' and engine like '%MergeTree%'
order by has_ttl, name
;
-- Log disk usage
-- @check overview-08 Log disk usage
select
    table,
    formatReadableSize(sum(bytes_on_disk)) as size,
    count() as parts
from system.parts
where database = 'system' and table like '%_log' and active
group by table
order by sum(bytes_on_disk) desc
;
-- Recent Errors Summary
-- @check overview-09 Recent Errors Summary
select
    toStartOfHour(event_time) as hour,
    countIf(type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')) as failed_queries,
    countIf(type != 'QueryStart') as total_queries,
    round(100.0 * failed_queries / nullIf(total_queries, 0), 2) as error_rate_pct,
    multiIf(error_rate_pct > 20, 'Major', error_rate_pct > 5, 'Moderate', 'OK') as severity
from system.query_log
where event_time >= now() - interval 24 hour
  and type != 'QueryStart'
group by hour
order by hour desc
limit 24
;
-- Part log errors by event type
-- @requires table:system.part_log
-- @check overview-10 Part log errors by event type
SELECT
    event_type,
    countIf(error != 0) AS errors,
    count() AS total,
    substr(anyIf(exception, error != 0), 1, 100) AS sample_exception,
    multiIf(errors > 100, 'Major', errors > 0, 'Moderate', 'OK') AS severity
FROM system.part_log
WHERE event_time >= now() - INTERVAL 24 HOUR
GROUP BY event_type
ORDER BY errors DESC
;
-- system.errors
-- @check overview-11 system.errors
select
    code,
    name,
    value as count,
    last_error_time,
    substring(last_error_message, 1, 160) as last_error_message
from system.errors
where last_error_time >= now() - interval 24 hour
  and name not in ('NO_REPLICA_HAS_PART','ACCESS_DENIED','UNKNOWN_IDENTIFIER','UNKNOWN_TABLE')
  and count > 500
order by last_error_time desc
limit 20
;
-- Detached parts by table and reason
-- @check overview-12 Detached parts by table and reason
select
    hostName() as host,
    database,
    table,
    reason,
    count() as detached_parts,
    formatReadableSize(sum(bytes_on_disk)) as bytes,
    min(modification_time) as first_detach,
    max(modification_time) as last_detach,
    multiIf(detached_parts > 100, 'Major', detached_parts > 0, 'Moderate', 'OK') as severity
from system.detached_parts
group by host, database, table, reason
order by detached_parts desc
limit 100
;
-- Warnings and errors in text_log (last 24h)
-- @check overview-13 Warnings and errors in text_log (last 24h)
-- @requires table:system.text_log
select
    level,
    logger_name,
    message_format_string,
    count() as count,
    max(event_time) as last_seen
from system.text_log
where event_time > now() - interval 24 hour
  and level <= 'Warning'
group by level, logger_name, message_format_string
order by level, count desc
limit 50
;
-- Background pool utilization
-- @check overview-14 Background pool utilization
WITH
    ['MergesAndMutations', 'Fetches', 'Move', 'Common', 'Schedule', 'BufferFlushSchedule', 'MessageBrokerSchedule', 'DistributedSchedule'] AS pool_tokens,
    ['pool', 'fetches_pool', 'move_pool', 'common_pool', 'schedule_pool', 'buffer_flush_schedule_pool', 'message_broker_schedule_pool', 'distributed_schedule_pool'] AS setting_tokens
SELECT
    extract(m.metric, '^Background(.*)Task') AS pool_name,
    m.active_tasks,
    s.pool_size,
    round(100.0 * m.active_tasks / nullIf(s.pool_size, 0), 1) AS utilization_pct,
    multiIf(utilization_pct > 99, 'Major', utilization_pct > 90, 'Moderate', 'OK') AS severity
FROM
(
    SELECT
        metric,
        value AS active_tasks,
        concat('background_', lower(transform(extract(metric, '^Background(.*)PoolTask'), pool_tokens, setting_tokens, '')), '_size') AS setting_name
    FROM system.metrics
    WHERE metric LIKE 'Background%PoolTask'
) AS m
INNER JOIN
(
    SELECT name, toFloat64OrZero(value) AS pool_size
    FROM system.server_settings
    WHERE name LIKE 'background%pool_size'
) AS s ON s.name = m.setting_name
WHERE s.pool_size > 0
ORDER BY utilization_pct DESC
;
