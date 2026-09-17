-- Dictionary Overview
-- @check dictionaries-01 Dictionary Overview
select
    hostName() as host,
    database,
    name,
    status,
    origin,
    type,
    formatReadableSize(bytes_allocated) as memory,
    element_count as elements,
    loading_duration,
    last_successful_update_time,
    last_exception
from clusterAllReplicas('{cluster}', system.dictionaries)
order by bytes_allocated desc, host asc
;

-- Dictionary Health Check
-- @check dictionaries-02 Dictionary Health Check
select
    hostName() as host,
    database,
    name,
    status,
    multiIf(
        status = 'FAILED', 'Critical',
        status = 'LOADING', 'Moderate',
        last_exception != '', 'Major',
        dateDiff('hour', last_successful_update_time, now()) > 24, 'Moderate',
        'OK'
    ) as severity,
    last_exception,
    last_successful_update_time
from clusterAllReplicas('{cluster}', system.dictionaries)
order by
    multiIf(severity = 'Critical', 1, severity = 'Major', 2, severity = 'Moderate', 3, 4),
    bytes_allocated desc,
    host asc
;

-- Memory Usage Audit
-- @check dictionaries-03 Memory Usage Audit
select
    d.host as host,
    formatReadableSize(dict_memory) as total_dictionary_memory,
    formatReadableSize(total_ram) as total_ram_human,
    round(100.0 * dict_memory / total_ram, 2) as pct_of_ram,
    multiIf(100.0 * dict_memory / total_ram > 20, 'Critical', 100.0 * dict_memory / total_ram > 15, 'Major', 100.0 * dict_memory / total_ram > 10, 'Moderate', 'OK') as severity
from
(
    select
        hostName() as host,
        sum(bytes_allocated) as dict_memory
    from clusterAllReplicas('{cluster}', system.dictionaries)
    group by host
) as d
left join
(
    select
        hostName() as host,
        toUInt64(maxIf(value, metric = 'OSMemoryTotal')) as total_ram
    from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
    where metric = 'OSMemoryTotal'
    group by host
) as m on m.host = d.host
;

-- Top Dictionaries by Memory
-- @check dictionaries-04 Top Dictionaries by Memory
select
    hostName() as host,
    database,
    name,
    type,
    formatReadableSize(bytes_allocated) as memory,
    element_count as elements,
    round(bytes_allocated / nullIf(element_count, 0), 2) as bytes_per_element,
    loading_duration,
    lifetime_min,
    lifetime_max
from clusterAllReplicas('{cluster}', system.dictionaries)
order by bytes_allocated desc, host asc
limit 20
;

-- Dictionary Configuration
-- @check dictionaries-05 Dictionary Configuration
select
    hostName() as host,
    database,
    name,
    key,
    attribute.names as attributes,
    attribute.types as types,
    source,
    lifetime_min,
    lifetime_max,
    loading_start_time,
    loading_duration
from clusterAllReplicas('{cluster}', system.dictionaries)
order by name, host asc
;

-- Dictionary Staleness Check
-- @check dictionaries-06 Dictionary Staleness Check
select
    hostName() as host,
    database,
    name,
    last_successful_update_time,
    dateDiff('second', last_successful_update_time, now()) as seconds_since_update,
    lifetime_max as lifetime_max_seconds,
    multiIf(
        seconds_since_update > lifetime_max * 2, 'Critical',
        seconds_since_update > lifetime_max, 'Major',
        seconds_since_update > lifetime_max * 0.9, 'Moderate',
        'OK'
    ) as severity,
    multiIf(
        seconds_since_update > lifetime_max * 2, 'very stale: more than 2x lifetime since last successful update',
        seconds_since_update > lifetime_max, 'past lifetime: reload overdue or failing',
        seconds_since_update > lifetime_max * 0.9, 'approaching lifetime',
        'fresh'
    ) as note
from clusterAllReplicas('{cluster}', system.dictionaries)
where lifetime_max > 0
order by seconds_since_update desc, host asc
;

-- Current Failures
-- @check dictionaries-07 Current Failures
select
    hostName() as host,
    database,
    name,
    status,
    last_exception,
    loading_start_time,
    last_successful_update_time
from clusterAllReplicas('{cluster}', system.dictionaries)
where status = 'FAILED' or last_exception != ''
;

-- Dictionary Load Errors in Logs
-- @check dictionaries-08 Dictionary Load Errors in Logs
-- @requires table:system.text_log
select
    hostName() as host,
    event_time,
    level,
    logger_name,
    substring(message, 1, 300) as message
from clusterAllReplicas('{cluster}', system.text_log)
where logger_name like '%Dictionary%'
  and level in ('Error', 'Warning')
  and event_time > now() - interval 1 hour
order by event_time desc, host asc
limit 30
;

-- Lookup Performance (via query_log)
-- @check dictionaries-09 Lookup Performance (via query_log)
select
    hostName() as host,
    normalized_query_hash,
    count() as executions,
    round(avg(query_duration_ms)) as avg_ms,
    any(substring(query, 1, 100)) as query_sample
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and query ilike '%dictGet%'
  and event_date = today()
group by host, normalized_query_hash
order by count() desc, host asc
limit 20
;

-- Dictionary Hit/Miss Ratio
-- @check dictionaries-10 Dictionary Hit/Miss Ratio
select
    hostName() as host,
    'DictCacheHits' as metric,
    value
from clusterAllReplicas('{cluster}', system.events)
where event = 'DictCacheHits'
union all
select
    hostName() as host,
    'DictCacheMisses' as metric,
    value
from clusterAllReplicas('{cluster}', system.events)
where event = 'DictCacheMisses'
settings system_events_show_zero_values = 1
;

-- Cache Dictionary Analysis
-- For cache dictionaries, check hit rate and size
-- @check dictionaries-11 Cache Dictionary Analysis
select
    hostName() as host,
    database,
    name,
    type,
    element_count,
    formatReadableSize(bytes_allocated) as memory,
    loading_duration
from clusterAllReplicas('{cluster}', system.dictionaries)
where lower(type) like '%cache%'
;

-- Flat/Hashed Dictionary Size Check
-- @check dictionaries-12 Flat/Hashed Dictionary Size Check
select
    hostName() as host,
    database,
    name,
    type,
    element_count,
    formatReadableSize(bytes_allocated) as memory,
    round(bytes_allocated / nullIf(element_count, 0)) as bytes_per_key,
    if(bytes_per_key > 1000, 'High memory per key', 'OK') as note
from clusterAllReplicas('{cluster}', system.dictionaries)
where type in ('Flat', 'Hashed', 'ComplexKeyHashed')
order by bytes_allocated desc, host asc
;

-- Identify Source Types
-- @check dictionaries-13 Identify Source Types
select
    hostName() as host,
    source,
    count() as dictionaries,
    formatReadableSize(sum(bytes_allocated)) as total_memory
from clusterAllReplicas('{cluster}', system.dictionaries)
group by host, source
order by sum(bytes_allocated) desc, host asc
;

-- Check Source Connectivity (for ClickHouse source dictionaries)
-- @check dictionaries-14 Check Source Connectivity (for ClickHouse source dictionaries)
select
    hostName() as host,
    name as dictionary_name,
    source
from clusterAllReplicas('{cluster}', system.dictionaries)
where source like '%clickhouse%'
;

-- Scheduled Reload Check
-- @check dictionaries-15 Scheduled Reload Check
select
    hostName() as host,
    database,
    name,
    lifetime_min,
    lifetime_max,
    last_successful_update_time,
    dateDiff('second', last_successful_update_time, now()) as seconds_since_update,
    if(seconds_since_update > lifetime_max, 'Should have reloaded', 'OK') as reload_status
from clusterAllReplicas('{cluster}', system.dictionaries)
where lifetime_max > 0
order by seconds_since_update desc, host asc
;
