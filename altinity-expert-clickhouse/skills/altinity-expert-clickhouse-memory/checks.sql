-- Current Memory Overview
-- @check memory-01 Current Memory Overview
select
    hostName() as host,
    formatReadableSize(total) as total_ram,
    formatReadableSize(resident) as clickhouse_resident,
    formatReadableSize(free_without_cached) as free,
    formatReadableSize(cached) as os_cached,
    formatReadableSize(buffers) as os_buffers,
    round(100.0 * resident / total, 1) as clickhouse_pct,
    multiIf(resident > total * 0.9, 'Critical', resident > total * 0.8, 'Major', 'OK') as severity
from
(
    select
        hostName() as host,
        toUInt64(maxIf(value, metric = 'OSMemoryTotal')) as total,
        toUInt64(maxIf(value, metric = 'MemoryResident')) as resident,
        toUInt64(maxIf(value, metric = 'OSMemoryFreeWithoutCached')) as free_without_cached,
        toUInt64(maxIf(value, metric = 'OSMemoryCached')) as cached,
        toUInt64(maxIf(value, metric = 'OSMemoryBuffers')) as buffers
    from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    where metric in ('OSMemoryTotal', 'MemoryResident', 'OSMemoryFreeWithoutCached', 'OSMemoryCached', 'OSMemoryBuffers')
    group by host
)
;

-- Memory Breakdown by Component
-- @check memory-02 Memory Breakdown by Component
select
    hostName() as host,
    'Dictionaries' as component,
    formatReadableSize(sum(bytes_allocated)) as size,
    toFloat64(sum(bytes_allocated)) as size_bytes,
    toUInt64(count()) as count
from clusterAllReplicas('{cluster}', system.dictionaries)
group by host

union all

select
    hostName() as host,
    'Memory Tables (Memory/Set/Join)' as component,
    formatReadableSize(assumeNotNull(sum(total_bytes))) as size,
    toFloat64(assumeNotNull(sum(total_bytes))) as size_bytes,
    toUInt64(count()) as count
from clusterAllReplicas('{cluster}', system.tables)
where engine in ('Memory', 'Set', 'Join')
group by host

union all

select
    hostName() as host,
    'Primary Keys' as component,
    formatReadableSize(sum(primary_key_bytes_in_memory)) as size,
    toFloat64(sum(primary_key_bytes_in_memory)) as size_bytes,
    toUInt64(sum(marks)) as count
from clusterAllReplicas('{cluster}', system.parts)
where active
group by host

union all

select
    hostName() as host,
    'In-Memory Parts' as component,
    formatReadableSize(sumIf(data_uncompressed_bytes, part_type = 'InMemory')) as size,
    toFloat64(sumIf(data_uncompressed_bytes, part_type = 'InMemory')) as size_bytes,
    toUInt64(countIf(part_type = 'InMemory')) as count
from clusterAllReplicas('{cluster}', system.parts)
where active
group by host

union all

select
    hostName() as host,
    'Active Merges' as component,
    formatReadableSize(sum(memory_usage)) as size,
    toFloat64(sum(memory_usage)) as size_bytes,
    toUInt64(count()) as count
from clusterAllReplicas('{cluster}', system.merges)
group by host

union all

select
    hostName() as host,
    'Running Queries' as component,
    formatReadableSize(sum(memory_usage)) as size,
    toFloat64(sum(memory_usage)) as size_bytes,
    toUInt64(count()) as count
from clusterAllReplicas('{cluster}', system.processes)
group by host

union all

select
    hostName() as host,
    'Mark Cache' as component,
    formatReadableSize(value) as size,
    toFloat64(value) as size_bytes,
    toUInt64(0) as count
from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
where metric = 'MarkCacheBytes'

union all

select
    hostName() as host,
    'Uncompressed Cache' as component,
    formatReadableSize(value) as size,
    toFloat64(value) as size_bytes,
    toUInt64(0) as count
from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
where metric = 'UncompressedCacheBytes'

order by size_bytes desc, host asc
;

-- Memory Allocation Audit
-- @check memory-03 Memory Allocation Audit
select
    d.host as host,
    'Dictionaries + Memory Tables' as check_name,
    formatReadableSize(dictionaries + mem_tables) as used,
    round(100.0 * (dictionaries + mem_tables) / total_ram, 1) as pct,
    multiIf(pct > 30, 'Critical', pct > 25, 'Major', pct > 20, 'Moderate', 'OK') as severity
from
(
    select
        hostName() as host,
        sum(bytes_allocated) as dictionaries
    from clusterAllReplicas('{cluster}', system.dictionaries)
    group by host
) d
left join
(
    select
        hostName() as host,
        assumeNotNull(sum(total_bytes)) as mem_tables
    from clusterAllReplicas('{cluster}', system.tables)
    where engine in ('Memory', 'Set', 'Join')
    group by host
) t on t.host = d.host
left join
(
    select
        hostName() as host,
        sum(primary_key_bytes_in_memory) as pk_memory
    from clusterAllReplicas('{cluster}', system.parts)
    where active
    group by host
) p on p.host = d.host
left join
(
    select
        hostName() as host,
        toUInt64(maxIf(value, metric = 'OSMemoryTotal')) as total_ram
    from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    where metric = 'OSMemoryTotal'
    group by host
) m on m.host = d.host

union all

select
    p.host as host,
    'Primary Keys' as check_name,
    formatReadableSize(pk_memory) as used,
    round(100.0 * pk_memory / total_ram, 1) as pct,
    multiIf(pct > 30, 'Critical', pct > 25, 'Major', pct > 20, 'Moderate', 'OK') as severity
from
(
    select
        hostName() as host,
        sum(primary_key_bytes_in_memory) as pk_memory
    from clusterAllReplicas('{cluster}', system.parts)
    where active
    group by host
) p
left join
(
    select
        hostName() as host,
        toUInt64(maxIf(value, metric = 'OSMemoryTotal')) as total_ram
    from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    where metric = 'OSMemoryTotal'
    group by host
) m on m.host = p.host
;

-- Top Memory-Using Queries
-- @check memory-04 Top Memory-Using Queries
select
    hostName() as host,
    initial_query_id,
    user,
    round(elapsed, 1) as elapsed_sec,
    formatReadableSize(memory_usage) as memory,
    formatReadableSize(peak_memory_usage) as peak_memory,
    substring(query, 1, 80) as query_preview
from clusterAllReplicas('{cluster}', system.processes)
order by peak_memory_usage desc, host asc
limit 15
;

-- Top Memory-Using Dictionaries
-- @check memory-05 Top Memory-Using Dictionaries
select
    hostName() as host,
    database,
    name,
    formatReadableSize(bytes_allocated) as memory,
    element_count as elements,
    source,
    loading_duration
from clusterAllReplicas('{cluster}', system.dictionaries)
order by bytes_allocated desc, host asc
limit 20
;

-- Top Memory-Using Tables (Memory Engine)
-- @check memory-06 Top Memory-Using Tables (Memory Engine)
select
    hostName() as host,
    database,
    name,
    engine,
    formatReadableSize(total_bytes) as size,
    total_rows as rows
from clusterAllReplicas('{cluster}', system.tables)
where engine in ('Memory', 'Set', 'Join')
order by total_bytes desc, host asc
limit 20
;

-- Top Primary Key Memory by Table
-- @check memory-07 Top Primary Key Memory by Table
select
    hostName() as host,
    database,
    table,
    formatReadableSize(sum(primary_key_bytes_in_memory)) as pk_memory,
    formatReadableSize(sum(primary_key_bytes_in_memory_allocated)) as pk_allocated,
    sum(marks) as marks
from clusterAllReplicas('{cluster}', system.parts)
where active
group by host, database, table
order by sum(primary_key_bytes_in_memory) desc, host asc
limit 20
;

-- Memory Usage Over Time
-- @check memory-08 Memory Usage Over Time
-- @requires table:system.asynchronous_metric_log
select
    hostName() as host,
    toStartOfFiveMinutes(event_time) as ts,
    formatReadableSize(max(value)) as peak_memory
from clusterAllReplicas('{cluster}', system.asynchronous_metric_log)
where metric = 'MemoryResident'
  and event_time > now() - interval 4 hour
group by host, ts
order by ts, host
;

-- Recent Memory-Heavy Queries
-- @check memory-09 Recent Memory-Heavy Queries
select
    hostName() as host,
    event_time,
    initial_query_id,
    user,
    formatReadableSize(memory_usage) as memory,
    round(query_duration_ms / 1000, 1) as duration_sec,
    substring(query, 1, 100) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where event_date >= today()
  and type = 'QueryFinish'
order by memory_usage desc, host asc
limit 20
;

-- Memory Exceptions
-- @check memory-10 Memory Exceptions
select
    hostName() as host,
    event_time,
    user,
    exception_code,
    substring(exception, 1, 200) as exception,
    substring(query, 1, 100) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  and exception_code = 241
  and event_date >= today() - 1
order by event_time desc, host asc
limit 30
;

-- Memory Timeline Reconstruction
-- Reconstructs memory usage peaks by operation type from query_log + part_log
-- @check memory-11 Memory Timeline Reconstruction
-- @requires table:system.part_log
with
    now() - interval 6 hour as min_time,
    now() as max_time,
    interval 30 minute as time_frame_size
select
    host,
    toStartOfInterval(event_timestamp, time_frame_size) as timeframe,
    formatReadableSize(max(mem_overall)) as peak_ram,
    formatReadableSize(maxIf(mem_by_type, event_type = 'Insert')) as inserts_ram,
    formatReadableSize(maxIf(mem_by_type, event_type = 'Select')) as selects_ram,
    formatReadableSize(maxIf(mem_by_type, event_type = 'MergeParts')) as merge_ram,
    formatReadableSize(maxIf(mem_by_type, event_type = 'MutatePart')) as mutate_ram
from (
    select
        host,
        toDateTime(toUInt32(ts)) as event_timestamp,
        t as event_type,
        sum(mem) over (partition by host, t order by ts) as mem_by_type,
        sum(mem) over (partition by host order by ts) as mem_overall
    from (
        with arrayJoin([
            (toFloat64(event_time_microseconds) - (duration_ms / 1000), toInt64(peak_memory_usage)),
            (toFloat64(event_time_microseconds), -peak_memory_usage)
        ]) as data
        select
            hostName() as host,
            cast(event_type, 'LowCardinality(String)') as t,
            data.1 as ts,
            data.2 as mem
        from clusterAllReplicas('{cluster}', system.part_log)
        where event_time between min_time and max_time
          and peak_memory_usage != 0

        union all

        with arrayJoin([
            (toFloat64(query_start_time_microseconds), toInt64(memory_usage)),
            (toFloat64(event_time_microseconds), -memory_usage)
        ]) as data
        select
            hostName() as host,
            query_kind as t,
            data.1 as ts,
            data.2 as mem
        from clusterAllReplicas('{cluster}', system.query_log)
        where event_time between min_time and max_time
          and memory_usage != 0
    )
)
group by host, timeframe
order by host, timeframe
;

-- Current Memory Settings
-- @check memory-12 Current Memory Settings
select
    hostName() as host,
    name,
    value,
    description
from clusterAllReplicas('{cluster}', system.server_settings)
where name in (
    'max_server_memory_usage',
    'max_server_memory_usage_to_ram_ratio',
    'max_memory_usage',
    'max_memory_usage_for_user',
    'memory_tracker_fault_probability'
)
order by name, host asc
;

-- Memory Used by Other Processes
-- @check memory-13 Memory Used by Other Processes
with
    (select toFloat64(value) from system.server_settings where name = 'max_server_memory_usage_to_ram_ratio') as max_ratio,
    (select value from system.asynchronous_metrics where metric = 'OSMemoryTotal') as total,
    (select value from system.asynchronous_metrics where metric = 'OSMemoryFreeWithoutCached') as free_without_cached,
    (select value from system.asynchronous_metrics where metric = 'MemoryResident') as clickhouse_resident,
    (select value from system.asynchronous_metrics where metric = 'OSMemoryCached') as cached,
    (select value from system.asynchronous_metrics where metric = 'OSMemoryBuffers') as buffers,
    total - free_without_cached as total_used,
    total_used - (buffers + cached + clickhouse_resident) as used_by_others
select
    formatReadableSize(used_by_others) as other_processes_memory,
    formatReadableSize(total * (1 - max_ratio)) as max_allowed_for_others,
    round(100.0 * used_by_others / total, 1) as pct_of_total,
    multiIf(used_by_others > total * (1 - max_ratio) * 2, 'Major', used_by_others > total * (1 - max_ratio), 'Moderate', 'OK') as severity,
    if(severity != 'OK', 'Other processes use RAM beyond the headroom left by max_server_memory_usage_to_ram_ratio; expected on shared hosts or containers that see host memory, a real risk on dedicated servers', 'OK') as note
;

-- High Memory from Aggregations
-- Find queries with high memory aggregations
-- @check memory-14 High Memory from Aggregations
select
    normalized_query_hash,
    count() as executions,
    formatReadableSize(max(memory_usage)) as max_memory,
    formatReadableSize(avg(memory_usage)) as avg_memory,
    any(substring(query, 1, 100)) as query_sample
from system.query_log
where type = 'QueryFinish'
  and event_date = today()
  and memory_usage > 1000000000
  and query ilike '%group by%'
group by normalized_query_hash
order by max(memory_usage) desc
limit 20
;

-- High Memory from JOINs
-- @check memory-15 High Memory from JOINs
select
    normalized_query_hash,
    count() as executions,
    formatReadableSize(max(memory_usage)) as max_memory,
    any(substring(query, 1, 100)) as query_sample
from system.query_log
where type = 'QueryFinish'
  and event_date = today()
  and memory_usage > 1000000000
  and query ilike '%join%'
group by normalized_query_hash
order by max(memory_usage) desc
limit 20
;
