/*
    DESCRIPTION:

    What This Means: PostgreSQL connection usage is high (active connections are
        approaching max_connections). As usage nears the limit, the cluster risks
        rejecting new connections with "FATAL: too many connections", including
        the connections reserved for superuser/administrative tasks.

    Recommendations:
        Review application connection behavior, idle-in-transaction sessions, and
        long-lived idle connections. Introduce or tune a connection pooler
        (e.g. PgBouncer) so many client connections share a small pool of backend
        connections, rather than raising max_connections indiscriminately.
        Raising max_connections increases per-backend memory (work_mem, shared
        memory overhead) and should only be done after benchmarking and with
        adequate RAM headroom. Always keep superuser_reserved_connections
        available for administrative access.

    Scope : cluster-level
    Category : Connections

    More info:
        https://www.postgresql.org/docs/current/runtime-config-connection.html#GUC-MAX-CONNECTIONS
        https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW
        https://www.pgbouncer.org/config.html
*/

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN connection_usage_percent < 80 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'MaxConnections', max_connections,
                'ActiveConnections', active_connections,
                'ConnectionUsagePercent', connection_usage_percent,
                'ReservedSuperuserConnections', reserved_superuser_connections,
                'FindingReason', 'PostgreSQL connection usage is high.'
            )
        END
    FROM
    (
        SELECT
            current_setting('max_connections')::int AS max_connections,
            current_setting('superuser_reserved_connections')::int AS reserved_superuser_connections,
            COUNT(*)::int AS active_connections,
            ROUND
            (
                COUNT(*)::numeric
                / NULLIF(current_setting('max_connections')::numeric, 0) * 100,
                2
            ) AS connection_usage_percent
        FROM pg_stat_activity
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
    'Connections',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Connection usage is within the expected range.'
        ELSE
            'Review application connection behavior, connection pooling, idle sessions, and max_connections configuration.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
