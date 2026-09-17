-- 1) Current merge activity with memory and algorithm/type
-- @check merges-01 Current merge activity with memory and algorithm/type
select
    hostName() as host,
    database,
    table,
    round(elapsed, 1) as elapsed_sec,
    round(progress * 100, 1) as progress_pct,
    num_parts,
    merge_type,
    merge_algorithm,
    formatReadableSize(total_size_bytes_compressed) as source_size,
    formatReadableSize(memory_usage) as memory_usage,
    is_mutation,
    result_part_name
from clusterAllReplicas('{cluster}', system.merges)
order by elapsed desc, host asc
limit 100
;

-- 2) Active merge memory summary by host
-- @check merges-02 Active merge memory summary by host
select
    hostName() as host,
    count() as active_merges,
    formatReadableSize(sum(memory_usage)) as total_merge_memory,
    formatReadableSize(max(memory_usage)) as max_single_merge_memory
from clusterAllReplicas('{cluster}', system.merges)
group by host
order by sum(memory_usage) desc, host asc
limit 100
;

-- 3) Active merge memory summary cluster-wide
-- @check merges-03 Active merge memory summary cluster-wide
select
    count() as active_merges,
    formatReadableSize(sum(memory_usage)) as cluster_total_merge_memory,
    formatReadableSize(max(memory_usage)) as cluster_max_single_merge_memory
from clusterAllReplicas('{cluster}', system.merges)
;

-- 4) Merge success/failure trend by hour (24h)
-- @check merges-04 Merge success/failure trend by hour (24h)
-- @requires table:system.part_log
select
    hostName() as host,
    toStartOfHour(event_time) as hour,
    countIf(event_type = 'MergeParts' and error = 0) as merge_ok,
    countIf(event_type = 'MergeParts' and error != 0) as merge_failed,
    round(100.0 * merge_failed / nullIf(merge_ok + merge_failed, 0), 2) as fail_pct
from clusterAllReplicas('{cluster}', system.part_log)
where event_time >= now() - interval 24 hour
group by host, hour
order by hour desc, host asc
limit 500
;

-- 5) Table-level merge verdict summary (24h)
-- @check merges-05 Table-level merge verdict summary (24h)
-- @requires table:system.part_log
select
    database,
    table,
    countIf(event_type = 'MergeParts' and error = 0) as merge_ok_24h,
    countIf(event_type = 'MergeParts' and error != 0) as merge_failed_24h,
    maxIf(event_time, event_type = 'MergeParts' and error = 0) as last_merge_ok_time,
    maxIf(event_time, event_type = 'MergeParts' and error != 0) as last_merge_fail_time
from clusterAllReplicas('{cluster}', system.part_log)
where event_time >= now() - interval 24 hour
group by database, table
having merge_ok_24h + merge_failed_24h > 0
order by merge_failed_24h desc, merge_ok_24h asc
limit 200
;

-- 6) Merge reason + algorithm matrix (24h)
-- @check merges-06 Merge reason + algorithm matrix (24h)
-- @requires table:system.part_log
select
    database,
    table,
    merge_reason,
    merge_algorithm,
    count() as merge_events,
    countIf(error != 0) as failed_events,
    round(100.0 * failed_events / count(), 2) as failed_pct,
    round(avg(duration_ms)) as avg_duration_ms,
    round(quantile(0.95)(duration_ms)) as p95_duration_ms,
    formatReadableSize(sum(size_in_bytes)) as result_bytes,
    sum(rows) as result_rows,
    max(event_time) as last_event_time
from clusterAllReplicas('{cluster}', system.part_log)
where event_time >= now() - interval 24 hour
  and event_type = 'MergeParts'
group by database, table, merge_reason, merge_algorithm
order by merge_events desc
limit 500
;

-- 7) Peak merge RAM by table from part_log (24h)
-- @check merges-07 Peak merge RAM by table from part_log (24h)
-- @requires table:system.part_log
select
    database,
    table,
    count() as merge_events,
    countIf(error != 0) as failed_merges,
    formatReadableSize(sum(peak_memory_usage)) as sum_peak_memory,
    formatReadableSize(avg(peak_memory_usage)) as avg_peak_memory,
    formatReadableSize(quantileExact(0.95)(peak_memory_usage)) as p95_peak_memory,
    formatReadableSize(max(peak_memory_usage)) as max_peak_memory,
    max(event_time) as last_merge_time
from clusterAllReplicas('{cluster}', system.part_log)
where event_time >= now() - interval 24 hour
  and event_type = 'MergeParts'
group by database, table
order by max(peak_memory_usage) desc
limit 200
;

-- 8) Part count offenders
-- @check merges-08 Part count offenders
select
    hostName() as host,
    database,
    table,
    partition_id,
    count() as part_count,
    formatReadableSize(sum(bytes_on_disk)) as size
from clusterAllReplicas('{cluster}', system.parts)
where active
group by host, database, table, partition_id
having part_count > 50
order by part_count desc, host asc
limit 200
;
