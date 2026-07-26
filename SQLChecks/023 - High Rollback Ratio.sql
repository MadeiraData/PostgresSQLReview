/*
    DESCRIPTION:
        What This Means: High rollback ratio detected in this database.

        A high rollback ratio means a significant percentage of transactions are
        being rolled back instead of committed. This can indicate application
        errors, failed transactions, deadlocks, lock timeouts, constraint violations,
        retry behavior, or inefficient transaction handling.

    Recommendations:
        Review application logs and PostgreSQL logs for transaction errors.
        Investigate deadlocks, lock timeouts, statement timeouts, constraint
        violations, and application retry patterns.
        If the rollback volume is expected, document the reason and validate that
        it does not create unnecessary load.

    Scope : Database-level
    Category : Performance

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
        https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-VIEW
*/

/* ============================================================
   CHECK: High Rollback Ratio
   ============================================================ */

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'This database has a high rollback ratio.',
                'ThresholdRollbackPercent', 10,
                'MinimumTransactionCount', 1000,
                'Databases',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'DatabaseName', datname,
                        'Commits', xact_commit,
                        'Rollbacks', xact_rollback,
                        'TotalTransactions', xact_commit + xact_rollback,
                        'RollbackPercent',
                            ROUND
                            (
                                xact_rollback::numeric
                                / NULLIF(xact_commit + xact_rollback, 0) * 100,
                                2
                            ),
                        'StatsReset', stats_reset
                    )
                    ORDER BY
                        ROUND
                        (
                            xact_rollback::numeric
                            / NULLIF(xact_commit + xact_rollback, 0) * 100,
                            2
                        ) DESC
                )
            )
        END
    FROM pg_stat_database
    WHERE datname = current_database()
      AND xact_commit + xact_rollback >= 1000
      AND
      (
          xact_rollback::numeric
          / NULLIF(xact_commit + xact_rollback, 0) * 100
      ) > 10
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
    'Transactions',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Rollback ratio is within the expected range.'
        ELSE
            'Investigate application errors, failed transactions, deadlocks, timeouts, constraint violations, and retry behavior causing frequent rollbacks.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';