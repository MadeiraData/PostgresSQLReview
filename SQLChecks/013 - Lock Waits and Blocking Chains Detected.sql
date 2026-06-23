/* ============================================================
   CHECK: Lock Waits and Blocking Chains Detected
   ============================================================ */


v_AdditionalInfo :=
(
    WITH blocked_sessions AS
    (
        SELECT
            blocked.pid AS blocked_pid,
            blocked.usename AS blocked_user,
            blocked.datname AS blocked_database,
            blocked.application_name AS blocked_application,
            blocked.client_addr AS blocked_client_addr,
            blocked.state AS blocked_state,
            blocked.wait_event_type,
            blocked.wait_event,
            now() - blocked.query_start AS blocked_query_age,
            left(blocked.query, 500) AS blocked_query,
            blocker.pid AS blocker_pid,
            blocker.usename AS blocker_user,
            blocker.datname AS blocker_database,
            blocker.application_name AS blocker_application,
            blocker.client_addr AS blocker_client_addr,
            blocker.state AS blocker_state,
            now() - blocker.query_start AS blocker_query_age,
            now() - blocker.xact_start AS blocker_transaction_age,
            left(blocker.query, 500) AS blocker_query
        FROM pg_stat_activity blocked
        JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blocking_pid ON true
        JOIN pg_stat_activity blocker ON blocker.pid = blocking_pid
        WHERE blocked.wait_event_type = 'Lock'
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more sessions are waiting on locks and have blocking sessions.',
                'BlockedSessionCount', COUNT(*),
                'BlockingChains',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'BlockedPid', blocked_pid,
                        'BlockedUser', blocked_user,
                        'BlockedDatabase', blocked_database,
                        'BlockedApplication', blocked_application,
                        'BlockedClientAddress', blocked_client_addr,
                        'BlockedState', blocked_state,
                        'WaitEventType', wait_event_type,
                        'WaitEvent', wait_event,
                        'BlockedQueryAge', blocked_query_age,
                        'BlockedQuery', blocked_query,
                        'BlockerPid', blocker_pid,
                        'BlockerUser', blocker_user,
                        'BlockerDatabase', blocker_database,
                        'BlockerApplication', blocker_application,
                        'BlockerClientAddress', blocker_client_addr,
                        'BlockerState', blocker_state,
                        'BlockerQueryAge', blocker_query_age,
                        'BlockerTransactionAge', blocker_transaction_age,
                        'BlockerQuery', blocker_query
                    )
                    ORDER BY blocked_query_age DESC
                )
            )
        END
    FROM blocked_sessions
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No current lock waits or blocking chains were detected.'
        ELSE
            'Investigate blocking sessions, long transactions, application locking behavior, and missing indexes that may increase lock duration.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';