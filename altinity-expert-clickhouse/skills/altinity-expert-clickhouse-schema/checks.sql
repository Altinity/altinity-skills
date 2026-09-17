-- Partition Health Audit
-- Interpretation:
-- Critical: >1500 partitions with tiny median size - partitioning key too granular
-- Major: >500 small partitions - consider coarser partitioning
-- Ideal: Partitions 1-10GB each, hundreds not thousands of partitions
-- @check schema-01 Partition Health Audit
with
    median(b) as median_partition_size_bytes,
    median(r) as median_partition_size_rows,
    count() as partition_count
select
    host,
    format('{}.{}', database, table) as object,
    multiIf(
        partition_count > 1500 and (median_partition_size_bytes < 16000000 or median_partition_size_rows < 250000), 'Critical',
        partition_count > 500 and (median_partition_size_bytes < 16000000 or median_partition_size_rows < 250000), 'Major',
        partition_count > 500 and (median_partition_size_bytes < 100000000 or median_partition_size_rows < 10000000), 'Moderate',
        partition_count > 100 and (median_partition_size_bytes < 16000000 or median_partition_size_rows < 250000), 'Moderate',
        partition_count > 1 and (median_partition_size_bytes < 16000000 or median_partition_size_rows < 250000), 'Minor',
        'OK'
    ) as severity,
    format('Partitions: {}, median size: {}, median rows: {}',
        toString(partition_count),
        formatReadableSize(median_partition_size_bytes),
        formatReadableQuantity(median_partition_size_rows)
    ) as details
from (
    select
        hostName() as host,
        database, table, partition,
        sum(bytes_on_disk) as b,
        sum(rows) as r
    from clusterAllReplicas('{cluster}', system.parts)
    where active and database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
    group by host, database, table, partition
)
group by host, database, table
having severity != 'OK'
order by
    multiIf(severity='Critical',1, severity='Major',2, severity='Moderate',3, 4),
    median_partition_size_bytes
limit 30
;

-- Oversized Partitions (for *MergeTree engines)
-- Why it matters: Aggregating/Replacing/etc engines need to merge entire partitions to collapse rows.
-- Oversized partitions = incomplete deduplication.
-- @check schema-02 Oversized Partitions (for *MergeTree engines)
with
    max(partition_bytes) as max_partition_bytes
select
    host,
    format('{}.{}', database, table) as object,
    multiIf(
        max_partition_bytes > max_merge_size * 0.95, 'Critical',
        max_partition_bytes > max_merge_size * 0.75, 'Major',
        max_partition_bytes > max_merge_size * 0.55, 'Moderate',
        'Minor'
    ) as severity,
    format('Max partition: {} (limit: {})',
        formatReadableSize(max_partition_bytes),
        formatReadableSize(max_merge_size)
    ) as details
from
(
    select
        hostName() as host,
        database,
        table,
        partition,
        sum(bytes_on_disk) as partition_bytes
    from clusterAllReplicas('{cluster}', system.parts)
    where active
      and database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
      and (database, table) in (
          select database, name from clusterAllReplicas('{cluster}', system.tables)
          where engine like '%Aggregating%' or engine like '%Collapsing%'
             or engine like '%Summing%' or engine like '%Replacing%' or engine like '%Graphite%'
      )
    group by host, database, table, partition
	) p
	left join
	(
	    select
	        hostName() as host,
	        max(toUInt64(value)) as max_merge_size
	    from clusterAllReplicas('{cluster}', system.merge_tree_settings)
	    where name = 'max_bytes_to_merge_at_max_space_in_pool'
	    group by host
	) s on s.host = p.host
	group by p.host, database, table, max_merge_size
	having max_partition_bytes > max_merge_size * 0.33 and max_partition_bytes > 20000000000
	order by max_partition_bytes desc, p.host asc
	limit 20
	;

-- Primary Key Analysis
-- Red flags:
-- First ORDER BY column is high-cardinality ID → poor data locality
-- Wide datatypes (UUID, DateTime64) → bloated primary key index
-- Poor compression on PK column → indicates high cardinality
-- @check schema-03 Primary Key Analysis
with
    tables as (
        select
            hostName() as host,
            format('{}.{}', database, name) as object,
            splitByChar(',', primary_key)[1] as pkey,
            total_rows
        from clusterAllReplicas('{cluster}', system.tables)
        where engine like '%MergeTree' and total_rows > 10000000
    ),
    columns as (
        select
            hostName() as host,
            format('{}.{}', database, table) as object,
            name, type,
            data_compressed_bytes / nullIf(data_uncompressed_bytes, 0) as ratio
        from clusterAllReplicas('{cluster}', system.columns)
    )
select
    tables.host,
    tables.object,
    'Minor' as severity,
    concat('First PK column (', pkey, ') issue: ',
        multiIf(
            pkey ilike '%id%', 'appears to be an ID (high cardinality)',
            type in ('UUID','UInt64','Int64','IPv4','IPv6','UInt32','Int32','UInt128') or type like 'DateTime%',
                concat('wide datatype (', type, ')'),
            ratio > 0.5, concat('poor compression (', toString(round(ratio, 2)), ')'),
            'unknown'
        )
    ) as details,
    round(ratio, 3) as compression_ratio
from tables
join columns on tables.host = columns.host and tables.object = columns.object and tables.pkey = columns.name
where ratio > 0.5 or pkey ilike '%id%'
   or type in ('UUID','UInt64','Int64','IPv4','IPv6','UInt32','Int32','UInt128')
   or type like 'DateTime%'
order by tables.total_rows desc, tables.host asc
limit 30
;

-- Column Count Check
-- @check schema-04 Column Count Check
with count() as columns
select
    host,
    object,
    multiIf(columns > 1500, 'Critical', columns > 1000, 'Major', columns > 800, 'Moderate', 'Minor') as severity,
    format('Too many columns: {}', toString(columns)) as details
from (
    select
        hostName() as host,
        format('{}.{}', database, table) as object,
        column
    from clusterAllReplicas('{cluster}', system.parts_columns)
    where modification_time > now() - interval 5 day
      and database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
    limit 1 by object, column
)
group by host, object
having columns > 600
order by columns desc, host asc
;

-- Nullable Columns Audit
-- Why avoid Nullable: Storage overhead, query complexity, NULL handling bugs.
-- @check schema-05 Nullable Columns Audit
with
    countIf(type like '%Nullable%') as nullable_columns,
    count() as total_columns
select
    hostName() as host,
    format('{}.{}', database, table) as object,
    'Minor' as severity,
    format('Nullable columns: {} of {} ({}%)',
        toString(nullable_columns),
        toString(total_columns),
        toString(round(100.0 * nullable_columns / total_columns, 1))
    ) as details
from clusterAllReplicas('{cluster}', system.columns)
where database not in ('system', 'information_schema', 'INFORMATION_SCHEMA')
group by host, database, table
having nullable_columns > 0.1 * total_columns or nullable_columns > 10
order by nullable_columns desc, host asc
limit 30
;

-- Long Names Check
-- @check schema-06 Long Names Check
select
    hostName() as host,
    format('{}.{}', database, name) as object,
    multiIf(length(name) > 196, 'Critical', length(name) > 128, 'Major', length(name) > 64, 'Moderate', 'Minor') as severity,
    format('Table name too long: {} chars', toString(length(name))) as details
from clusterAllReplicas('{cluster}', system.tables)
where length(name) > 32

union all

select
    hostName() as host,
    format('{}.{}.{}', database, table, name) as object,
    multiIf(length(name) > 196, 'Critical', length(name) > 128, 'Major', length(name) > 64, 'Moderate', 'Minor') as severity,
    format('Column name too long: {} chars', toString(length(name))) as details
from clusterAllReplicas('{cluster}', system.columns)
where length(name) > 32

order by severity, object, host asc
limit 50
;

-- MV Design Issues
-- @check schema-07 MV Design Issues
select
    hostName() as host,
    format('{}.{}', database, name) as object,
    multiIf(
        create_table_query ilike '%JOIN%', 'Moderate - JOIN in MV (only left table triggers updates)',
        splitByChar(' ', create_table_query)[5] != 'TO', 'Moderate - TO syntax not used (implicit target table)',
        'OK'
    ) as issue
from clusterAllReplicas('{cluster}', system.tables)
where engine = 'MaterializedView'
  and issue != 'OK'
;

-- MV Dependency Chain
-- @check schema-08 MV Dependency Chain
with count() as deps
select
    hostName() as host,
    referenced_database || '.' || referenced_table as parent_object,
    'Moderate' as severity,
    format('Long dependency chain: {} dependents', toString(deps)) as details
from clusterAllReplicas('{cluster}', system.tables) t
array join arrayConcat(dependencies_database, [database]) as referenced_database,
           arrayConcat(dependencies_table, [name]) as referenced_table
where length(dependencies_table) > 0
group by host, referenced_database, referenced_table
having deps > 10
order by deps desc, host asc
;

-- Table Overview
-- @check schema-09 Table Overview
select
    hostName() as host,
    database,
    name,
    engine,
    partition_key,
    sorting_key,
    primary_key,
    total_rows,
    formatReadableSize(total_bytes) as size,
    formatReadableSize(total_bytes / nullIf(total_rows, 0)) as avg_row_size
from clusterAllReplicas('{cluster}', system.tables)
where database not in ('system', 'INFORMATION_SCHEMA', 'information_schema')
  and engine like '%MergeTree%'
order by total_bytes desc, host asc
limit 50
;

-- Check table-level settings
-- @check schema-10 Check table-level settings
select
    hostName() as host,
    name, value, changed, description
from clusterAllReplicas('{cluster}', system.merge_tree_settings)
where name in (
    'index_granularity',
    'min_bytes_for_wide_part',
    'min_rows_for_wide_part',
    'ttl_only_drop_parts',
    'max_bytes_to_merge_at_max_space_in_pool'
)
;
