/*
    DESCRIPTION:

    What This Means: idle_session_timeout is set to 0 (PostgreSQL's default), so
        a session that is connected but currently has no open transaction and is
        not running any statement -- a fully idle session -- is allowed to stay
        connected indefinitely. This is distinct from
        idle_in_transaction_session_timeout (see the separate check of that
        name), which only bounds idle time while a transaction is still open;
        this setting bounds ordinary idle connections holding no transaction at
        all.

    Every idle session still occupies one of the cluster's limited connection
        slots counted against max_connections (see the separate Connection
        Usage is High check) and keeps its backend process, session memory, and
        any session-level state (temporary tables, prepared statements,
        session-level SET values) allocated for as long as it sits idle.
        Application connection leaks, client processes that crashed or hung
        without closing their socket, or a connection pooler left holding
        backend connections open longer than the application actually needs
        them can accumulate unnoticed until the cluster unexpectedly runs out of
        connection slots -- which then rejects every new connection attempt
        cluster-wide, including from clients that never leaked anything.

    Recommendations:
        Configure idle_session_timeout to a value that reflects how long a
        genuinely idle application connection should be allowed to sit before
        PostgreSQL closes it, commonly tens of minutes for most OLTP workloads.
        Validate the chosen value against the connection pooler's own
        idle-connection handling first: PgBouncer, RDS Proxy, and similar
        poolers already manage idle backend connections on their own schedule,
        and an aggressive idle_session_timeout set behind one of them can race
        with the pooler and close connections the pooler still considers
        healthy, surfacing as unexpected "server closed the connection
        unexpectedly" errors in the application. Where a single cluster-wide
        value does not fit every workload, set it per-database or per-role with
        ALTER DATABASE / ALTER ROLE ... SET instead.

    Scope : Cluster-level
    Category : Configuration

    More info:
        https://www.postgresql.org/docs/current/runtime-config-client.html
        https://www.postgresql.org/docs/current/runtime-config-connection.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN s.idle_session_timeout_ms > 0
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'idle_session_timeout is set to 0 (disabled), so a session with no open transaction and no running statement can remain connected indefinitely, continuing to occupy a connection slot and its backend''s session memory.',
            'IdleSessionTimeoutMs', s.idle_session_timeout_ms
        )
    END
    FROM (
        SELECT
            (SELECT setting::bigint FROM pg_catalog.pg_settings WHERE name = 'idle_session_timeout') AS idle_session_timeout_ms
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
    'Configuration',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,                                                          -- Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'idle_session_timeout is configured; fully idle sessions do not remain connected indefinitely.'
        ELSE
            'Configure idle_session_timeout to a value appropriate for this workload so fully idle sessions release their connection slot instead of accumulating indefinitely. Validate the value against any connection pooler''s own idle-connection handling before applying it cluster-wide.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
