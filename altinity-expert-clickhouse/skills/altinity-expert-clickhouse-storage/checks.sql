-- Disk Space Audit
-- @check storage-01 Disk Space Audit
select
    hostName() as host,
    name as disk_name,
    path,
    type,
    formatReadableSize(total_space) as total,
    formatReadableSize(free_space) as free,
    formatReadableSize(unreserved_space) as unreserved,
    round(100.0 * (total_space - free_space) / total_space, 1) as used_pct,
    multiIf(used_pct > 90, 'Critical', used_pct > 85, 'Major', used_pct > 80, 'Moderate', 'OK') as severity
from clusterAllReplicas('{cluster}', system.disks)
order by used_pct desc, host asc
;

-- Storage by Database
-- @check storage-02 Storage by Database
select
    hostName() as host,
    database,
    count() as tables,
    sum(total_rows) as rows,
    formatReadableSize(sum(total_bytes)) as total_size,
    formatReadableSize(sum(total_bytes) / nullIf(sum(total_rows), 0)) as avg_row_size
from clusterAllReplicas('{cluster}', system.tables)
where engine like '%MergeTree%'
group by host, database
order by sum(total_bytes) desc, host asc
;

-- Top Tables by Size
-- @check storage-03 Top Tables by Size
select
    hostName() as host,
    database,
    name,
    engine,
    formatReadableSize(total_bytes) as size,
    formatReadableQuantity(total_rows) as rows,
    formatReadableSize(total_bytes / nullIf(total_rows, 0)) as avg_row_size,
    ifNull(p.parts, 0) as parts
from clusterAllReplicas('{cluster}', system.tables) t
left join
(
    select
        hostName() as host,
        database,
        table,
        count() as parts
    from clusterAllReplicas('{cluster}', system.parts)
    where active
    group by host, database, table
) p on p.host = host and p.database = t.database and p.table = t.name
where engine like '%MergeTree%'
order by total_bytes desc, host asc
limit 30
;

-- Disk Usage by Path
-- @check storage-04 Disk Usage by Path
select
    hostName() as host,
    substr(path, 1, position(path, '/store/')) as disk_path,
    formatReadableSize(sum(bytes_on_disk)) as used,
    count() as parts,
    uniq(database, table) as tables
from clusterAllReplicas('{cluster}', system.parts)
where active
group by host, disk_path
order by sum(bytes_on_disk) desc, host asc
;

-- Overall Compression Ratio
-- @check storage-05 Overall Compression Ratio
select
    hostName() as host,
    formatReadableSize(sum(data_compressed_bytes)) as compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed,
    round(sum(data_uncompressed_bytes) / nullIf(sum(data_compressed_bytes), 0), 2) as ratio
from clusterAllReplicas('{cluster}', system.columns)
where database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
;

-- Compression by Table
-- @check storage-06 Compression by Table
select
    hostName() as host,
    database,
    table,
    formatReadableSize(sum(data_compressed_bytes)) as compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed,
    round(sum(data_uncompressed_bytes) / nullIf(sum(data_compressed_bytes), 0), 2) as ratio,
    if(ratio < 2, 'Poor', if(ratio < 5, 'OK', 'Good')) as compression_quality
from clusterAllReplicas('{cluster}', system.columns)
where database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
group by host, database, table
having sum(data_compressed_bytes) > 100000000
order by sum(data_compressed_bytes) desc, host asc
limit 30
;

-- Columns with Poor Compression
-- Solutions for poor compression:
-- Add explicit codec: CODEC(ZSTD(3))
-- For sequential integers: CODEC(Delta, ZSTD)
-- For timestamps: CODEC(DoubleDelta, ZSTD)
-- For low-cardinality strings: LowCardinality(String)
-- @check storage-07 Columns with Poor Compression
select
    hostName() as host,
    database,
    table,
    name as column,
    type,
    compression_codec,
    formatReadableSize(data_compressed_bytes) as compressed,
    formatReadableSize(data_uncompressed_bytes) as uncompressed,
    round(data_uncompressed_bytes / nullIf(data_compressed_bytes, 0), 2) as ratio
from clusterAllReplicas('{cluster}', system.columns)
where database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
  and data_compressed_bytes > 100000000
  and data_uncompressed_bytes / nullIf(data_compressed_bytes, 0) < 2
order by data_compressed_bytes desc, host asc
limit 30
;

-- Part Size Distribution
-- @check storage-08 Part Size Distribution
select
    hostName() as host,
    database,
    table,
    count() as parts,
    formatReadableSize(min(bytes_on_disk)) as min_part,
    formatReadableSize(median(bytes_on_disk)) as median_part,
    formatReadableSize(max(bytes_on_disk)) as max_part,
    formatReadableSize(sum(bytes_on_disk)) as total_size
from clusterAllReplicas('{cluster}', system.parts)
where active and database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
group by host, database, table
order by sum(bytes_on_disk) desc, host asc
limit 30
;

-- Small Parts Detection
-- @check storage-09 Small Parts Detection
select
    hostName() as host,
    database,
    table,
    countIf(bytes_on_disk < 1000000) as tiny_parts_under_1mb,
    countIf(bytes_on_disk < 10000000) as small_parts_under_10mb,
    count() as total_parts,
    round(100.0 * countIf(bytes_on_disk < 10000000) / count(), 1) as small_pct
from clusterAllReplicas('{cluster}', system.parts)
where active and database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
group by host, database, table
having small_pct > 50 and count() > 10
order by small_pct desc, host asc
limit 30
;

-- Wide vs Compact Parts
-- @check storage-10 Wide vs Compact Parts
select
    hostName() as host,
    database,
    table,
    countIf(part_type = 'Wide') as wide_parts,
    countIf(part_type = 'Compact') as compact_parts,
    countIf(part_type = 'InMemory') as memory_parts,
    formatReadableSize(sumIf(bytes_on_disk, part_type = 'Wide')) as wide_size,
    formatReadableSize(sumIf(bytes_on_disk, part_type = 'Compact')) as compact_size
from clusterAllReplicas('{cluster}', system.parts)
where active
group by host, database, table
having wide_parts > 0 or compact_parts > 0
order by wide_parts + compact_parts desc, host asc
limit 30
;

-- Disk IO Metrics
-- @check storage-11 Disk IO Metrics
select
    hostName() as host,
    metric,
    value,
    description
from clusterAllReplicas('{cluster}', system.asynchronous_metrics)
where metric like '%Disk%' or metric like '%IO%' or metric like '%Read%' or metric like '%Write%'
order by metric, host asc
;

-- Recent IO Activity from Query Log
-- @check storage-12 Recent IO Activity from Query Log
select
    hostName() as host,
    toStartOfFiveMinutes(event_time) as ts,
    count() as queries,
    formatReadableSize(sum(read_bytes)) as read_bytes,
    formatReadableSize(sum(written_bytes)) as written_bytes,
    sum(read_rows) as read_rows,
    sum(written_rows) as written_rows
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_time > now() - interval 1 hour
group by host, ts
order by ts desc, host asc
;

-- Queries with High IO
-- @check storage-13 Queries with High IO
select
    hostName() as host,
    query_id,
    user,
    formatReadableSize(read_bytes) as read_bytes_human,
    formatReadableSize(written_bytes) as written_bytes_human,
    round(query_duration_ms / 1000, 1) as duration_sec,
    substring(query, 1, 80) as query_preview
from clusterAllReplicas('{cluster}', system.query_log)
where type = 'QueryFinish'
  and event_date = today()
order by read_bytes + written_bytes desc, host asc
limit 20
;

-- System Logs Disk Usage
-- Check: If system logs > 5% of disk, add TTL or reduce retention.
-- @check storage-14 System Logs Disk Usage
select
    hostName() as host,
    table,
    formatReadableSize(sum(bytes_on_disk)) as size,
    count() as parts,
    round(100.0 * sum(bytes_on_disk) / nullIf(log_bytes, 0), 1) as pct_of_logs
from
(
    select
        hostName() as host,
        *
    from clusterAllReplicas('{cluster}', system.parts)
) p
left join
(
    select
        hostName() as host,
        sum(bytes_on_disk) as log_bytes
    from clusterAllReplicas('{cluster}', system.parts)
    where database = 'system' and table like '%_log' and active
    group by host
) totals on totals.host = p.host
where database = 'system' and table like '%_log' and active
group by host, table, log_bytes
order by sum(bytes_on_disk) desc, host asc
;

-- Detached Parts
-- Common reasons:
-- broken - Data corruption
-- noquorum - Replication quorum not reached
-- unexpected - Orphaned after failed operation
-- clone - Leftover from ATTACH
-- @check storage-15 Detached Parts
select
    hostName() as host,
    database,
    table,
    reason,
    count() as count,
    formatReadableSize(sum(bytes_on_disk)) as size
from clusterAllReplicas('{cluster}', system.detached_parts)
group by host, database, table, reason
order by sum(bytes_on_disk) desc, host asc
;

-- Storage Policies
-- @check storage-16 Storage Policies
select
    hostName() as host,
    policy_name,
    volume_name,
    volume_priority,
    disks,
    max_data_part_size,
    move_factor
from clusterAllReplicas('{cluster}', system.storage_policies)
order by policy_name, volume_priority, host asc
;

-- Tables by Storage Policy
-- @check storage-17 Tables by Storage Policy
select
    hostName() as host,
    storage_policy,
    count() as tables,
    formatReadableSize(sum(total_bytes)) as total_size
from clusterAllReplicas('{cluster}', system.tables)
where engine like '%MergeTree%'
group by host, storage_policy
order by sum(total_bytes) desc, host asc
;

-- Disk Filling Up - What's growing fastest?
-- @check storage-18 Disk Filling Up - What's growing fastest?
select
    hostName() as host,
    database,
    table,
    count() as new_parts,
    formatReadableSize(sum(bytes_on_disk)) as new_data
from clusterAllReplicas('{cluster}', system.parts)
where modification_time > now() - interval 1 hour
  and active
group by host, database, table
order by sum(bytes_on_disk) desc, host asc
limit 20
;

-- Slow Disk Detection
-- Check merge speeds as proxy for disk performance
-- @check storage-19 Slow Disk Detection
-- @requires table:system.part_log
select
    hostName() as host,
    database,
    table,
    count() as merges,
    round(avg(duration_ms)) as avg_ms,
    formatReadableSize(sum(size_in_bytes)) as merged_bytes,
    round(sum(size_in_bytes) / nullIf(sum(duration_ms), 0) * 1000) as bytes_per_sec,
    formatReadableSize(bytes_per_sec) as speed
from clusterAllReplicas('{cluster}', system.part_log)
where event_type = 'MergeParts'
  and event_date = today()
group by host, database, table
having count() > 5
order by bytes_per_sec asc, host asc
limit 20
;
