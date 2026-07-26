/*
    DESCRIPTION:

    What This Means: The single oldest open transaction in the cluster has been
        running longer than the 1-hour threshold. This check focuses on the age of
        the very oldest transaction because, under MVCC, it is the oldest open
        transaction's snapshot (its xmin) that sets the floor for what VACUUM and
        autovacuum are allowed to clean up. As long as one old transaction stays
        open — actively running or "idle in transaction" — dead tuples newer than
        its snapshot cannot be reclaimed anywhere it applies, which causes table
        and index bloat, wasted disk space, degraded query performance, retained
        locks, and a held-back cluster-wide oldest transaction ID that increases
        transaction ID (XID) wraparound risk.

    Recommendations:
        Investigate the oldest open transaction identified here and determine
        whether it is stuck, idle-in-transaction, or a legitimately long workload.
        Coordinate with the application owner to commit or roll it back; if needed,
        cancel the statement with pg_cancel_backend(pid) or terminate the backend
        with pg_terminate_backend(pid). To prevent recurrence, set
        idle_in_transaction_session_timeout and statement_timeout to bound session
        and statement duration, keep transactions short, and avoid holding a
        transaction open across application-side waits. Track age(backend_xmin) in
        pg_stat_activity so old snapshots are caught before they threaten vacuum
        progress and wraparound safety.

    Scope : database-level
    Category : Transactions

    More info:
        https://www.postgresql.org/docs/current/routine-vacuuming.html
        https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW
        https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-IDLE-IN-TRANSACTION-SESSION-TIMEOUT
*/

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN max_transaction_age < interval '1 hour' THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'The oldest open transaction age is high.',
                'Threshold', '1 hour',
                'OldestTransactionAge', max_transaction_age,
                'OldestTransactionStart', oldest_transaction_start,
                'Pid', pid,
                'UserName', usename,
                'DatabaseName', datname,
                'ApplicationName', application_name,
                'ClientAddress', client_addr,
                'State', state,
                'WaitEventType', wait_event_type,
                'WaitEvent', wait_event,
                'Query', left(query, 500)
            )
        END
    FROM
    (
        SELECT
            pid,
            usename,
            datname,
            application_name,
            client_addr,
            state,
            wait_event_type,
            wait_event,
            query,
            xact_start AS oldest_transaction_start,
            now() - xact_start AS max_transaction_age
        FROM pg_stat_activity
        WHERE xact_start IS NOT NULL
          AND pid <> pg_backend_pid()
        ORDER BY xact_start ASC
        LIMIT 1
    ) s
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
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Oldest open transaction age is within the expected range.'
        ELSE
            'Investigate the oldest open transaction. Long transactions can delay vacuum cleanup, increase bloat, hold locks, and increase transaction ID wraparound risk.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
