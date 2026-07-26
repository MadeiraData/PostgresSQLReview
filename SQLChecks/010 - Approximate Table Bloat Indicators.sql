/*
    DESCRIPTION:
        What This Means: large tables show possible bloat indicators.
        This is an approximate signal based on PostgreSQL statistics, not exact bloat measurement.

    Recommendations:
        Investigate autovacuum behavior, table churn, and long transactions.
        Consider VACUUM, REINDEX CONCURRENTLY, pg_repack, or planned maintenance options.

    Scope : Database-level
    Category : Performance

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
        https://www.postgresql.org/docs/current/routine-vacuuming.html
*/

v_AdditionalInfo :=
(
    WITH candidate_tables AS
    (
        SELECT
            s.schemaname AS SchemaName,
            s.relname AS TableName,
            s.n_live_tup AS EstimatedLiveTuples,
            s.n_dead_tup AS EstimatedDeadTuples,
            round
            (
                s.n_dead_tup::numeric
                / NULLIF(s.n_live_tup + s.n_dead_tup, 0)
                * 100,
                2
            ) AS EstimatedDeadTuplePercent,
            pg_total_relation_size(c.oid) AS TotalSizeBytes,
            pg_size_pretty(pg_total_relation_size(c.oid)) AS TotalSize,
            s.last_vacuum AS LastVacuum,
            s.last_autovacuum AS LastAutovacuum,
            s.last_analyze AS LastAnalyze,
            s.last_autoanalyze AS LastAutoAnalyze,
            s.vacuum_count AS VacuumCount,
            s.autovacuum_count AS AutovacuumCount
        FROM pg_stat_user_tables s
        JOIN pg_class c
            ON c.oid = s.relid
        WHERE pg_total_relation_size(c.oid) > 1073741824
          AND s.n_live_tup > 10000
          AND s.n_dead_tup::numeric / NULLIF(s.n_live_tup + s.n_dead_tup, 0) > 0.10
        ORDER BY
            pg_total_relation_size(c.oid) DESC,
            s.n_dead_tup DESC
        LIMIT 50
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'ImportantNote', 'This is an approximate bloat indicator based on PostgreSQL statistics, not exact bloat measurement.',
                    'Thresholds',
                    jsonb_build_object
                    (
                        'MinimumTableSizeBytes', 1073741824,
                        'MinimumTableSize', '1 GB',
                        'MinimumEstimatedLiveTuples', 10000,
                        'EstimatedDeadTuplePercentThreshold', 10
                    ),
                    'Tables',
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', SchemaName,
                            'TableName', TableName,
                            'TotalSize', TotalSize,
                            'TotalSizeBytes', TotalSizeBytes,
                            'EstimatedLiveTuples', EstimatedLiveTuples,
                            'EstimatedDeadTuples', EstimatedDeadTuples,
                            'EstimatedDeadTuplePercent', EstimatedDeadTuplePercent,
                            'LastVacuum', LastVacuum,
                            'LastAutovacuum', LastAutovacuum,
                            'LastAnalyze', LastAnalyze,
                            'LastAutoAnalyze', LastAutoAnalyze,
                            'VacuumCount', VacuumCount,
                            'AutovacuumCount', AutovacuumCount
                        )
                        ORDER BY TotalSizeBytes DESC
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
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No large tables with approximate bloat indicators were detected.'
        ELSE
            'Investigate possible table bloat indicators. Review autovacuum behavior, table churn, and long-running transactions. Do not use VACUUM FULL as the default remediation.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';

