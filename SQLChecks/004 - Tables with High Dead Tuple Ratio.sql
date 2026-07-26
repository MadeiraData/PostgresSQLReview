/*
    DESCRIPTION:
        What This Means: tables have a high dead tuple ratio.
        This may indicate autovacuum is not keeping up or long transactions exist.

    Recommendations:
        Investigate autovacuum behavior, table churn, and long-running transactions.
        Do not use VACUUM FULL as the default remediation.

     Scope : Database-level
     Category : Maintenance

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
        https://www.postgresql.org/docs/current/routine-vacuuming.html
*/

v_AdditionalInfo :=
(
    WITH candidate_tables AS
    (
        SELECT
            schemaname AS SchemaName,
            relname AS TableName,
            n_live_tup AS LiveTuples,
            n_dead_tup AS DeadTuples,
            round((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 2) AS DeadTuplePercent,
            last_autovacuum AS LastAutovacuum,
            last_autoanalyze AS LastAutoanalyze
        FROM pg_stat_user_tables
        WHERE n_live_tup > 10000
          AND n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) > 0.20
        ORDER BY n_dead_tup DESC
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
                        'MinimumLiveTuples', 10000,
                        'DeadTupleRatioPercent', 20
                    ),
                    'Tables',
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', SchemaName,
                            'TableName', TableName,
                            'LiveTuples', LiveTuples,
                            'DeadTuples', DeadTuples,
                            'DeadTuplePercent', DeadTuplePercent,
                            'LastAutovacuum', LastAutovacuum,
                            'LastAutoanalyze', LastAutoanalyze
                        )
                        ORDER BY DeadTuples DESC
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No tables with high dead tuple ratio were detected.'
        ELSE
            'Investigate autovacuum behavior and table churn. Consider regular VACUUM, autovacuum tuning, REINDEX CONCURRENTLY, pg_repack, or planned maintenance options.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';

