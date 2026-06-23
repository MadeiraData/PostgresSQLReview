/* DESCRIPTION:
   Observability: log_lock_waits is disabled. PostgreSQL is not configured to
   log sessions that wait longer than deadlock_timeout while trying to acquire
   a lock.

   WHY THIS MATTERS:
   Lock waits can cause application slowdowns, blocked sessions, transaction
   pileups, and operational incidents. Without lock-wait logging, it is harder
   to identify blocking patterns, problematic transactions, migration issues,
   and queries that hold locks for too long.

   REMEDIATION:
   Enable log_lock_waits to improve visibility into lock contention. Review
   deadlock_timeout as well, because it controls how long PostgreSQL waits
   before logging lock waits when log_lock_waits is enabled.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-logging.html
   https://www.postgresql.org/docs/current/runtime-config-locks.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('log_lock_waits', true) = 'on'
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'LogLockWaits',
                current_setting('log_lock_waits', true),
            'DeadlockTimeout',
                current_setting('deadlock_timeout', true),
            'FindingReason',
                'log_lock_waits is disabled, so PostgreSQL is not logging long lock waits.'
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
    'Observability',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'log_lock_waits is enabled.'
        ELSE
            'Enable log_lock_waits to improve visibility into lock contention and long lock waits.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';