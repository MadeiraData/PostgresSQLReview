
/*
    DESCRIPTION:
        What This Means: One or more databases have a high transaction ID age
        and may be approaching transaction ID wraparound.

        PostgreSQL uses transaction IDs (XIDs) that are limited in size.
        If freezing does not occur regularly through VACUUM or autovacuum,
        old XIDs can eventually approach wraparound, which may force
        emergency maintenance and can ultimately prevent writes.

    Recommendations:
        Identify tables with high relfrozenxid age in the affected databases.
        Ensure autovacuum is functioning correctly and not being blocked by
        long-running transactions.
        Consider running VACUUM (FREEZE) on affected tables during a maintenance window.

    Scope : Database-level
    Category : Maintenance

    More info:
        https://www.postgresql.org/docs/current/routine-vacuuming.html
        https://www.postgresql.org/docs/current/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND
        https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
*/

/* ============================================================
   CHECK: Databases Approaching Transaction ID Wraparound
   ============================================================ */

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more databases have a high transaction ID age and may be approaching wraparound risk.',
                'ThresholdXidAge', 1000000000,
                'AutovacuumFreezeMaxAge',
                    current_setting('autovacuum_freeze_max_age', true),
                'Databases',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'DatabaseName', datname,
                        'XidAge', age(datfrozenxid),
                        'DatFrozenXid', datfrozenxid,
                        'AllowConnections', datallowconn,
                        'IsTemplate', datistemplate
                    )
                    ORDER BY age(datfrozenxid) DESC
                )
            )
        END
    FROM pg_database
    WHERE datallowconn = true
      AND age(datfrozenxid) > 1000000000
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
    'Maintenance',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No databases approaching transaction ID wraparound risk were detected.'
        ELSE
            'Identify the oldest tables in the affected databases and run VACUUM FREEZE or allow aggressive autovacuum to complete. Review autovacuum freeze settings and long-running transactions that may prevent cleanup.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';