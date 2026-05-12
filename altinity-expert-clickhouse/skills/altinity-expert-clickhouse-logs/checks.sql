-- query_log should be enabled
with
(select max(modification_time) from system.parts) -
(select max(modification_time) from system.parts where database='system' and table='query_log') as lag
SELECT
    'A0.2.01' AS id,
    'system.query_log' AS object,
    'Major' AS severity,
    'No fresh records in system.query_log to analize' as details,
     map() as values
where lag > 3600*4

union all

-- part_log should be enabled
with
(select max(modification_time) from system.parts) -
(select max(modification_time) from system.parts where database='system' and table='part_log') as lag
SELECT
    'A0.2.02' AS id,
    'system.part_log' AS object,
    'Major' AS severity,
    'No fresh records in system.part_log to analize' as details,
     map() as values
where lag > 3600*4

    union all
-- system.query_log has too old data
with
(select max(modification_time) from system.parts) -
(select min(modification_time) from system.parts where database='system' and table='query_log') as age
SELECT
    'A0.2.03' AS id,
    'system.query_log' AS object,
    'Major' AS severity,
    format('system.query_log has too old data - {}',formatReadableTimeDelta(age)) as details,
     map('age',age) as values
where age > 3600*24*30
;

-- system log table should have TTL
SELECT
    'A0.2.04' AS id,
    format('{}.{}',database, name) AS object,
    'Major' AS severity,
    'System log tables should have TTL enabled' as details,
     map() as values
from clusterAllReplicas('{cluster}',system.tables)
where database='system' and name like '%_log'
 and engine_full not like '% TTL %'
;

-- system logs shall not allocate more than 20% available disk space
with used.sp/free.sp as ratio,
    max(ratio) as max_ratio
SELECT
    'A0.2.05' AS id,
    'System Logs' AS object,
    multiIf(max_ratio > 0.2, 'Critical', max_ratio > 0.1, 'Major', max_ratio > 0.05, 'Moderate', 'Minor') AS severity,
    format('system logs take too much space on disk {}, ratio - {}',argMax(path,ratio),toString(max_ratio)) as details,
    CAST((groupArray(path),groupArray(ratio)), 'Map(String, Float)') as values
from (
        select sum(bytes_on_disk) sp, substr(path,1,position(path,'/store/')) as path
        from system.parts where database='system' and table like '%_log' group by path
     ) as used
join (
        select arrayMin([COLUMNS('^(free_space|unreserved_space)$')]) as sp,path from system.disks
     ) as free
using path
having max_ratio > 0.01
;

-- there are no system.*_logN table (leftovers after version upgrade)
SELECT
    'A0.2.06' AS id,
    format('{}.{}',database, name) AS object,
    'Minor' AS severity,
    'Leftover after version upgrade. Should be dropped' as details,
     map() as values
from clusterAllReplicas('{cluster}',system.tables)
where database='system' and match(name,'(.\w+)_log_(\d+)')
;

-- system.query_thread_log is disabled
SELECT
    'A0.2.07' AS id,
    'System' AS object,
    'Major' AS severity,
    'system.query_thread_log should be disabled in production systems' as details,
     map() as values
from clusterAllReplicas('{cluster}',system.tables)
where database='system' and name='query_thread_log';

-- crash_log has not recent records
with count() as crash_count
SELECT
    'A0.2.08' AS id,
    'System' AS object,
    'Major' AS severity,
     format('There are {} crashes for last 5 days', toString(crash_count)) as details,
     map() as values
from clusterAllReplicas('{cluster}',system.crash_log)
where event_time > now() - interval 5 day
having crash_count > 1
;
