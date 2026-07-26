/*
    DESCRIPTION:

    What This Means: autovacuum cost-based throttling may be too aggressive
        (autovacuum_vacuum_cost_delay is set above the modern default of 2 ms).
        Autovacuum sleeps after accumulating a set amount of I/O "cost"; a higher
        cost delay throttles its throughput, so on write-active clusters dead
        tuples, table/index bloat, and transaction-id age can accumulate faster
        than autovacuum can clean them up, degrading performance and raising
        wraparound risk.

    Recommendations:
        Review whether the elevated autovacuum_vacuum_cost_delay is intentional.
        The modern PostgreSQL default is 2 ms. Consider lowering it toward the
        default and/or raising autovacuum_vacuum_cost_limit, together with
        autovacuum worker capacity and available I/O headroom. This is a
        cluster-wide, reloadable change (takes effect via pg_reload_conf, no
        restart) and should be validated against the workload.

    Scope : Cluster-level
    Category : Maintenance

    More info:
        https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
        https://www.postgresql.org/docs/current/runtime-config-resource.html#RUNTIME-CONFIG-RESOURCE-VACUUM-COST
        https://www.postgresql.org/docs/current/routine-vacuuming.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN s.cost_delay_ms <= 2
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'autovacuum_vacuum_cost_delay is configured above the modern default of 2 ms, which throttles autovacuum I/O throughput and can allow dead tuples and bloat to accumulate on write-active clusters.',
            'Thresholds', jsonb_build_object(
                'RecommendedMaxCostDelayMs', 2,
                'ModernDefaultCostDelayMs', 2
            ),
            'AutovacuumVacuumCostDelayMs', s.cost_delay_ms,
            'AutovacuumVacuumCostLimit', s.av_cost_limit_raw,
            'EffectiveVacuumCostLimit',
                CASE WHEN s.av_cost_limit_raw = -1 THEN s.base_cost_limit ELSE s.av_cost_limit_raw END,
            'AutovacuumMaxWorkers', s.max_workers
        )
    END
    FROM (
        SELECT
            (SELECT setting::numeric FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_delay') AS cost_delay_ms,
            (SELECT setting::integer FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_limit') AS av_cost_limit_raw,
            (SELECT setting::integer FROM pg_settings WHERE name = 'vacuum_cost_limit')            AS base_cost_limit,
            (SELECT setting::integer FROM pg_settings WHERE name = 'autovacuum_max_workers')       AS max_workers
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
    'Maintenance',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,                                                          -- Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'autovacuum_vacuum_cost_delay is at or below the modern default of 2 ms; autovacuum cost-based throttling does not appear overly aggressive.'
        ELSE
            'According to PostgreSQL operational best practices, review whether the elevated autovacuum_vacuum_cost_delay is intentional. The modern default is 2 ms; higher values throttle autovacuum throughput. Consider lowering it toward the default and/or raising autovacuum_vacuum_cost_limit alongside autovacuum worker capacity and I/O headroom. This is a cluster-wide, reloadable change (no restart required) and should be validated against the workload.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';