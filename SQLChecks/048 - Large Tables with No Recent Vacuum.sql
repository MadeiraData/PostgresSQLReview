/* DESCRIPTION:
   Maintenance: large tables have not been vacuumed recently. This may indicate
   that dead tuples are not being cleaned up regularly on important tables.

   WHY THIS MATTERS:
   PostgreSQL relies on VACUUM and autovacuum to reclaim dead tuples, reduce
   table and index bloat, maintain visibility map information, and reduce
   transaction ID wraparound risk. If large tables are not vacuumed regularly,
   performance and storage usage may degrade over time.

   REMEDIATION:
   Review large tables with no recent vacuum activity. Confirm that autovacuum
   is enabled and keeping up with table churn. Consider running VACUUM manually
   for affected tables and tuning table-level autovacuum thresholds for large
   or frequently updated tables.

   REFERENCES:
   https://www.postgresql.org/docs/current/sql-vacuum.html
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
            COALESCE(st.n_dead_tup, 0) AS estimated_dead_rows,
            st.last_vacuum,
            st.last_autovacuum,
            GREATEST(st.last_vacuum, st.last_autovacuum) AS last_vacuum_activity
        FROM pg_class cls
        JOIN pg_namespace nsp
            ON nsp.oid = cls.relnamespace
        LEFT JOIN pg_stat_user_tables st
            ON st.relid = cls.oid
        WHERE cls.relkind IN ('r', 'p')
          AND nsp.nspname NOT IN ('pg_catalog', 'information_schema')
          AND pg_total_relation_size(cls.oid) >= 1073741824 -- 1 GB
    ),
    large_tables_without_recent_vacuum AS (
        SELECT *
        FROM large_tables
        WHERE last_vacuum_activity IS NULL
           OR last_vacuum_activity < now() - interval '30 days'
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM large_tables_without_recent_vacuum)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'LargeTablesWithNoRecentVacuum',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'TableSizeBytes', table_size_bytes,
                        'EstimatedLiveRows', estimated_live_rows,
                        'EstimatedDeadRows', estimated_dead_rows,
                        'LastVacuum', last_vacuum,
                        'LastAutovacuum', last_autovacuum,
                        'LastVacuumActivity', last_vacuum_activity
                    )
                    ORDER BY table_size_bytes DESC
                )
                FROM large_tables_without_recent_vacuum
            ),
            'FindingReason',
            'One or more large tables have not been vacuumed in the last 30 days or have no recorded vacuum activity.'
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Large tables appear to have recent vacuum activity.'
        ELSE
            'Review large tables without recent vacuum activity. Run VACUUM where needed and tune autovacuum thresholds for important large or high-churn tables.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';