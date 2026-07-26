/*
    DESCRIPTION:

    What This Means: connection logging is disabled (log_connections is off), so
        successful and attempted connections are not recorded. log_connections logs
        authorized and attempted connections; log_disconnections logs session end
        and duration. Both are off by default. Without them there is no audit trail
        of who connected and when, which hampers security auditing (for example
        detecting brute-force authentication attempts), connection analysis, and
        correlating sessions with later log lines.

    Recommendations:
        Enable connection logging according to your security and audit policy. On
        PostgreSQL 18 log_connections accepts a list of aspects (for example
        'authentication' or 'all'); on earlier versions it is boolean. Consider also
        enabling log_disconnections to capture session duration. These are reloadable
        (no restart) but increase log volume, so size log storage/rotation
        accordingly. If connection logging is handled by an external layer
        (pgBouncer, a proxy, or the platform), confirm that before enabling it here.

    Scope : Cluster-level
    Category : Observability

    More info:
        https://www.postgresql.org/docs/current/runtime-config-logging.html
        https://www.enterprisedb.com/blog/how-get-best-out-postgresql-logs
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN lower(s.log_connections) NOT IN ('off', 'none', 'false', '0', 'no')
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'log_connections is disabled, so successful and attempted connections are not recorded. Connection/disconnection logging is important for security auditing and for correlating sessions in the logs.',
            'LogConnections', s.log_connections,
            'LogDisconnections', s.log_disconnections
        )
    END
    FROM (
        SELECT
            COALESCE(NULLIF(trim((SELECT setting FROM pg_settings WHERE name = 'log_connections')), ''), 'off') AS log_connections,
            (SELECT setting FROM pg_settings WHERE name = 'log_disconnections') AS log_disconnections
    ) s
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
    2,                                                          -- Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Connection logging is enabled (log_connections is set); connection activity is being recorded.'
        ELSE
            'According to PostgreSQL logging best practices, enable connection logging for security auditing and session correlation. Set log_connections (on PostgreSQL 18 it accepts a list of aspects such as ''all''; earlier versions are boolean) and consider log_disconnections for session duration. These are reloadable (no restart) but increase log volume, so plan log storage and rotation. If connection auditing is handled by an external proxy or platform layer, confirm that before enabling it at the server.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';