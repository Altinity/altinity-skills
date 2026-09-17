-- Current Running Queries
-- @check reporting-01 Current Running Queries
select
    hostName() as host,
    query_id,
    user,
    round(elapsed, 1) as elapsed_sec,
    formatReadableSize(read_bytes) as read_bytes,
    formatReadableSize(memory_usage) as memory,
    read_rows,
    substring(query, 1, 80) as query_preview
from clusterAllReplicas('{cluster}', system.processes)
where is_cancelled = 0
order by elapsed desc, host asc
limit 20
;

-- Recent Query Performance Summary
-- @check reporting-02 Recent Query Performance Summary
select
    hostName() as host,
    toStartOfFiveMinutes(event_time) as ts,
    count() as queries,
    countIf(type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')) as failed,
    round(avg(query_duration_ms)) as avg_ms,
    round(quantile(0.95)(query_duration_ms)) as p95_ms,
    round(max(query_duration_ms)) as max_ms,
    formatReadableSize(sum(read_bytes)) as read_bytes,
    formatReadableSize(sum(memory_usage)) as memory
from clusterAllReplicas('{cluster}', system.query_log)
where event_time > now() - interval 1 hour
  and type in ('QueryFinish', 'ExceptionWhileProcessing')
group by host, ts
order by ts desc, host asc
;

-- Slowest Queries (Last 24h)
-- @check reporting-03 Slowest Queries (Last 24h)
select
    hostName() as host,
    query_id,
    user,
    query_duration_ms,
    formatReadableSize(read_bytes) as read_bytes,
    formatReadableSize(memory_usage) as memory,
    read_rows,
    result_rows,
    substring(query, 1, 100) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date >= today() - 1
  and query_kind = 'Select'
order by query_duration_ms desc, host asc
limit 20
;

-- Most Frequent Queries
-- @check reporting-04 Most Frequent Queries
select
    hostName() as host,
    normalized_query_hash,
    count() as executions,
    round(avg(query_duration_ms)) as avg_ms,
    round(quantile(0.95)(query_duration_ms)) as p95_ms,
    formatReadableSize(avg(read_bytes)) as avg_read,
    formatReadableSize(avg(memory_usage)) as avg_memory,
    any(substring(query, 1, 100)) as query_sample
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date = today()
  and query_kind = 'Select'
group by host, normalized_query_hash
having count() > 5
order by count() desc, host asc
limit 30
;

-- Queries by CPU Time
-- @check reporting-05 Queries by CPU Time
select
    hostName() as host,
    normalized_query_hash,
    sum(ProfileEvents['UserTimeMicroseconds']) as user_cpu_us,
    sum(ProfileEvents['SystemTimeMicroseconds']) as system_cpu_us,
    count() as executions,
    round(avg(query_duration_ms)) as avg_duration_ms,
    any(substring(query, 1, 80)) as query_sample
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date >= today() - 1
group by host, normalized_query_hash
order by user_cpu_us desc, host asc
limit 20
;

-- Queries Reading Too Much Data
-- High read_amplification indicates:
-- Missing or ineffective indexes
-- Poor ORDER BY alignment with query patterns
-- Full table scans
-- @check reporting-06 Queries Reading Too Much Data
select
    hostName() as host,
    query_id,
    user,
    formatReadableSize(read_bytes) as read_bytes,
    read_rows,
    result_rows,
    round(read_rows / nullIf(result_rows, 0)) as read_amplification,
    round(query_duration_ms / 1000, 1) as duration_sec,
    substring(query, 1, 100) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date = today()
  and query_kind = 'Select'
  and read_rows > 0
order by read_bytes desc, host asc
limit 20
;

-- Queries by Tables Accessed
-- @check reporting-07 Queries by Tables Accessed
select
    hostName() as host,
    arrayStringConcat(tables, ', ') as tables,
    count() as queries,
    round(avg(query_duration_ms)) as avg_ms,
    formatReadableSize(avg(read_bytes)) as avg_read
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date = today()
  and length(tables) > 0
group by host, tables
order by count() desc, host asc
limit 30
;

-- Recent Failures
-- @check reporting-08 Recent Failures
select
    hostName() as host,
    event_time,
    user,
    exception_code,
    substring(exception, 1, 150) as exception,
    substring(query, 1, 100) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  and event_date = today()
order by event_time desc, host asc
limit 30
;

-- Failure Summary by Error Code
-- Common exception codes:
-- 60 - Table doesn't exist
-- 62 - Syntax error
-- 241 - Memory limit exceeded
-- 159 - Timeout
-- 252 - Too many parts
-- @check reporting-09 Failure Summary by Error Code
select
    hostName() as host,
    exception_code,
    count() as failures,
    any(substring(exception, 1, 100)) as example_exception
from clusterAllReplicas('{cluster}', system.query_log)
where type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  and event_date = today()
group by host, exception_code
order by failures desc, host asc
limit 20
;

-- Query Types Distribution
-- @check reporting-10 Query Types Distribution
select
    hostName() as host,
    query_kind,
    count() as queries,
    round(avg(query_duration_ms)) as avg_ms,
    formatReadableSize(sum(read_bytes)) as total_read,
    formatReadableSize(sum(written_bytes)) as total_written
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date = today()
group by host, query_kind
order by queries desc, host asc
;

-- Peak Query Hours
-- @check reporting-11 Peak Query Hours
select
    hostName() as host,
    toHour(event_time) as hour,
    count() as queries,
    round(avg(query_duration_ms)) as avg_ms,
    max(query_duration_ms) as max_ms
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date = today()
group by host, hour
order by host, hour
;

-- Queries by User
-- @check reporting-12 Queries by User
select
    hostName() as host,
    user,
    count() as queries,
    countIf(type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')) as failures,
    round(avg(query_duration_ms)) as avg_ms,
    formatReadableSize(sum(read_bytes)) as total_read
from clusterAllReplicas('{cluster}', system.query_log)
where event_date = today()
group by host, user
order by queries desc, host asc
;

-- MV Execution During Inserts
-- @check reporting-13 MV Execution During Inserts
-- @requires table:system.query_views_log
select
    hostName() as host,
    view_name,
    count() as trigger_count,
    round(avg(view_duration_ms)) as avg_ms,
    round(max(view_duration_ms)) as max_ms,
    round(sum(view_duration_ms) / 1000) as total_sec,
    formatReadableSize(sum(written_bytes)) as written
from clusterAllReplicas('{cluster}', system.query_views_log)
where event_time > now() - interval 1 hour
group by host, view_name
order by sum(view_duration_ms) desc, host asc
limit 20
;

-- Slow MV Breakdown by Query
-- @check reporting-14 Slow MV Breakdown by Query
-- @requires table:system.query_views_log
select
    hostName() as host,
    initial_query_id,
    view_name,
    view_type,
    view_duration_ms,
    read_rows,
    written_rows,
    formatReadableSize(peak_memory_usage) as memory,
    status
from clusterAllReplicas('{cluster}', system.query_views_log)
where event_time > now() - interval 1 hour
order by view_duration_ms desc, host asc
limit 30
;

-- Distributed Query Performance
-- @check reporting-15 Distributed Query Performance
select
    hostName() as host,
    query_id,
    is_initial_query,
    formatReadableSize(read_bytes) as read_bytes,
    read_rows,
    round(query_duration_ms / 1000, 1) as duration_sec,
    length(thread_ids) as threads,
    substring(query, 1, 80) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date = today()
  and (query like '%Distributed%' or is_initial_query = 0)
order by query_duration_ms desc, host asc
limit 30
;
