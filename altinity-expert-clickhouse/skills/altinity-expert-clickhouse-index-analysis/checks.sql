-- =============================================================================
-- INDEX EFFECTIVENESS ANALYSIS CHECKS
-- =============================================================================
-- Run these queries to assess whether indexes match actual query patterns
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. TABLES WITH SKIPPING INDEXES
-- -----------------------------------------------------------------------------
-- Lists all data skipping indexes across all tables
-- @check index-analysis-01 INDEX EFFECTIVENESS ANALYSIS CHECKS
SELECT
    database,
    table,
    name AS index_name,
    type AS index_type,
    expr AS indexed_expression,
    granularity,
    formatReadableSize(data_compressed_bytes) AS index_size,
    formatReadableSize(data_uncompressed_bytes) AS index_uncompressed
FROM system.data_skipping_indices
ORDER BY database, table, name;

-- -----------------------------------------------------------------------------
-- 2. TABLES WITH PROJECTIONS
-- -----------------------------------------------------------------------------
-- Lists all projections and their ORDER BY keys
-- @requires table:system.projections
-- @check index-analysis-02 TABLES WITH PROJECTIONS
SELECT
    database,
    table,
    name AS projection_name,
    sorting_key,
    type
FROM system.projections
ORDER BY database, table, name;

-- -----------------------------------------------------------------------------
-- 3. TOP TABLES BY QUERY FREQUENCY (LAST 24H)
-- -----------------------------------------------------------------------------
-- Identifies most queried tables to prioritize index analysis
-- @check index-analysis-03 TOP TABLES BY QUERY FREQUENCY (LAST 24H)
SELECT
    arrayJoin(tables) AS table_name,
    count() AS query_count,
    round(avg(query_duration_ms)) AS avg_duration_ms,
    round(avg(read_rows)) AS avg_rows_read,
    formatReadableSize(avg(read_bytes)) AS avg_bytes_read,
    round(avg(ProfileEvents['SelectedMarks'])) AS avg_marks_selected,
    round(avg(ProfileEvents['SelectedMarksTotal'])) AS avg_marks_total,
    round(100.0 * sum(ProfileEvents['SelectedMarks']) / nullIf(sum(ProfileEvents['SelectedMarksTotal']), 0), 1) AS pct_marks_selected
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
  AND query ILIKE 'SELECT%'
  AND type = 'QueryFinish'
GROUP BY table_name
ORDER BY query_count DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 4. QUERIES WITH POOR GRANULE SELECTIVITY (LAST 24H)
-- -----------------------------------------------------------------------------
-- Finds queries that read many granules relative to result size
-- Many selected marks with few result rows = index not effective.
-- Per-query mark/part counts live in ProfileEvents (SelectedMarks, SelectedParts),
-- with SelectedMarksTotal / SelectedPartsTotal as the denominators.
-- @check index-analysis-04 QUERIES WITH POOR GRANULE SELECTIVITY (LAST 24H)
SELECT
    normalized_query_hash,
    any(query) AS sample_query,
    count() AS executions,
    round(avg(ProfileEvents['SelectedMarks'])) AS avg_marks,
    round(avg(ProfileEvents['SelectedParts'])) AS avg_parts,
    round(100.0 * sum(ProfileEvents['SelectedMarks']) / nullIf(sum(ProfileEvents['SelectedMarksTotal']), 0), 1) AS pct_marks_selected,
    round(avg(read_rows)) AS avg_rows_read,
    round(avg(result_rows)) AS avg_result_rows,
    round(avg(read_rows) / nullIf(avg(result_rows), 0), 1) AS read_amplification,
    round(avg(query_duration_ms)) AS avg_duration_ms
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
  AND query ILIKE 'SELECT%'
  AND type = 'QueryFinish'
  AND result_rows > 0
GROUP BY normalized_query_hash
HAVING avg_marks > 1000 AND read_amplification > 100
ORDER BY avg_marks DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 5. FREQUENTLY FILTERED COLUMNS (LAST 24H)
-- -----------------------------------------------------------------------------
-- Extracts columns used in WHERE clauses to compare against ORDER BY keys
-- @check index-analysis-05 FREQUENTLY FILTERED COLUMNS (LAST 24H)
WITH
    arrayJoin(extractAll(query, '\\b(?:PRE)?WHERE\\s+(.*?)\\s+(?:GROUP BY|ORDER BY|UNION|SETTINGS|FORMAT|$)')) AS w,
    arrayFilter(x -> (position(lower(w), lower(extract(x, '\\.(`[^`]+`|[^\\.]+)$'))) > 0), columns) AS c,
    arrayJoin(c) AS filtered_column
SELECT
    filtered_column,
    count() AS filter_count
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
  AND query ILIKE 'SELECT%'
  AND type = 'QueryFinish'
  AND length(columns) > 0
GROUP BY filtered_column
ORDER BY filter_count DESC
LIMIT 30;

-- -----------------------------------------------------------------------------
-- 6. PRIMARY KEY COLUMN ANALYSIS
-- -----------------------------------------------------------------------------
-- Shows ORDER BY keys (from system.tables) with part/PK-memory aggregates (from system.parts)
-- @check index-analysis-06 PRIMARY KEY COLUMN ANALYSIS
SELECT
    t.database,
    t.table,
    t.sorting_key,
    t.primary_key,
    t.partition_key,
    t.sampling_key,
    formatReadableSize(p.pk_memory) AS pk_memory,
    p.total_rows,
    p.parts,
    round(p.total_rows / nullIf(p.parts, 0) / 8192, 1) AS avg_granules_per_part
FROM
(
    SELECT database, name AS table, sorting_key, primary_key, partition_key, sampling_key
    FROM system.tables
    WHERE engine LIKE '%MergeTree%'
) AS t
INNER JOIN
(
    SELECT
        database,
        table,
        sum(primary_key_bytes_in_memory) AS pk_memory,
        sum(rows) AS total_rows,
        count() AS parts
    FROM system.parts
    WHERE active
    GROUP BY database, table
) AS p ON p.database = t.database AND p.table = t.table
ORDER BY p.total_rows DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 7. SKIP INDEX EFFECTIVENESS ESTIMATE
-- -----------------------------------------------------------------------------
-- Compares index size to column size - oversized indexes may not be helpful
-- @check index-analysis-07 SKIP INDEX EFFECTIVENESS ESTIMATE
SELECT
    dsi.database,
    dsi.table,
    dsi.name AS index_name,
    dsi.type AS index_type,
    dsi.expr,
    formatReadableSize(dsi.data_compressed_bytes) AS index_size,
    c.name AS column_name,
    formatReadableSize(c.data_compressed_bytes) AS column_size,
    round(dsi.data_compressed_bytes / nullIf(c.data_compressed_bytes, 0) * 100, 1) AS index_to_column_pct
FROM system.data_skipping_indices AS dsi
LEFT JOIN system.columns AS c 
    ON dsi.database = c.database 
    AND dsi.table = c.table 
    AND dsi.expr = c.name
WHERE dsi.data_compressed_bytes > 0
ORDER BY dsi.data_compressed_bytes DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 8. QUERIES THAT BYPASS PRIMARY KEY (LAST 24H)
-- -----------------------------------------------------------------------------
-- Finds queries that don't use primary key filtering effectively
-- @check index-analysis-08 QUERIES THAT BYPASS PRIMARY KEY (LAST 24H)
SELECT
    normalized_query_hash,
    any(query) AS sample_query,
    count() AS executions,
    arrayJoin(tables) AS table_name,
    round(avg(ProfileEvents['SelectedParts'])) AS avg_parts,
    round(avg(ProfileEvents['SelectedMarks'])) AS avg_marks,
    round(100.0 * sum(ProfileEvents['SelectedMarks']) / nullIf(sum(ProfileEvents['SelectedMarksTotal']), 0), 1) AS pct_marks_selected,
    round(avg(read_rows)) AS avg_read_rows,
    formatReadableSize(avg(read_bytes)) AS avg_read_bytes
FROM system.query_log
WHERE event_time >= now() - INTERVAL 1 DAY
  AND query ILIKE 'SELECT%'
  AND type = 'QueryFinish'
  AND ProfileEvents['SelectedMarksTotal'] > 10000
GROUP BY normalized_query_hash, table_name
ORDER BY avg_marks DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 9. PARTITION PRUNING EFFECTIVENESS
-- -----------------------------------------------------------------------------
-- Shows how well queries prune partitions
-- @check index-analysis-09 PARTITION PRUNING EFFECTIVENESS
SELECT
    q.table_name,
    q.query_count,
    q.avg_selected_parts,
    p.total_active_parts,
    round(q.avg_selected_parts / nullIf(p.total_active_parts, 0) * 100, 1) AS pct_parts_scanned
FROM
(
    SELECT
        arrayJoin(tables) AS table_name,
        count() AS query_count,
        round(avg(ProfileEvents['SelectedParts'])) AS avg_selected_parts
    FROM system.query_log
    WHERE event_time >= now() - INTERVAL 1 DAY
      AND query ILIKE 'SELECT%'
      AND type = 'QueryFinish'
    GROUP BY table_name
) AS q
INNER JOIN
(
    SELECT concat(database, '.', table) AS table_name, count() AS total_active_parts
    FROM system.parts
    WHERE active
    GROUP BY table_name
    HAVING total_active_parts > 10
) AS p ON p.table_name = q.table_name
ORDER BY pct_parts_scanned DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 10. WHERE CONDITION PATTERNS BY TABLE (LAST 3 DAYS)
-- -----------------------------------------------------------------------------
-- Shows normalized WHERE patterns to understand common filter combinations
-- @check index-analysis-10 WHERE CONDITION PATTERNS BY TABLE (LAST 3 DAYS)
WITH
    arrayJoin(extractAll(normalizeQuery(query), '\\b(?:PRE)?WHERE\\s+(.*?)\\s+(?:GROUP BY|ORDER BY|UNION|SETTINGS|FORMAT|$)')) AS where_pattern
SELECT
    arrayJoin(tables) AS table_name,
    where_pattern,
    count() AS frequency
FROM system.query_log
WHERE event_time >= now() - INTERVAL 3 DAY
  AND query ILIKE 'SELECT%'
  AND type = 'QueryFinish'
GROUP BY table_name, where_pattern
ORDER BY table_name, frequency DESC
LIMIT 50;
