
/* DESCRIPTION:
   What This Means: large tables have not been analyzed recently. This may indicate
   stale planner statistics on important tables.

   WHY THIS MATTERS:
   PostgreSQL relies on table statistics to choose efficient query plans. If
   large tables are not analyzed regularly, the planner may make poor estimates,
   choose inefficient joins or scans, and cause query performance regressions.

   Recommendations:
   Review large tables with no recent analyze activity. Confirm that autovacuum
   and autoanalyze are enabled and keeping up. Consider running ANALYZE manually
   for affected tables and tuning table-level autovacuum analyze thresholds for
   high-change or large tables.

   Scope : Database-level
   Category : Performance

   REFERENCES:
   https://www.postgresql.org/docs/current/sql-analyze.html
   https://www.postgresql.org/docs/current/routine-vacuuming.html
   https://www.postgresql.org/docs/current/monitoring-stats.html
*/

v_AdditionalInfo := (
    WITH large_tables AS (
        SELECT
            nsp.nspname AS schema_name,
            cls.relname AS table_name,
            cls.oid AS table_oid,
            pg_total_relation_size(cls.oid) AS table_size_bytes,
            COALESCE(st.n_live_tup, 0) AS estimated_live_rows,
            COALESCE(st.n_mod_since_analyze, 0) AS rows_modified_since_analyze,
            st.last_analyze,
            st.last_autoanalyze,
            GREATEST(st.last_analyze, st.last_autoanalyze) AS last_analyze_activity
        FROM pg_class cls
        JOIN pg_namespace nsp
            ON nsp.oid = cls.relnamespace
        LEFT JOIN pg_stat_user_tables st
            ON st.relid = cls.oid
        WHERE cls.relkind IN ('r', 'p')
          AND nsp.nspname NOT IN ('pg_catalog', 'information_schema')
          AND pg_total_relation_size(cls.oid) >= 1073741824 -- 1 GB
    ),
    large_tables_without_recent_analyze AS (
        SELECT
            *
        FROM large_tables
        WHERE last_analyze_activity IS NULL
           OR last_analyze_activity < now() - interval '30 days'
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM large_tables_without_recent_analyze)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'LargeTablesWithNoRecentAnalyze',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'TableSizeBytes', table_size_bytes,
                        'EstimatedLiveRows', estimated_live_rows,
                        'RowsModifiedSinceAnalyze', rows_modified_since_analyze,
                        'LastAnalyze', last_analyze,
                        'LastAutoAnalyze', last_autoanalyze,
                        'LastAnalyzeActivity', last_analyze_activity
                    )
                    ORDER BY table_size_bytes DESC
                )
                FROM large_tables_without_recent_analyze
            ),
            'FindingReason',
            'One or more large tables have not been analyzed in the last 30 days or have no recorded analyze activity.'
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
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Large tables appear to have recent analyze activity.'
        ELSE
            'Review large tables without recent analyze activity. Run ANALYZE where needed and tune autoanalyze thresholds for important large tables.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';