/* 1) Keeper/ZooKeeper session status (per host) */
-- @requires keeper
-- @check replication-triage-01 Keeper/ZooKeeper session status (per host)
SELECT hostName() AS ch_host, *
FROM clusterAllReplicas('{cluster}', system.zookeeper_connection)
ORDER BY host;

/* 2) Replication overview (triage)
Red flags:
- is_readonly=1 or is_session_expired=1 => Critical
- active_replicas < total_replicas => replicas missing
- absolute_delay > 300s => lag
*/
-- @check replication-triage-02 Replication overview (triage)
SELECT
  hostName() AS host,
  database,
  table,
  is_readonly,
  is_session_expired,
  active_replicas,
  total_replicas,
  future_parts,
  parts_to_check,
  queue_size,
  inserts_in_queue,
  merges_in_queue,
  part_mutations_in_queue,
  toInt64(log_max_index) - toInt64(log_pointer) AS log_lag,
  last_queue_update,
  absolute_delay,
  formatReadableTimeDelta(absolute_delay) AS delay_human,
  multiIf(
    is_readonly = 1 OR is_session_expired = 1, 'Critical',
    active_replicas < total_replicas, 'Major',
    absolute_delay > 3600 OR queue_size > 1000, 'Major',
    absolute_delay > 300 OR queue_size > 200, 'Moderate',
    'OK'
  ) AS severity,
  multiIf(
    is_readonly = 1 OR is_session_expired = 1, 'Check ZooKeeper connectivity, disk, and logs',
    active_replicas < total_replicas, 'Identify missing replicas / network / restarts',
    absolute_delay > 300 OR queue_size > 200, 'Inspect replication_queue (errors, oldest tasks) and fetches',
    'Looks OK'
  ) AS recommendation
FROM clusterAllReplicas('{cluster}', system.replicas)
ORDER BY severity ASC, absolute_delay DESC
LIMIT 200;
