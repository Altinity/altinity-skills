---
name: altinity-expert-clickhouse-schema
description: Diagnoses ClickHouse table design - partitioning, ORDER BY and primary key, column count, Nullable usage, identifier length and materialized view structure. Use for schema anti-patterns, too many partitions, oversized partitions, bad sort keys and materialized view design problems.
license: Apache-2.0
---

# Table schema and design analysis

Answers "is this table designed the way ClickHouse wants it" from `system.parts`, `system.tables`, `system.columns`, `system.parts_columns`, `system.data_skipping_indices` and `system.merge_tree_settings`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 10 checks: partition health audit, oversized partitions on collapsing engines, primary key analysis, column count, Nullable column audit, over-long table and column names, materialized view design issues, materialized view dependency chains, a table overview and the table-level MergeTree settings that shape all of the above.
- `reference.md` — background (settings, sizing, anti-patterns); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Deep-dive statements

Partition distribution for one table, to judge whether the partition key is too granular.

```sql
SELECT
    partition,
    count() AS parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS partition_size
FROM clusterAllReplicas('{cluster}', system.parts)
WHERE active AND database = '{database}' AND table = '{table}'
GROUP BY partition
ORDER BY partition DESC
LIMIT 100;
```

Column compression for one table, to find columns whose type or codec is wrong.

```sql
SELECT
    name, type, compression_codec,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / nullIf(sum(data_compressed_bytes), 0), 2) AS ratio
FROM clusterAllReplicas('{cluster}', system.columns)
WHERE database = '{database}' AND table = '{table}'
GROUP BY name, type, compression_codec
ORDER BY sum(data_compressed_bytes) DESC
LIMIT 50;
```

Data skipping indexes declared across one database.

```sql
SELECT database, table, name AS index_name, type, expr, granularity
FROM clusterAllReplicas('{cluster}', system.data_skipping_indices)
WHERE database = '{database}'
ORDER BY database, table;
```

## Interpretation rules

- ORDER BY guideline: first column low cardinality and frequently filtered (tenant, region, type); second column time-based when range queries are common; remaining filter columns by selectivity, most selective last. A UUID or hash as the first column is an anti-pattern, and so is a `DateTime64` with microsecond precision first, because every row gets its own value and the sparse index cannot prune.
- Partition granularity rule of thumb: aim for tens to a few hundred partitions per table, each in the 1-10 GB range. Daily partitioning is justified only above roughly 1 TB per month; below that, monthly or no partitioning is usually correct. Check schema-01 grades this; quote its median partition size as the evidence.
- Oversized partitions (schema-02) matter only for Replacing, Collapsing, Summing, Aggregating and Graphite engines. A partition larger than `max_bytes_to_merge_at_max_space_in_pool` can never merge into one part, so deduplication or aggregation never completes. The fix is a finer partition key, not a bigger pool.
- Compression ratio below 2 for a large column means the type or the codec is wrong. Repetitive strings should become `LowCardinality(String)`; sequential integers and timestamps benefit from `Delta` or `DoubleDelta` before `ZSTD`.
- Check schema-03 is Minor by design: it only flags a first key column that looks like an ID, has a wide type, or compresses poorly. Confirm against real query filters first, because changing ORDER BY means rebuilding the table.
- Check schema-07 emits an `issue` column instead of `severity`. A JOIN in a materialized view fires only on the left table's inserts, so the right side silently goes stale. A materialized view without `TO` owns a hidden `.inner` table that cannot be altered or backed up independently.
- Checks schema-09 and schema-10 return context, not findings. Use them to explain other results; do not list their rows as problems.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Many small partitions caused by small or frequent inserts → load skill `altinity-expert-clickhouse-ingestion`
- Oversized partitions, merge backlog, or many parts per partition → load skill `altinity-expert-clickhouse-merges`
- Wide primary key consuming RAM, or high mark cache pressure → load skill `altinity-expert-clickhouse-memory`
- Queries scanning far more rows than they return with this ORDER BY → load skill `altinity-expert-clickhouse-index-analysis`
- Materialized view slow at query time → load skill `altinity-expert-clickhouse-reporting`
- Schema changes issued as ALTER UPDATE or ALTER DELETE and stuck → load skill `altinity-expert-clickhouse-mutations`
