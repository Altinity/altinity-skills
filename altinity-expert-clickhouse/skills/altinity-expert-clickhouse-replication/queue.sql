/* 1) Queue size by table (per host)
Interpretation:
- Large queues + old tasks + retries/backoff usually means replication is stuck.
*/
-- @check replication-queue-01 Queue size by table (per host)
WITH
  count() AS count_all,
  countIf(last_exception != '') AS count_err,
  countIf(num_postponed > 0) AS count_postponed,
  countIf(is_currently_executing) AS count_executing
SELECT
  hostName() AS host,
  database,
  table,
  count_all AS queue_size,
  count_err AS with_errors,
  count_postponed AS postponed,
  count_executing AS executing,
  multiIf(count_all > 500, 'Critical', count_all > 400, 'Major', count_all > 200, 'Moderate', 'OK') AS severity
FROM clusterAllReplicas('{cluster}', system.replication_queue)
GROUP BY host, database, table
HAVING count_all > 50
ORDER BY severity ASC, queue_size DESC, host ASC
LIMIT 200;

/* 4) Queue tasks with errors/backoff (per host)
Use this to identify a table/type to drill down further.
*/
-- @check replication-queue-02 Queue tasks with errors/backoff (per host)
SELECT
  hostName() AS host,
  database,
  table,
  type,
  create_time,
  last_attempt_time,
  last_exception_time,
  num_tries,
  num_postponed,
  substring(postpone_reason, 1, 180) AS postpone_reason_180,
  substring(last_exception, 1, 240) AS last_exception_240,
  new_part_name,
  parts_to_merge,
  source_replica
FROM clusterAllReplicas('{cluster}', system.replication_queue)
WHERE last_exception != '' OR postpone_reason != ''
ORDER BY last_exception_time DESC, num_tries DESC, host ASC
LIMIT 200;
