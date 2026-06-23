/* DESCRIPTION:
   Maintenance: autovacuum_naptime may not be appropriate for the workload.
   A large autovacuum_naptime increases the time between autovacuum launcher
   cycles, potentially delaying vacuum and analyze activity.

   WHY THIS MATTERS:
   If autovacuum checks tables too infrequently, dead tuples and stale
   statistics can accumulate before maintenance is triggered. This can lead
   to table bloat, index bloat, suboptimal query plans, and increased
   maintenance pressure on busy systems.

   REMEDIATION:
   Review autovacuum_naptime together with table churn, autovacuum worker
   capacity, dead tuple growth, and maintenance activity. Consider reducing
   autovacuum_naptime if vacuum and analyze operations are not keeping pace
   with workload changes.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
   https://www.postgresql.org/docs/current/routine-vacuuming.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN pg_size_bytes(current_setting('autovacuum_naptime')) <= 300000 -- 5 minutes
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'AutovacuumNaptime',
                current_setting('autovacuum_naptime', true),
            'AutovacuumMaxWorkers',
                current_setting('autovacuum_max_workers', true),
            'AutovacuumVacuumCostLimit',
                current_setting('autovacuum_vacuum_cost_limit', true),
            'AutovacuumVacuumCostDelay',
                current_setting('autovacuum_vacuum_cost_delay', true),
            'FindingReason',
                'autovacuum_naptime is configured above 5 minutes, which may delay autovacuum responsiveness on busy systems.'
        )
    END
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
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'autovacuum_naptime appears to be within the expected range.'
        ELSE
            'Review autovacuum_naptime and consider reducing it if autovacuum is not reacting quickly enough to workload changes.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';