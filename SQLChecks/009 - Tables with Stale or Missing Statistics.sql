
/*
    DESCRIPTION:
        Statistics: tables have stale or missing planner statistics.
        Stale statistics can lead to poor query plans and unstable performance.

    Remediation:
        Review autovacuum/analyze behavior and recent table changes.
        Run ANALYZE where appropriate and tune autovacuum if this repeats.

    More info:
        https://www.postgresql.org/docs/current/planner-stats.html
        https://www.postgresql.org/docs/current/routine-vacuuming.html
*/

v_AdditionalInfo :=
(
    WITH stale_statistics AS
    (
        SELECT
            schemaname AS SchemaName,
            relname AS TableName,
            n_live_tup AS EstimatedLiveRows,
            n_mod_since_analyze AS RowsModifiedSinceAnalyze,
            last_analyze AS LastAnalyze,
            last_autoanalyze AS LastAutoAnalyze,
            COALESCE(last_analyze, last_autoanalyze) AS LastStatisticsUpdate
        FROM pg_stat_user_tables
        WHERE n_live_tup > 1000
          AND
          (
              COALESCE(last_analyze, last_autoanalyze) < now() - interval '7 days'
              OR
              (
                  last_analyze IS NULL
                  AND last_autoanalyze IS NULL
                  AND n_mod_since_analyze > 0
              )
          )
        ORDER BY
            LastStatisticsUpdate NULLS FIRST,
            n_mod_since_analyze DESC
        LIMIT 50
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'Thresholds',
                    jsonb_build_object
                    (
                        'MinimumEstimatedLiveRows', 1000,
                        'StatisticsAgeThreshold', '7 days'
                    ),
                    'Tables',
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', SchemaName,
                            'TableName', TableName,
                            'EstimatedLiveRows', EstimatedLiveRows,
                            'RowsModifiedSinceAnalyze', RowsModifiedSinceAnalyze,
                            'LastAnalyze', LastAnalyze,
                            'LastAutoAnalyze', LastAutoAnalyze,
                            'LastStatisticsUpdate', LastStatisticsUpdate
                        )
                        ORDER BY LastStatisticsUpdate NULLS FIRST
                    )
                )
        END
    FROM stale_statistics
);

INSERT INTO pg_review_results
(
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
    'Statistics',
    'Object-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No relevant tables with stale or missing statistics were detected.'
        ELSE
            'Review stale or missing table statistics. Run ANALYZE where appropriate and investigate whether autovacuum/autoanalyze is keeping up with table changes.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';

