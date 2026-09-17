/* Part log checks (cluster-wide by default)
   Usage:
   - Replace `{cluster}` with your ClickHouse cluster name (DataGrip).
   - Run statements one-by-one for MCP mode.
*/

/* 0) Sanity: do we have part_log data? */
-- @check part-log-01 Part log checks (cluster-wide by default)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  min(event_time) AS min_event_time,
  max(event_time) AS max_event_time,
  count() AS rows
FROM clusterAllReplicas('{cluster}', system.part_log)
GROUP BY host
ORDER BY host;

/* 1) Part activity timeline (last 6h): spikes by minute and event_type */
-- @check part-log-02 Part activity timeline (last 6h): spikes by minute and event_type
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  toStartOfMinute(event_time) AS minute,
  event_type,
  count() AS events,
  sum(rows) AS rows_sum,
  sum(size_in_bytes) AS bytes_sum
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 6 HOUR
GROUP BY host, minute, event_type
ORDER BY minute DESC, events DESC, host ASC
LIMIT 500;

/* 2) Too many parts / micro-batching: NewPart rate by table (last 1h)
   Heuristics:
   - parts_per_min > 60  => >1 part/sec (high)
   - avg_rows_per_part < 10k or avg_part_size < 1MB => micro-batches (merge pressure)
*/
-- @check part-log-03 Too many parts / micro-batching: NewPart rate by table (last 1h)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  database,
  table,
  toStartOfMinute(event_time) AS minute,
  count() AS parts_per_min,
  round(avg(rows)) AS avg_rows_per_part,
  formatReadableSize(avg(size_in_bytes)) AS avg_part_size
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 1 HOUR
  AND event_type = 'NewPart'
GROUP BY host, database, table, minute
ORDER BY parts_per_min DESC, host ASC
LIMIT 100;

/* 3) Merge balance: are merges keeping up? (last 1h)
   Interpretation:
   - new_parts >> merges => increasing part count / merge backlog risk
*/
-- @check part-log-04 Merge balance: are merges keeping up? (last 1h)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  database,
  table,
  countIf(event_type = 'NewPart') AS new_parts,
  countIf(event_type = 'MergeParts') AS merges,
  (merges - new_parts) AS net_reduction,
  round(merges / nullIf(new_parts, 0), 3) AS merges_per_newpart
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 1 HOUR
GROUP BY host, database, table
HAVING new_parts > 20
ORDER BY new_parts DESC, host ASC
LIMIT 100;

/* 4) Slow merges: duration distribution (last 6h) */
-- @check part-log-05 Slow merges: duration distribution (last 6h)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  database,
  table,
  count() AS merge_events,
  round(avg(duration_ms)) AS avg_ms,
  round(quantile(0.5)(duration_ms)) AS p50_ms,
  round(quantile(0.95)(duration_ms)) AS p95_ms,
  round(max(duration_ms)) AS max_ms,
  formatReadableSize(sum(size_in_bytes)) AS bytes_sum
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 6 HOUR
  AND event_type = 'MergeParts'
GROUP BY host, database, table
HAVING merge_events > 10
ORDER BY p95_ms DESC, host ASC
LIMIT 100;

/* 5) Mutation storms: MutatePart rate by table (last 6h)
   Interpretation:
   - high mutate_parts_per_min => ALTER UPDATE/DELETE touching many parts
*/
-- @check part-log-06 Mutation storms: MutatePart rate by table (last 6h)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  database,
  table,
  toStartOfMinute(event_time) AS minute,
  count() AS mutate_parts_per_min,
  formatReadableSize(sum(size_in_bytes)) AS bytes_sum
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 6 HOUR
  AND event_type = 'MutatePart'
GROUP BY host, database, table, minute
ORDER BY mutate_parts_per_min DESC, host ASC
LIMIT 200;

/* 6) Mutation backlog: outstanding mutations (cluster-wide use: load mutations skill)
   Note: schema varies by version; keep this query minimal.
*/
-- @check part-log-07 Mutation backlog: outstanding mutations (cluster-wide use: load mutations skill)
SELECT
  hostName() AS host,
  database,
  table,
  countIf(is_done = 0) AS not_done,
  max(create_time) AS newest_create_time,
  max(parts_to_do) AS max_parts_to_do
FROM clusterAllReplicas('{cluster}', system.mutations)
GROUP BY host, database, table
HAVING not_done > 0
ORDER BY max_parts_to_do DESC, host ASC
LIMIT 100;

/* 7) Replication churn: DownloadPart spikes (last 6h)
   Interpretation:
   - bursts of DownloadPart can indicate replica restarts, lag catch-up, network/disk issues, or part loss.
*/
-- @check part-log-08 Replication churn: DownloadPart spikes (last 6h)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  database,
  table,
  toStartOfMinute(event_time) AS minute,
  count() AS downloads_per_min,
  formatReadableSize(sum(size_in_bytes)) AS bytes_sum
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 6 HOUR
  AND event_type = 'DownloadPart'
GROUP BY host, database, table, minute
ORDER BY downloads_per_min DESC, host ASC
LIMIT 200;

/* 8) RemovePart spikes (last 6h)
   Interpretation:
   - could be TTL cleanup, DROP/DETACH PARTITION, mutation cleanup, or unexpected data loss; investigate top tables.
*/
-- @check part-log-09 RemovePart spikes (last 6h)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  database,
  table,
  toStartOfMinute(event_time) AS minute,
  count() AS removes_per_min,
  formatReadableSize(sum(size_in_bytes)) AS bytes_sum
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 6 HOUR
  AND event_type = 'RemovePart'
GROUP BY host, database, table, minute
ORDER BY removes_per_min DESC, host ASC
LIMIT 200;

/* 9) MovePart spikes (last 6h)
   Interpretation:
   - can indicate storage policy movement, disk rebalancing, or manual moves.
*/
-- @check part-log-10 MovePart spikes (last 6h)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  database,
  table,
  toStartOfMinute(event_time) AS minute,
  count() AS moves_per_min,
  any(disk_name) AS any_disk_name
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 6 HOUR
  AND event_type = 'MovePart'
GROUP BY host, database, table, minute
ORDER BY moves_per_min DESC, host ASC
LIMIT 200;

/* 10) Part-log errors: merges/mutations failing (last 24h) */
-- @check part-log-11 Part-log errors: merges/mutations failing (last 24h)
-- @requires table:system.part_log
SELECT
  hostName() AS host,
  event_type,
  database,
  table,
  error,
  count() AS events,
  substring(anyLast(exception), 1, 240) AS exception_240,
  max(event_time) AS last_time
FROM clusterAllReplicas('{cluster}', system.part_log)
WHERE event_time > now() - INTERVAL 24 HOUR
  AND error != 0
GROUP BY host, event_type, database, table, error
ORDER BY events DESC, last_time DESC, host ASC
LIMIT 200;
