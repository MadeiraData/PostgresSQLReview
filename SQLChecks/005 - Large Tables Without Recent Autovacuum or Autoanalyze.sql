/*
    DESCRIPTION:
        What This Means: large tables do not show recent autovacuum or autoanalyze activity.
        Missing maintenance activity can lead to stale statistics and poor query plans.

    Recommendations:
        Review autovacuum configuration and table-level storage parameters.
        Confirm whether manual maintenance or recent statistics reset explains the result.

    Scope : Database-level
    Category : Maintenance

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
        https://www.postgresql.org/docs/current/planner-stats.html
*/

v_AdditionalInfo :=
(
    WITH candidate_tables AS
    (
        SELECT
            schemaname AS SchemaName,
            relname AS TableName,
            n_live_tup AS LiveTuples,
            last_autovacuum AS LastAutovacuum,
            last_autoanalyze AS LastAutoanalyze,
            autovacuum_count AS AutovacuumCount,
            autoanalyze_count AS AutoanalyzeCount
        FROM pg_stat_user_tables
        WHERE n_live_tup > 100000
          AND
          (
              last_autovacuum IS NULL
              OR last_autoanalyze IS NULL
          )
        ORDER BY n_live_tup DESC
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
                        'MinimumLiveTuples', 100000
                    ),
                    'Tables',
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', SchemaName,
                            'TableName', TableName,
                            'LiveTuples', LiveTuples,
                            'LastAutovacuum', LastAutovacuum,
                            'LastAutoanalyze', LastAutoanalyze,
                            'AutovacuumCount', AutovacuumCount,
                            'AutoanalyzeCount', AutoanalyzeCount
                        )
                        ORDER BY LiveTuples DESC
                    )
                )
        END
    FROM candidate_tables
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
    'Maintenance',
    'Object-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No large tables without recent autovacuum or autoanalyze activity were detected.'
        ELSE
            'Review autovacuum and autoanalyze activity for large tables. Missing or stale statistics can lead to poor execution plans.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';

