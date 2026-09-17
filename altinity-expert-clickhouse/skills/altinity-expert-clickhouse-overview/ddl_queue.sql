-- DDL Queue Health (ON CLUSTER queue; only meaningful with Keeper/ZooKeeper configured)
-- @requires keeper
-- @check overview-ddl-queue-01 DDL queue health (ON CLUSTER)
WITH
    600  AS active_stuck_s,   -- “Active” older than this => jam
    100  AS backlog_warn,
    1000 AS backlog_major
SELECT
    cluster,
    countIf(status != 'Finished') AS not_finished,
    countIf(status = 'Active')    AS active,

    nullIf(minIf(query_create_time, status != 'Finished'), toDateTime(0)) AS oldest_not_finished,
    dateDiff('second', oldest_not_finished, now())                        AS oldest_not_finished_age_s,

    nullIf(minIf(query_create_time, status = 'Active'), toDateTime(0))    AS oldest_active,
    dateDiff('second', oldest_active, now())                              AS oldest_active_age_s,

    argMinIf(entry, query_create_time, status = 'Active')                 AS active_entry,
    argMinIf(host,  query_create_time, status = 'Active')                 AS active_host,
    argMinIf(substring(query, 1, 200), query_create_time, status = 'Active') AS active_query_200,

    multiIf(
      active > 0 AND oldest_active_age_s >= active_stuck_s, 'Major',
      not_finished >= backlog_major,                         'Major',
      not_finished >= backlog_warn,                          'Moderate',
      active > 0 AND oldest_active_age_s >= 120,             'Moderate',
      'OK'
    ) AS ddl_queue_health,

    if(ddl_queue_health != 'OK',
       'New ON CLUSTER may time out: queue is serialized by the oldest Active entry',
       'DDL queue looks healthy'
    ) AS note
FROM system.distributed_ddl_queue
GROUP BY cluster
ORDER BY (ddl_queue_health != 'OK') DESC, ifNull(oldest_active_age_s, 0) DESC, not_finished DESC
;
