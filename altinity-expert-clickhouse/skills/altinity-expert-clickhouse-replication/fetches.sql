/* 1) Active fetches (per host)
Interpretation:
- Many long-running fetches or repeated fetch errors can drive lag.
*/
-- @check replication-fetches-01 Active fetches (per host)
SELECT
  hostName() AS host,
  database,
  table,
  elapsed,
  progress,
  formatReadableSize(total_size_bytes_compressed) AS size,
  result_part_name
FROM clusterAllReplicas('{cluster}', system.replicated_fetches)
ORDER BY elapsed DESC
LIMIT 200;

/* 2) Recent fetch activity (DownloadPart) in part_log (per host) */
-- @requires table:system.part_log
-- @check replication-fetches-02 Recent fetch activity (DownloadPart) in part_log (per host)
SELECT
  hostName() AS host,
  event_time,
  database,
  table,
  part_name,
  duration_ms,
  formatReadableSize(size_in_bytes) AS size,
  error
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_type = 'DownloadPart'
  AND event_date >= today() - 1
ORDER BY event_time DESC
LIMIT 200;

