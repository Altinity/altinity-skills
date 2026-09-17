-- Mark Cache Health
-- Interpretation:
-- hit_ratio < 0.7 → Cache too small or access pattern not cache-friendly
-- pct_of_ram > 15% → Cache consuming too much RAM
-- pct_marks_cached < 1% → Very few marks in cache (might be OK for large datasets)
-- @check caches-01 Mark Cache Health
select
    hostName() as host,
    'Mark Cache' as cache,
    formatReadableSize(cache_bytes) as size,
    hits,
    misses,
    round(hits / nullIf(hits + misses, 0), 3) as hit_ratio,
    multiIf(hits / nullIf(hits + misses, 0) < 0.3, 'Critical', hits / nullIf(hits + misses, 0) < 0.5, 'Major', hits / nullIf(hits + misses, 0) < 0.7, 'Moderate', 'OK') as hit_severity,
    round(100.0 * cache_bytes / total_ram, 2) as pct_of_ram,
    multiIf(100.0 * cache_bytes / total_ram > 25, 'Critical', 100.0 * cache_bytes / total_ram > 20, 'Major', 100.0 * cache_bytes / total_ram > 15, 'Moderate', 'OK') as size_severity,
    round(100.0 * cache_bytes / nullIf(total_marks_bytes, 0), 2) as pct_marks_cached
from
(
    with
        events as
        (
            select
                hostName() as host,
                event,
                value
            from clusterAllReplicas('{cluster}', system.events)
            where event in ('MarkCacheHits', 'MarkCacheMisses')
        ),
        async as
        (
            select
                hostName() as host,
                metric,
                value
            from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
            where metric in ('MarkCacheBytes', 'OSMemoryTotal')
        ),
        marks as
        (
            select
                hostName() as host,
                sum(marks_bytes) as total_marks_bytes
            from clusterAllReplicas('{cluster}', system.parts)
            where active
            group by host
        )
    select
        m.host as host,
        toUInt64(maxIf(e.value, e.event = 'MarkCacheHits')) as hits,
        toUInt64(maxIf(e.value, e.event = 'MarkCacheMisses')) as misses,
        toUInt64(maxIf(a.value, a.metric = 'MarkCacheBytes')) as cache_bytes,
        toUInt64(maxIf(a.value, a.metric = 'OSMemoryTotal')) as total_ram,
        m.total_marks_bytes
    from marks m
    left join events e on e.host = m.host
    left join async a on a.host = m.host
    group by
        m.host,
        m.total_marks_bytes
)
settings system_events_show_zero_values = 1
;

-- Uncompressed Cache Health
-- Note: Uncompressed cache is disabled by default. Low hit ratio is normal if not explicitly configured.
-- @check caches-02 Uncompressed Cache Health
select
    hostName() as host,
    'Uncompressed Cache' as cache,
    formatReadableSize(cache_bytes) as size,
    hits,
    misses,
    round(hits / nullIf(hits + misses, 0), 3) as hit_ratio,
    multiIf(hits / nullIf(hits + misses, 0) < 0.01 and misses > 1000, 'Moderate', 'OK') as hit_severity,
    round(100.0 * cache_bytes / total_ram, 2) as pct_of_ram,
    multiIf(100.0 * cache_bytes / total_ram > 25, 'Critical', 100.0 * cache_bytes / total_ram > 20, 'Major', 100.0 * cache_bytes / total_ram > 15, 'Moderate', 'OK') as size_severity
from
(
    with
        events as
        (
            select
                hostName() as host,
                event,
                value
            from clusterAllReplicas('{cluster}', system.events)
            where event in ('UncompressedCacheHits', 'UncompressedCacheMisses')
        ),
        async as
        (
            select
                hostName() as host,
                metric,
                value
            from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
            where metric in ('UncompressedCacheBytes', 'OSMemoryTotal')
        )
    select
        e.host as host,
        toUInt64(maxIf(e.value, e.event = 'UncompressedCacheHits')) as hits,
        toUInt64(maxIf(e.value, e.event = 'UncompressedCacheMisses')) as misses,
        toUInt64(maxIf(a.value, a.metric = 'UncompressedCacheBytes')) as cache_bytes,
        toUInt64(maxIf(a.value, a.metric = 'OSMemoryTotal')) as total_ram
    from events e
    left join async a on a.host = e.host
    group by e.host
)
settings system_events_show_zero_values = 1
;

-- Query Cache Health (v23.1+)
-- @check caches-03 Query Cache Health (v23.1+)
select
    hostName() as host,
    'Query Cache' as cache,
    formatReadableSize(sum(result_size)) as cached_data,
    count() as entries
from clusterAllReplicas('{cluster}', system.query_cache)
group by host
;

-- Compiled Expression Cache
-- @check caches-04 Compiled Expression Cache
select
    hostName() as host,
    'Compiled Expression Cache' as cache,
    hits,
    misses,
    round(hits / nullIf(hits + misses, 0), 3) as hit_ratio
from
(
    select
        hostName() as host,
        toUInt64(maxIf(value, event = 'CompiledExpressionCacheHits')) as hits,
        toUInt64(maxIf(value, event = 'CompiledExpressionCacheMisses')) as misses
    from clusterAllReplicas('{cluster}', system.events)
    where event in ('CompiledExpressionCacheHits', 'CompiledExpressionCacheMisses')
    group by host
)
settings system_events_show_zero_values = 1
;

-- Mark Cache by Table
-- @check caches-05 Mark Cache by Table
select
    hostName() as host,
    database,
    table,
    formatReadableSize(sum(marks_bytes)) as marks_size,
    sum(marks) as marks_count,
    count() as parts
from clusterAllReplicas('{cluster}', system.parts)
where active
group by host, database, table
order by sum(marks_bytes) desc, host asc
limit 20
;

-- Primary Key Memory by Table
-- @check caches-06 Primary Key Memory by Table
select
    hostName() as host,
    database,
    table,
    formatReadableSize(sum(primary_key_bytes_in_memory)) as pk_in_memory,
    formatReadableSize(sum(primary_key_bytes_in_memory_allocated)) as pk_allocated,
    sum(marks) as marks
from clusterAllReplicas('{cluster}', system.parts)
where active
group by host, database, table
order by sum(primary_key_bytes_in_memory) desc, host asc
limit 20
;

-- Cache Events Over Time
-- @check caches-07 Cache Events Over Time
-- @requires table:system.asynchronous_metric_log
select
    hostName() as host,
    toStartOfFiveMinutes(event_time) as ts,
    sumIf(value, metric = 'MarkCacheBytes') as mark_cache_bytes,
    sumIf(value, metric = 'UncompressedCacheBytes') as uncompressed_cache_bytes,
    sumIf(value, metric = 'QueryCacheBytes') as query_cache_bytes
from clusterAllReplicas('{cluster}', system.asynchronous_metric_log)
where event_time > now() - interval 1 hour
  and metric in ('MarkCacheBytes', 'UncompressedCacheBytes', 'QueryCacheBytes')
group by host, ts
order by ts, host
;

-- Current Cache Settings
-- @check caches-08 Current Cache Settings
select name, value, description
from clusterAllReplicas('{cluster}', system.server_settings)
where name in (
    'mark_cache_size',
    'uncompressed_cache_size',
    'query_cache_max_size',
    'compiled_expression_cache_size'
)
;

-- Sizing Analysis
-- @check caches-09 Sizing Analysis
select
    m.host as host,
    formatReadableSize(total_marks) as total_marks_size,
    formatReadableSize(total_ram * 0.05) as recommended_mark_cache_5pct,
    formatReadableSize(total_ram * 0.10) as recommended_mark_cache_10pct,
    formatReadableSize(least(total_marks, total_ram * 0.15)) as ideal_mark_cache,
    'Ideal = min(all_marks, 15% RAM)' as formula
from
(
    select
        hostName() as host,
        toFloat64(maxIf(value, metric = 'OSMemoryTotal')) as total_ram
    from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    where metric = 'OSMemoryTotal'
    group by host
) as m
left join
(
    select
        hostName() as host,
        toFloat64(sum(marks_bytes)) as total_marks
    from clusterAllReplicas('{cluster}', system.parts)
    where active
    group by host
) as p on p.host = m.host
;

-- Poor Mark Cache Hit Ratio Diagnostic
-- Check which tables are being queried
-- @check caches-10 Poor Mark Cache Hit Ratio Diagnostic
select
    hostName() as host,
    arrayStringConcat(tables, ', ') as tables,
    count() as query_count,
    round(avg(read_rows)) as avg_rows_read
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date = today()
  and length(tables) > 0
group by host, tables
order by query_count desc, host asc
limit 20
;

-- Cache Too Large - Check for tables with excessive marks
-- @check caches-11 Cache Too Large - Check for tables with excessive marks
select
    prt.host as host,
    database,
    table,
    formatReadableSize(sum(marks_bytes)) as marks_size,
    sum(marks) as marks_count,
    round(sum(marks_bytes) / nullIf(cache_bytes, 0) * 100, 2) as pct_of_cache
from
(
    select
        hostName() as host,
        database,
        table,
        marks_bytes,
        marks
    from clusterAllReplicas('{cluster}', system.parts)
    where active
) as prt
left join
(
    select
        hostName() as host,
        toFloat64(maxIf(value, metric = 'MarkCacheBytes')) as cache_bytes
    from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    where metric = 'MarkCacheBytes'
    group by host
) as mc on mc.host = prt.host
group by prt.host, database, table, cache_bytes
having sum(marks_bytes) > 100000000
order by sum(marks_bytes) desc, prt.host asc
limit 20
;

-- Cache hit ratio over time (last hour)
-- @check caches-12 Cache hit ratio over time (last hour)
-- @requires table:system.metric_log
select
    hostName() as host,
    toStartOfMinute(event_time) as ts,
    sum(ProfileEvent_MarkCacheHits) as hits,
    sum(ProfileEvent_MarkCacheMisses) as misses,
    round(hits / nullIf(hits + misses, 0), 3) as hit_ratio
from clusterAllReplicas('{cluster}', system.metric_log)
where event_time > now() - interval 1 hour
group by host, ts
order by ts, host
;
