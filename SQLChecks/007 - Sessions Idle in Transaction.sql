/*
    DESCRIPTION:
        What This Means: sessions are idle while holding an open transaction.
        This can block vacuum cleanup, hold locks, and increase bloat risk.

    Recommendations:
        Review the application/session behavior and close transactions promptly.
        Consider idle_in_transaction_session_timeout after validating application impact.

    Scope : Database-level
    Category : Performance

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
        https://www.postgresql.org/docs/current/runtime-config-client.html
*/

v_AdditionalInfo :=
(
    WITH idle_transactions AS
    (
        SELECT
            pid AS ProcessId,
            usename AS UserName,
            datname AS DatabaseName,
            application_name AS ApplicationName,
            client_addr::text AS ClientAddress,
            state AS SessionState,
            xact_start AS TransactionStartTime,
            now() - xact_start AS TransactionDuration,
            wait_event_type AS WaitEventType,
            wait_event AS WaitEvent,
            left(query, 500) AS QuerySample
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND backend_type = 'client backend'
          AND state = 'idle in transaction'
          AND xact_start IS NOT NULL
          AND now() - xact_start > interval '5 minutes'
        ORDER BY xact_start ASC
        LIMIT 50
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'Threshold', '5 minutes',
                    'Sessions',
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'ProcessId', ProcessId,
                            'UserName', UserName,
                            'DatabaseName', DatabaseName,
                            'ApplicationName', ApplicationName,
                            'ClientAddress', ClientAddress,
                            'SessionState', SessionState,
                            'TransactionStartTime', TransactionStartTime,
                            'TransactionDuration', TransactionDuration,
                            'WaitEventType', WaitEventType,
                            'WaitEvent', WaitEvent,
                            'QuerySample', QuerySample
                        )
                        ORDER BY TransactionStartTime ASC
                    )
                )
        END
    FROM idle_transactions
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
    'Cluster/session-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No idle-in-transaction sessions above the threshold were detected.'
        ELSE
            'Investigate sessions that remain idle inside open transactions. Consider application fixes and a controlled idle_in_transaction_session_timeout configuration if appropriate.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production/Development';

