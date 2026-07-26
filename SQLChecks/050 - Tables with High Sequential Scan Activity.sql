
/* DESCRIPTION:
   What This Means: tables with high sequential scan activity were found. These
   tables are being scanned sequentially frequently, which may indicate missing
   indexes, inefficient query predicates, reporting workloads, or normal access
   patterns for small tables.

   WHY THIS MATTERS:
   Frequent sequential scans on large or frequently accessed tables can increase
   I/O, CPU usage, buffer churn, and query latency. High sequential scan activity
   should be reviewed together with table size, rows read, index usage, and query
   patterns before deciding whether indexing or query tuning is required.

   Recommendations:
   Review tables with high sequential scan activity. Use pg_stat_statements,
   execution plans, and application query patterns to identify whether indexes,
   query rewrites, partitioning, or statistics improvements are needed. Do not
   add indexes automatically, especially for small tables or intentional
   reporting scans.

   Scope : Database-level
   Category : Performance

   REFERENCES:
   https://www.postgresql.org/docs/current/monitoring-stats.html
   https://www.postgresql.org/docs/current/indexes.html
   https://www.postgresql.org/docs/current/using-explain.html
*/

v_AdditionalInfo := (
    WITH table_scan_activity AS (
        SELECT
            schemaname AS schema_name,
            relname AS table_name,
            relid AS table_oid,
            pg_total_relation_size(relid) AS table_size_bytes,
            COALESCE(n_live_tup, 0) AS estimated_live_rows,
            COALESCE(seq_scan, 0) AS sequential_scans,
            COALESCE(seq_tup_read, 0) AS sequential_rows_read,
            COALESCE(idx_scan, 0) AS index_scans,
            CASE
                WHEN (COALESCE(seq_scan, 0) + COALESCE(idx_scan, 0)) > 0
                    THEN round(
                        COALESCE(seq_scan, 0)::numeric
                        / (COALESCE(seq_scan, 0) + COALESCE(idx_scan, 0))::numeric,
                        4
                    )
                ELSE NULL
            END AS sequential_scan_ratio
        FROM pg_stat_user_tables
    ),
    high_seq_scan_tables AS (
        SELECT *
        FROM table_scan_activity
        WHERE table_size_bytes >= 104857600 -- 100 MB
          AND (
                sequential_scans >= 1000
             OR sequential_rows_read >= 10000000
             OR (
                    sequential_scan_ratio >= 0.80
                AND sequential_scans >= 100
                )
          )
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM high_seq_scan_tables)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'TablesWithHighSequentialScanActivity',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'TableSizeBytes', table_size_bytes,
                        'EstimatedLiveRows', estimated_live_rows,
                        'SequentialScans', sequential_scans,
                        'SequentialRowsRead', sequential_rows_read,
                        'IndexScans', index_scans,
                        'SequentialScanRatio', sequential_scan_ratio
                    )
                    ORDER BY sequential_rows_read DESC
                )
                FROM high_seq_scan_tables
            ),
            'FindingReason',
            'One or more user tables have high sequential scan activity according to pg_stat_user_tables.'
        )
    END
);

INSERT INTO pg_review_results (
    CheckId,
    Title,
    Category,
    Scope,
    RequiresAttention,
    WorstCaseImpact,
    CurrentStateImpact,
    RecommendationEffort,
    RecommendationRisk,
    Recommendation,
    AdditionalInfo,
    ResponsibleDbaTeam
)
SELECT
    v_CheckId,
    v_CheckTitle,
    'Performance',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No large user tables exceeded the sequential scan activity review thresholds.'
        ELSE
            'Review high sequential scan tables using pg_stat_statements and execution plans before adding or changing indexes.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';