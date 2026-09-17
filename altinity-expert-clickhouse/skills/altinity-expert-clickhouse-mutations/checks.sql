-- Current Mutations Status
-- @check mutations-01 Current Mutations Status
select
    hostName() as host,
    database,
    table,
    mutation_id,
    command,
    create_time,
    is_done,
    parts_to_do,
    latest_failed_part,
    latest_fail_time,
    latest_fail_reason
from clusterAllReplicas('{cluster}', system.mutations)
where not is_done
order by create_time, host asc
;

-- Mutation Summary by Table
-- @check mutations-02 Mutation Summary by Table
select
    hostName() as host,
    database,
    table,
    countIf(not is_done) as pending,
    countIf(is_done) as completed,
    countIf(latest_fail_reason != '') as failed,
    min(create_time) as oldest_pending
from clusterAllReplicas('{cluster}', system.mutations)
group by host, database, table
having pending > 0
order by pending desc, host asc
;

-- Stuck Mutations Detection
-- @check mutations-03 Stuck Mutations Detection
with
    now() as current_time,
    dateDiff('minute', create_time, current_time) as age_minutes
select
    hostName() as host,
    database,
    table,
    mutation_id,
    substring(command, 1, 60) as command,
    create_time,
    age_minutes,
    parts_to_do,
    multiIf(age_minutes > 1440, 'Critical', age_minutes > 360, 'Major', age_minutes > 60, 'Moderate', 'OK') as severity,
    latest_fail_reason
from clusterAllReplicas('{cluster}', system.mutations)
where not is_done
  and age_minutes > 30
order by create_time, host asc
;

-- Recent Completed Mutations
-- @check mutations-04 Recent Completed Mutations
-- @requires table:system.part_log
select
    hostName() as host,
    event_time,
    database,
    table,
    part_name,
    duration_ms,
    formatReadableSize(size_in_bytes) as size,
    rows,
    formatReadableSize(peak_memory_usage) as peak_memory
from clusterAllReplicas('{cluster}', system.part_log)
where event_type = 'MutatePart'
  and event_date >= today() - 1
order by event_time desc, host asc
limit 30
;

-- Mutation Performance by Table
-- @check mutations-05 Mutation Performance by Table
-- @requires table:system.part_log
select
    hostName() as host,
    database,
    table,
    count() as mutations,
    round(avg(duration_ms)) as avg_ms,
    round(max(duration_ms)) as max_ms,
    formatReadableSize(sum(size_in_bytes)) as total_size,
    sum(rows) as total_rows
from clusterAllReplicas('{cluster}', system.part_log)
where event_type = 'MutatePart'
  and event_date >= today() - 7
group by host, database, table
order by count() desc, host asc
limit 30
;

-- Failed Mutations in Part Log
-- @check mutations-06 Failed Mutations in Part Log
-- @requires table:system.part_log
select
    hostName() as host,
    event_time,
    database,
    table,
    part_name,
    duration_ms,
    error,
    exception
from clusterAllReplicas('{cluster}', system.part_log)
where event_type = 'MutatePart'
  and error != 0
  and event_date >= today() - 7
order by event_time desc, host asc
limit 30
;

-- Mutations Running Now
-- @check mutations-07 Mutations Running Now
select
    hostName() as host,
    database,
    table,
    elapsed,
    progress,
    is_mutation,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) as size,
    formatReadableSize(memory_usage) as memory,
    result_part_name
from clusterAllReplicas('{cluster}', system.merges)
where is_mutation = 1
order by elapsed desc, host asc
;

-- Parts Awaiting Mutation
-- @check mutations-08 Parts Awaiting Mutation
WITH
    parts_by_table AS
    (
        SELECT
            hostName() as host,
            database,
            `table`,
            count() AS total_active_parts
        FROM clusterAllReplicas('{cluster}', system.parts)
        WHERE active
        GROUP BY host, database, `table`
    )
SELECT
    m.host,
    m.database,
    m.table,
    m.mutation_id,
    m.parts_to_do,
    m.command,
    ifNull(p.total_active_parts, 0) AS total_active_parts,
    if(p.total_active_parts = 0, 0.0, round(100.0 * m.parts_to_do / p.total_active_parts, 1)) AS pct_remaining
FROM
(
    select hostName() as host, *
    from clusterAllReplicas('{cluster}', system.mutations)
) AS m
LEFT JOIN parts_by_table AS p ON p.host = m.host AND p.database = m.database AND p.`table` = m.table
WHERE NOT m.is_done
ORDER BY m.parts_to_do DESC
;

-- Mutation vs Merge Competition
-- Check background pool saturation
-- Mutations and merges share the same pool. If pool is saturated, mutations wait.
-- @check mutations-09 Mutation vs Merge Competition
select
    hostName() as host,
    metric,
    value
from clusterAllReplicas('{cluster}', system.metrics)
where metric like 'Background%'
;

-- Mutation Creation Rate
-- Red flag: >1 mutation per 5 minutes sustained = mutation overload.
-- @check mutations-10 Mutation Creation Rate
select
    hostName() as host,
    toStartOfHour(create_time) as hour,
    count() as mutations_created,
    countIf(is_done) as completed,
    countIf(not is_done) as pending
from clusterAllReplicas('{cluster}', system.mutations)
where create_time > now() - interval 7 day
group by host, hour
order by hour desc, host asc
;

-- Mutation Types
-- @check mutations-11 Mutation Types
select
    hostName() as host,
    multiIf(
        command ilike '%DELETE%', 'DELETE',
        command ilike '%UPDATE%', 'UPDATE',
        command ilike '%MATERIALIZE%', 'MATERIALIZE',
        command ilike '%DROP COLUMN%', 'DROP COLUMN',
        command ilike '%ADD COLUMN%', 'ADD COLUMN',
        command ilike '%MODIFY%', 'MODIFY',
        'OTHER'
    ) as mutation_type,
    count() as total,
    countIf(not is_done) as pending,
    countIf(latest_fail_reason != '') as failed
from clusterAllReplicas('{cluster}', system.mutations)
group by host, mutation_type
order by total desc, host asc
;
