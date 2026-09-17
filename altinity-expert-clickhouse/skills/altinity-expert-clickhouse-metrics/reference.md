# Metrics reference

Background for the metrics skill. Read only when a recommendation needs to be explained.

## Where the numbers come from

| Table | Contents | Notes |
|-------|----------|-------|
| `system.metrics` | Current gauges | Instantaneous values such as `Query`, `TCPConnection`, `BackgroundMergesAndMutationsPoolTask`. |
| `system.events` | Cumulative counters | Reset on restart. Always read together with uptime. |
| `system.asynchronous_metrics` | Host and server metrics, refreshed on a timer | Load average, memory, disk and block device metrics live here. |
| `system.metric_log` | One row per second with every metric and event as a column | Source for short-history query and event rates. |
| `system.asynchronous_metric_log` | History of asynchronous metrics | Source for memory and load trends. |

From version 26.8 several per-device and per-core asynchronous metrics moved from one metric name per device into a `key_values` map on a single metric. That is why metrics-02 and metrics-10 ship two variants.

## Key metrics to alert on

| Metric | Warning | Critical |
|--------|---------|----------|
| `ReadonlyReplica` | any sustained | above 0 for more than a few minutes |
| `Query` | above 75 percent of `max_concurrent_queries` | above 90 percent |
| `MemoryResident` | above 80 percent of RAM | above 90 percent |
| `MaxPartCountForPartition` | above `parts_to_delay_insert` | above `parts_to_throw_insert` |
| `ReplicasMaxAbsoluteDelay` | above 5 minutes | above 1 hour |
| `LoadAverage1` | above CPU core count | above twice the core count |
| `BlockInFlightOps` | above 128 | above 200 |

## Prometheus export

ClickHouse exposes these metrics in Prometheus format when the `prometheus` block is present in the server config, by default on port 9363 at `/metrics`. Without it, historical analysis is limited to `system.metric_log` and `system.asynchronous_metric_log`, whose retention is usually days rather than months.

## Related limits

| Setting | Scope | Notes |
|---------|-------|-------|
| `max_concurrent_queries` | Server | Queries above this are rejected with TOO_MANY_SIMULTANEOUS_QUERIES. |
| `max_connections` | Server | TCP and HTTP connection ceiling. |
| `background_pool_size` | Server | Merge and mutation worker count; saturation here throttles merges. |
| `parts_to_delay_insert` | Table | Inserts start sleeping past this part count. |
| `parts_to_throw_insert` | Table | Inserts fail past this part count. |
