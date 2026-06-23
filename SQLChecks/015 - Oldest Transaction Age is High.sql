
/* ============================================================
   CHECK: Oldest Transaction Age is High
   ============================================================ */

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
