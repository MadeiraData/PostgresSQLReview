/*
    DESCRIPTION:
        Observability: Database statistics reset time is recent.

        PostgreSQL cumulative statistics in pg_stat_database can be reset manually
        using pg_stat_reset() or by certain operational actions. A recent reset can
        make performance, activity, temporary file usage, transaction, block I/O,
        and cache hit ratio metrics incomplete or misleading.

    Remediation:
        Confirm whether the statistics reset was expected.
        If the reset was planned, treat current cumulative statistics as partial
        since the reset time.
        If the reset was unexpected, investigate who or what reset the statistics
        and review monitoring or maintenance automation.

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
        https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-VIEW
*/

/* ============================================================
   CHECK: Database Statistics Reset Time is Recent
   ============================================================ */

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more databases have had statistics reset recently.',
                'Threshold', '24 hours',
                'Databases',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'DatabaseName', datname,
                        'StatsReset', stats_reset,
                        'StatsAge', now() - stats_reset,
                        'NumBackends', numbackends,
                        'XactCommit', xact_commit,
                        'XactRollback', xact_rollback,
                        'TempFiles', temp_files,
                        'TempBytes', temp_bytes,
                        'Deadlocks', deadlocks
                    )
                    ORDER BY stats_reset DESC
                )
            )
        END
    FROM pg_stat_database
    WHERE stats_reset IS NOT NULL
      AND stats_reset > now() - interval '24 hours'
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
    'Observability',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Database statistics reset time is not recent.'
        ELSE
            'Confirm whether the statistics reset was expected. Treat cumulative pg_stat_database metrics as partial since the reset time.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';