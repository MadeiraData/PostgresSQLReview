
/*
    DESCRIPTION:
        What This Means: Deadlocks were detected in one or more databases.

        A deadlock occurs when two or more sessions wait on each other in a cycle,
        and PostgreSQL resolves it by canceling one of the transactions. Deadlocks
        can indicate problematic transaction ordering, long-held locks, missing
        indexes, or application concurrency issues.

    Recommendations:
        Review PostgreSQL logs around the deadlock times for the full deadlock
        details and involved SQL statements.
        Investigate application transaction order, lock acquisition order, and
        queries that hold locks for a long time.
        Consider adding indexes or reducing transaction scope where appropriate.

    Scope : Database-level
    Category : Performance

    More info:
        https://www.postgresql.org/docs/current/explicit-locking.html
        https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-VIEW
*/

/* ============================================================
   CHECK: Deadlocks Detected
   ============================================================ */

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more databases report deadlocks in pg_stat_database.',
                'Databases',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'DatabaseName', datname,
                        'Deadlocks', deadlocks,
                        'StatsReset', stats_reset
                    )
                    ORDER BY deadlocks DESC
                )
            )
        END
    FROM pg_stat_database
    WHERE deadlocks > 0
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
    'Concurrency',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No deadlocks were reported in pg_stat_database.'
        ELSE
            'Review PostgreSQL logs for deadlock details and investigate transaction ordering, long-held locks, and application concurrency patterns.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';