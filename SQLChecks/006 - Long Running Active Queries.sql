
/*
    DESCRIPTION:
        Concurrency: active queries are running longer than the configured threshold.
        Long-running queries may consume resources and delay other workload.

    Remediation:
        Review query purpose, execution plan, wait events, and application behavior.
        Do not terminate sessions automatically without business validation.

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
*/

v_AdditionalInfo :=
(
    WITH long_running_queries AS
    (
        SELECT
            pid AS ProcessId,
            usename AS UserName,
            datname AS DatabaseName,
            application_name AS ApplicationName,
            client_addr::text AS ClientAddress,
            state AS SessionState,
            wait_event_type AS WaitEventType,
            wait_event AS WaitEvent,
            query_start AS QueryStartTime,
            now() - query_start AS QueryDuration,
            left(query, 500) AS QuerySample
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND backend_type = 'client backend'
          AND state = 'active'
          AND query_start IS NOT NULL
          AND now() - query_start > interval '30 minutes'
        ORDER BY query_start ASC
        LIMIT 50
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'Threshold', '30 minutes',
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
                            'WaitEventType', WaitEventType,
                            'WaitEvent', WaitEvent,
                            'QueryStartTime', QueryStartTime,
                            'QueryDuration', QueryDuration,
                            'QuerySample', QuerySample
                        )
                        ORDER BY QueryStartTime ASC
                    )
                )
        END
    FROM long_running_queries
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No long-running active queries above the threshold were detected.'
        ELSE
            'Review long-running active queries, their wait events, execution plans, and application context. Terminate sessions only after business validation.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production/Development';

