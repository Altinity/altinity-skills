# Reference: mutation background

Background for the mutations skill. Read only when you need to explain a recommendation.

## Mutation anti-patterns

| Anti-pattern | Problem | Better approach |
|---|---|---|
| Frequent small ALTER UPDATE | One mutation per statement, each rewriting matching parts | Batch updates into one mutation, or model updates as inserts into a ReplacingMergeTree |
| ALTER DELETE without WHERE, or matching most rows | Full table rewrite | TTL, or DROP PARTITION |
| UPDATE on a high-cardinality column | Touches nearly every part, heavy IO | Restructure the data model so the value is inserted, not updated |
| Many concurrent mutations | Queue builds, merges starve | Serialize mutations, one at a time |
| Mutating a column in the ORDER BY key | Not allowed for key columns; fails or requires a rebuild | Rebuild the table with the intended key |

## Settings that govern mutations

| Setting | Notes |
|---|---|
| `mutations_sync` | 0 asynchronous, 1 wait for the current replica, 2 wait for all replicas. |
| `max_mutations_in_flight` | Upper bound on concurrently executing mutations. |
| `number_of_mutations_to_delay` | Pending mutations above this slow incoming INSERTs. |
| `number_of_mutations_to_throw` | Pending mutations above this reject INSERTs outright. |
| `background_pool_size` | Shared by merges and mutations; mutations compete with merges for it. |
| `lightweight_deletes_sync` | Applies to lightweight DELETE, which marks rows instead of rewriting parts immediately. |

## Monitoring thresholds

| Signal | Threshold worth alerting on |
|---|---|
| Pending mutations per table | more than 10 |
| Oldest unfinished mutation age | more than 1 hour |
| `latest_fail_reason` | any non-empty value |
