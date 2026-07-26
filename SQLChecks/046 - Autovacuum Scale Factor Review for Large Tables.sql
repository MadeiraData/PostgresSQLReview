
/* DESCRIPTION:
   What This Means: autovacuum scale factor settings may be too high for large
   tables. Large tables can require a very large number of row changes before
   autovacuum is triggered when scale-factor-based thresholds are used.

   WHY THIS MATTERS:
   On large tables, high autovacuum_vacuum_scale_factor or
   autovacuum_analyze_scale_factor values can delay vacuum and analyze activity.
   This may allow dead tuples to accumulate, increase table and index bloat,
   delay statistics refreshes, and contribute to poor query plans or wraparound
   pressure.

   Recommendations:
   Review large tables and consider table-level autovacuum settings using lower
   scale factors and/or fixed thresholds. Prioritize frequently updated large
   tables with high dead tuple counts or stale statistics.

   Scope : Cluster-level
   Category : Maintenance

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
   https://www.postgresql.org/docs/current/sql-altertable.html
   https://www.postgresql.org/docs/current/routine-vacuuming.html
*/

v_AdditionalInfo := (
    WITH table_autovacuum_settings AS (
        SELECT
            nsp.nspname AS schema_name,
            cls.relname AS table_name,
            cls.oid AS table_oid,
            pg_total_relation_size(cls.oid) AS table_size_bytes,
            COALESCE(st.n_live_tup, 0) AS estimated_live_rows,
            COALESCE(st.n_dead_tup, 0) AS estimated_dead_rows,
            st.last_autovacuum,
            st.last_autoanalyze,
            current_setting('autovacuum_vacuum_scale_factor')::numeric
                AS global_vacuum_scale_factor,
            current_setting('autovacuum_vacuum_threshold')::integer
                AS global_vacuum_threshold,
            current_setting('autovacuum_analyze_scale_factor')::numeric
                AS global_analyze_scale_factor,
            current_setting('autovacuum_analyze_threshold')::integer
                AS global_analyze_threshold,
            (
                SELECT option_value::numeric
                FROM pg_options_to_table(cls.reloptions)
                WHERE option_name = 'autovacuum_vacuum_scale_factor'
            ) AS table_vacuum_scale_factor,
            (
                SELECT option_value::integer
                FROM pg_options_to_table(cls.reloptions)
                WHERE option_name = 'autovacuum_vacuum_threshold'
            ) AS table_vacuum_threshold,
            (
                SELECT option_value::numeric
                FROM pg_options_to_table(cls.reloptions)
                WHERE option_name = 'autovacuum_analyze_scale_factor'
            ) AS table_analyze_scale_factor,
            (
                SELECT option_value::integer
                FROM pg_options_to_table(cls.reloptions)
                WHERE option_name = 'autovacuum_analyze_threshold'
            ) AS table_analyze_threshold
        FROM pg_class cls
        JOIN pg_namespace nsp
            ON nsp.oid = cls.relnamespace
        LEFT JOIN pg_stat_user_tables st
            ON st.relid = cls.oid
        WHERE cls.relkind IN ('r', 'p')
          AND nsp.nspname NOT IN ('pg_catalog', 'information_schema')
    ),
    calculated_thresholds AS (
        SELECT
            *,
            COALESCE(table_vacuum_scale_factor, global_vacuum_scale_factor)
                AS effective_vacuum_scale_factor,
            COALESCE(table_vacuum_threshold, global_vacuum_threshold)
                AS effective_vacuum_threshold,
            COALESCE(table_analyze_scale_factor, global_analyze_scale_factor)
                AS effective_analyze_scale_factor,
            COALESCE(table_analyze_threshold, global_analyze_threshold)
                AS effective_analyze_threshold
        FROM table_autovacuum_settings
    ),
    large_table_risks AS (
        SELECT
            *,
            (
                effective_vacuum_threshold
                + floor(effective_vacuum_scale_factor * estimated_live_rows)
            )::bigint AS estimated_vacuum_trigger_rows,
            (
                effective_analyze_threshold
                + floor(effective_analyze_scale_factor * estimated_live_rows)
            )::bigint AS estimated_analyze_trigger_rows
        FROM calculated_thresholds
        WHERE table_size_bytes >= 1073741824 -- 1 GB
          AND estimated_live_rows >= 1000000
          AND (
                effective_vacuum_scale_factor >= 0.10
             OR effective_analyze_scale_factor >= 0.05
          )
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM large_table_risks)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'LargeTablesWithHighAutovacuumScaleFactors',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'TableSizeBytes', table_size_bytes,
                        'EstimatedLiveRows', estimated_live_rows,
                        'EstimatedDeadRows', estimated_dead_rows,
                        'EffectiveVacuumScaleFactor', effective_vacuum_scale_factor,
                        'EffectiveVacuumThreshold', effective_vacuum_threshold,
                        'EstimatedVacuumTriggerRows', estimated_vacuum_trigger_rows,
                        'EffectiveAnalyzeScaleFactor', effective_analyze_scale_factor,
                        'EffectiveAnalyzeThreshold', effective_analyze_threshold,
                        'EstimatedAnalyzeTriggerRows', estimated_analyze_trigger_rows,
                        'LastAutovacuum', last_autovacuum,
                        'LastAutoanalyze', last_autoanalyze
                    )
                    ORDER BY table_size_bytes DESC
                )
                FROM large_table_risks
            ),
            'FindingReason',
            'One or more large tables have autovacuum or autoanalyze scale factors that may delay maintenance activity.'
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Large table autovacuum scale factors appear to be within the expected review range.'
        ELSE
            'Review large-table autovacuum settings and consider lower table-level scale factors or fixed thresholds for high-churn tables.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';