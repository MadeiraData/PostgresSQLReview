/* ============================================================
   CHECK: Long Running Transactions
   ============================================================ */

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