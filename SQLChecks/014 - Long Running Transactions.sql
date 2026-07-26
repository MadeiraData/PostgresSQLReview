/*
    DESCRIPTION:

    What This Means: One or more transactions have been open for a long time
        (over the 30-minute threshold). A transaction that stays open — whether
        actively running or sitting "idle in transaction" — holds its snapshot
        and any acquired locks for its entire lifetime. Because of MVCC, this
        prevents VACUUM/autovacuum from cleaning up dead tuples newer than the
        transaction's xmin, which drives table and index bloat, degrades query
        performance, consumes disk space, and holds back the cluster's oldest
        transaction ID. Left unchecked, this raises the risk of transaction ID
        (XID) wraparound, which can eventually force PostgreSQL to stop accepting
        new write commands.

    Recommendations:
        Identify the offending sessions and determine whether they are stuck,
        idle-in-transaction, or legitimately long-running. Work with application
        owners to commit or roll back these transactions; if necessary, cancel the
        statement with pg_cancel_backend(pid) or terminate the backend with
        pg_terminate_backend(pid). To prevent recurrence, set
        idle_in_transaction_session_timeout to bound idle-in-transaction sessions
        and statement_timeout to bound individual statement duration, keep
        transactions short, and avoid holding transactions open across
        application-side waits. Monitor age(backend_xmin) in pg_stat_activity to
        catch old snapshots before they threaten vacuum progress and wraparound
        safety.

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
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more transactions have been running for a long time.',
                'LongRunningTransactionThreshold', '30 minutes',
                'TransactionCount', COUNT(*),
                'Transactions',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'Pid', pid,
                        'UserName', usename,
                        'DatabaseName', datname,
                        'ApplicationName', application_name,
                        'ClientAddress', client_addr,
                        'State', state,
                        'TransactionStart', xact_start,
                        'TransactionAge', now() - xact_start,
                        'QueryStart', query_start,
                        'QueryAge', now() - query_start,
                        'WaitEventType', wait_event_type,
                        'WaitEvent', wait_event,
                        'Query', left(query, 500)
                    )
                    ORDER BY xact_start
                )
            )
        END
    FROM pg_stat_activity
    WHERE xact_start IS NOT NULL
      AND now() - xact_start > interval '30 minutes'
      AND pid <> pg_backend_pid()
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
            THEN 'No long running transactions were detected.'
        ELSE
            'Review long running transactions. They can hold locks, prevent vacuum cleanup, increase bloat, and affect transaction ID wraparound safety.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';