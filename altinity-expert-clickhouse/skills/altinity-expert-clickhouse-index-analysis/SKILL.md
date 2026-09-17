---
name: altinity-expert-clickhouse-index-analysis
description: Analyze whether ClickHouse indexes (PRIMARY KEY, ORDER BY, skipping indexes, projections) are effective for the actual query patterns. Use when investigating index effectiveness, ORDER BY key design, query-to-index alignment, or when queries scan far more data than expected.
license: Apache-2.0
---

# Index effectiveness analysis

Answers "do the ORDER BY key, skipping indexes and projections match what the queries actually filter on?" from `system.data_skipping_indices`, `system.projections`, `system.tables`, `system.parts` and the `ProfileEvents` in `system.query_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 10 checks: skipping index inventory (index-analysis-01), projections and their ORDER BY keys (index-analysis-02, needs `system.projections`), top tables by query frequency (index-analysis-03), queries with poor granule selectivity (index-analysis-04), frequently filtered columns (index-analysis-05), primary key columns with part and PK-memory aggregates (index-analysis-06), skip index size versus column size (index-analysis-07), queries that bypass the primary key (index-analysis-08), partition pruning effectiveness (index-analysis-09), WHERE condition patterns per table (index-analysis-10).
- `reference.md` — background (ORDER BY design guidelines, anti-patterns, skipping index selection); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

Work in this order for each suspect table: read its keys and indexes (index-analysis-01, index-analysis-06, and `SHOW CREATE TABLE`), extract the columns the queries really filter on (index-analysis-05, index-analysis-10), measure the cardinalities of those columns, then judge alignment.

- `pct_marks_selected` close to 100 with high read amplification means the primary key is not filtering at all, whatever the ORDER BY looks like.
- Judge alignment per query pattern: filters on an ORDER BY prefix are already supported; filters on columns absent from the ORDER BY are candidates for a skipping index or a projection; a time range plus an entity filter needs the order checked, since time may belong in the partition key rather than first in the ORDER BY; a high-cardinality column first in the ORDER BY kills granule skipping and calls for a reorder.
- Order the ORDER BY columns from lowest to highest cardinality, and keep the columns that are actually filtered in the key. A time column usually belongs at reduced resolution such as `toDate(ts)`, unless the partition key already handles the time filtering.
- A skipping index helps only when the column is not in the ORDER BY prefix and its values correlate with the physical row order. On randomly distributed values it reads the index and then reads everything anyway, and on a column that is already an ORDER BY prefix it is pure redundancy.
- In index-analysis-07, `index_to_column_pct` near or above 100 means the index costs as much as the column it indexes; drop it unless it is proven to skip granules. The same economics apply to projections, which duplicate the data they cover: recommend one only when index-analysis-03 shows the pattern is frequent enough to pay for the storage and merge cost.
- Partition pruning (index-analysis-09) is a separate lever from the primary key. Poor pruning with a good ORDER BY points at the partition key or at queries filtering on a derived expression the pruner cannot use.
- In `EXPLAIN indexes = 1` output, a `PrimaryKey` condition of `true` means no filtering happened, the `Granules: X/Y` ratio is the real selectivity (lower X over Y is better), and a `Skip` step should reduce parts and granules further than the primary key alone did.

## Deep-dive statements

Cardinality of the candidate key columns. Pass `{columns}` as a comma-separated list; the lowest cardinality goes first in the ORDER BY.

```sql
SELECT {columns} APPLY uniq
FROM {database}.{table}
WHERE {time_column} > now() - INTERVAL {days} DAY;
```

Which columns of one table are actually filtered, ranked by usage.

```sql
WITH
    arrayJoin(extractAll(query, '\\b(?:PRE)?WHERE\\s+(.*?)\\s+(?:GROUP BY|ORDER BY|UNION|SETTINGS|FORMAT|$)')) AS w,
    arrayFilter(x -> (position(lower(w), lower(extract(x, '\\.(`[^`]+`|[^\\.]+)$'))) > 0), columns) AS c,
    arrayJoin(c) AS filtered_column
SELECT filtered_column, count() AS usage_count
FROM system.query_log
WHERE event_time >= now() - INTERVAL {days} DAY
  AND type = 'QueryFinish'
  AND query ILIKE 'SELECT%'
  AND arrayExists(x -> x LIKE '%{table}%', tables)
GROUP BY filtered_column
ORDER BY usage_count DESC
LIMIT 30;
```

Granule selectivity for the queries touching one table. `pct_marks_selected` is the share of the table's marks that were read.

```sql
SELECT
    normalized_query_hash,
    any(query) AS sample_query,
    round(avg(ProfileEvents['SelectedParts'])) AS avg_parts,
    round(avg(ProfileEvents['SelectedMarks'])) AS avg_marks,
    round(100.0 * sum(ProfileEvents['SelectedMarks']) / nullIf(sum(ProfileEvents['SelectedMarksTotal']), 0), 1) AS pct_marks_selected,
    round(avg(read_rows)) AS avg_read_rows,
    round(avg(query_duration_ms)) AS avg_duration_ms
FROM system.query_log
WHERE event_time >= now() - INTERVAL {days} DAY
  AND type = 'QueryFinish'
  AND query ILIKE 'SELECT%'
  AND arrayExists(x -> x LIKE '%{table}%', tables)
GROUP BY normalized_query_hash
ORDER BY avg_marks DESC
LIMIT 20;
```

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- The ORDER BY, partition key or materialized view chain needs redesign → load skill `altinity-expert-clickhouse-schema`
- Queries stay slow after the index work, or the cost is elsewhere in the plan → load skill `altinity-expert-clickhouse-reporting`
- Large primary key or mark cache memory, or poor cache hit rates → load skill `altinity-expert-clickhouse-memory`
- A new ORDER BY or projection would require rewriting existing data → load skill `altinity-expert-clickhouse-mutations`, and for the added merge cost `altinity-expert-clickhouse-merges`
