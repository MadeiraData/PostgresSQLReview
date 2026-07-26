
/* DESCRIPTION:
   What This Means: autovacuum worker capacity may be too low for the workload.
   A low autovacuum_max_workers setting can limit how many tables PostgreSQL can
   vacuum or analyze concurrently.

   WHY THIS MATTERS:
   If autovacuum cannot keep up with table churn, dead tuples may accumulate,
   statistics may become stale, tables and indexes may bloat, and transaction ID
   wraparound risk may increase. This is especially important on databases with
   many large or frequently updated tables.

   Recommendations:
   Review autovacuum_max_workers together with autovacuum_naptime,
   autovacuum_vacuum_cost_limit, autovacuum_vacuum_cost_delay, table churn,
   dead tuple counts, and server resources. Consider increasing worker capacity
   when many tables regularly require vacuum or analyze work.

   Scope : Cluster-level
   Category : Maintenance

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
   https://www.postgresql.org/docs/current/routine-vacuuming.html
   https://www.postgresql.org/docs/current/monitoring-stats.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('autovacuum', true) = 'on'
         AND current_setting('autovacuum_max_workers', true)::integer >= 3
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'Autovacuum',
                current_setting('autovacuum', true),
            'AutovacuumMaxWorkers',
                current_setting('autovacuum_max_workers', true),
            'AutovacuumNaptime',
                current_setting('autovacuum_naptime', true),
            'AutovacuumVacuumCostLimit',
                current_setting('autovacuum_vacuum_cost_limit', true),
            'AutovacuumVacuumCostDelay',
                current_setting('autovacuum_vacuum_cost_delay', true),
            'FindingReason',
                CASE
                    WHEN current_setting('autovacuum', true) <> 'on'
                        THEN 'autovacuum is disabled, so worker capacity is not available.'
                    ELSE
                        'autovacuum_max_workers is below 3, which may limit autovacuum capacity on active systems.'
                END
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Autovacuum worker capacity appears to be within the expected baseline.'
        ELSE
            'Review autovacuum worker capacity and consider increasing autovacuum_max_workers if autovacuum is not keeping up with table churn.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';