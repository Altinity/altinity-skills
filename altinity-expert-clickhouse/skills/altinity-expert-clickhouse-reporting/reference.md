# Reference: query execution settings

Background for the reporting skill. Read only when you need to explain a recommendation.

## Per-query limits and parallelism

| Setting | Scope | Notes |
|---|---|---|
| `max_execution_time` | query | Query timeout in seconds; a query killed by it appears as `ExceptionWhileProcessing`. |
| `max_rows_to_read` | query | Hard cap on rows scanned; pairs with `read_overflow_mode`. |
| `max_bytes_to_read` | query | Hard cap on bytes scanned. |
| `max_memory_usage` | query | Per-query memory cap; exceeding it gives MEMORY_LIMIT_EXCEEDED. |
| `max_threads` | query | Parallelism per query; raising it trades latency for CPU and memory. |
| `max_bytes_before_external_group_by` | query | Spills GROUP BY to disk instead of failing on memory. |
| `use_query_cache` | query | Serves repeated identical queries from the query result cache. |

## Query logging

| Setting | Scope | Notes |
|---|---|---|
| `log_queries` | server or user | Turns `system.query_log` on; without it this skill has no data. |
| `log_queries_min_query_duration_ms` | server or user | Queries faster than this are not logged, so short-but-frequent patterns can be invisible. |
| `log_query_views` | server or user | Turns `system.query_views_log` on, needed for the materialized-view checks. |
| `log_profile_events` | server or user | Populates `ProfileEvents`, needed for the marks and parts deep dive. |
