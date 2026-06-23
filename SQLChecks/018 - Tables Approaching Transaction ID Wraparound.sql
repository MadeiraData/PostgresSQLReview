/* ============================================================
   CHECK: Tables Approaching Transaction ID Wraparound
   ============================================================ */

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more tables have a high transaction ID age and may be approaching wraparound risk.',
                'ThresholdXidAge', 1000000000,
                'AutovacuumFreezeMaxAge',
                    current_setting('autovacuum_freeze_max_age', true),
                'Tables',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'SchemaName', n.nspname,
                        'TableName', c.relname,
                        'RelationKind', c.relkind,
                        'XidAge', age(c.relfrozenxid),
                        'RelFrozenXid', c.relfrozenxid,
                        'TableSize', pg_size_pretty(pg_total_relation_size(c.oid)),
                        'LastVacuum', s.last_vacuum,
                        'LastAutovacuum', s.last_autovacuum,
                        'VacuumCount', s.vacuum_count,
                        'AutovacuumCount', s.autovacuum_count
                    )
                    ORDER BY age(c.relfrozenxid) DESC
                )
            )
        END
    FROM pg_class c
    JOIN pg_namespace n
        ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s
        ON s.relid = c.oid
    WHERE c.relkind IN ('r', 'm', 't')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND age(c.relfrozenxid) > 1000000000
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
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No tables approaching transaction ID wraparound risk were detected.'
        ELSE
            'Run VACUUM FREEZE or allow aggressive autovacuum to complete on the affected tables. Review autovacuum freeze settings and investigate why freezing is not keeping up.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';