/* DESCRIPTION:
   Workload: tables with high INSERT, UPDATE, and DELETE activity were found.
   These tables experience significant write activity and may require closer
   maintenance, indexing, autovacuum, and bloat review.

   WHY THIS MATTERS:
   High write activity can generate dead tuples, increase WAL volume, create
   index maintenance overhead, trigger frequent autovacuum work, and contribute
   to table or index bloat. These tables are often the most important candidates
   for autovacuum tuning, index review, and performance monitoring.

   REMEDIATION:
   Review high-activity tables together with dead tuple counts, autovacuum
   history, table size, index count, query patterns, and application workload.
   Consider tuning table-level autovacuum settings, removing redundant indexes,
   and validating that write-heavy tables have appropriate maintenance capacity.

   REFERENCES:
   https://www.postgresql.org/docs/current/monitoring-stats.html
   https://www.postgresql.org/docs/current/routine-vacuuming.html
   https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
*/

v_AdditionalInfo := (
    WITH database_stats AS (
        SELECT
            datname,
            stats_reset
        FROM pg_stat_database
        WHERE datname = current_database()
    ),
    table_activity AS (
        SELECT
            schemaname AS schema_name,
            relname AS table_name,
            relid AS table_oid,
            pg_total_relation_size(relid) AS table_size_bytes,
            COALESCE(n_live_tup, 0) AS estimated_live_rows,
            COALESCE(n_dead_tup, 0) AS estimated_dead_rows,
            COALESCE(n_tup_ins, 0) AS rows_inserted,
            COALESCE(n_tup_upd, 0) AS rows_updated,
            COALESCE(n_tup_del, 0) AS rows_deleted,
            COALESCE(n_tup_hot_upd, 0) AS hot_rows_updated,
            (
                COALESCE(n_tup_ins, 0)
                + COALESCE(n_tup_upd, 0)
                + COALESCE(n_tup_del, 0)
            ) AS total_write_activity,
            last_vacuum,
            last_autovacuum,
            last_analyze,
            last_autoanalyze
        FROM pg_stat_user_tables
    ),
    high_activity_tables AS (
        SELECT
            ta.*,
            ds.stats_reset,
            CASE
                WHEN ta.estimated_live_rows > 0
                    THEN round(
                        (
                            ta.total_write_activity::numeric
                            / ta.estimated_live_rows::numeric
                        ),
                        2
                    )
                ELSE NULL
            END AS write_activity_to_live_rows_ratio
        FROM table_activity ta
        CROSS JOIN database_stats ds
        WHERE ta.total_write_activity >= 1000000
           OR (
                ta.estimated_live_rows >= 100000
            AND ta.total_write_activity >= ta.estimated_live_rows
           )
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM high_activity_tables)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'TablesWithHighInsertUpdateDeleteActivity',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'TableSizeBytes', table_size_bytes,
                        'EstimatedLiveRows', estimated_live_rows,
                        'EstimatedDeadRows', estimated_dead_rows,
                        'RowsInserted', rows_inserted,
                        'RowsUpdated', rows_updated,
                        'RowsDeleted', rows_deleted,
                        'HotRowsUpdated', hot_rows_updated,
                        'TotalWriteActivity', total_write_activity,
                        'WriteActivityToLiveRowsRatio', write_activity_to_live_rows_ratio,
                        'LastVacuum', last_vacuum,
                        'LastAutovacuum', last_autovacuum,
                        'LastAnalyze', last_analyze,
                        'LastAutoAnalyze', last_autoanalyze,
                        'StatsReset', stats_reset
                    )
                    ORDER BY total_write_activity DESC
                )
                FROM high_activity_tables
            ),
            'FindingReason',
            'One or more tables have high cumulative INSERT, UPDATE, and DELETE activity according to pg_stat_user_tables.'
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
    'Maintenance',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No tables exceeded the high INSERT, UPDATE, and DELETE activity review thresholds.'
        ELSE
            'Review high-write-activity tables for autovacuum tuning, bloat risk, redundant indexes, and maintenance capacity.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';