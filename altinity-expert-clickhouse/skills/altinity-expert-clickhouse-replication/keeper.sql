/* 1) Keeper/ZooKeeper average latency (per host)
Interpretation:
- Rising avg_latency_us often correlates with replication lag/readonly.
*/
-- @check replication-keeper-01 Keeper/ZooKeeper average latency (per host)
WITH
  sumIf(value, event = 'ZooKeeperWaitMicroseconds') AS total_us,
  sumIf(value, event = 'ZooKeeperTransactions') AS transactions
SELECT
  hostName() AS host,
  total_us,
  transactions,
  round(total_us / nullIf(transactions, 0)) AS avg_latency_us
FROM clusterAllReplicas('{cluster}', system.events)
WHERE event IN ('ZooKeeperWaitMicroseconds', 'ZooKeeperTransactions')
GROUP BY host
ORDER BY avg_latency_us DESC
SETTINGS system_events_show_zero_values = 1;

-- Recent Keeper/ZooKeeper errors and warnings from text_log (last 24h)
-- @requires table:system.text_log
-- @check replication-keeper-02 Recent Keeper/ZooKeeper errors and warnings from text_log (last 24h)
SELECT
  hostName() AS host,
  event_time,
  level,
  logger_name,
  substring(message, 1, 260) AS message_260
FROM clusterAllReplicas('{cluster}', system.text_log)
WHERE (logger_name ILIKE '%ZooKeeper%' OR logger_name ILIKE '%Keeper%')
  AND level IN ('Error', 'Warning')
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY event_time DESC
LIMIT 200;

