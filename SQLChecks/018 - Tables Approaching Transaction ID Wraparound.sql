/*
    DESCRIPTION:

    What This Means: One or more tables have a transaction ID (XID) age above the
        1 billion threshold, meaning their oldest unfrozen XID (relfrozenxid) has
        aged far past the point where routine autovacuum should have frozen it.
        PostgreSQL uses 32-bit transaction IDs, which can only span about 2 billion
        transactions before they "wrap around". To prevent that, VACUUM freezes old
        rows so their XIDs no longer count toward age. If freezing fails to keep up,
        the age keeps climbing silently — there is no performance symptom — until
        PostgreSQL begins emitting mandatory-vacuum warnings, then forces the
        database into read-only mode and ultimately refuses new write transactions
        to avoid data corruption. A single lagging table (often a rarely-used or
        autovacuum-disabled table) sets the age for the whole database, so even one
        entry here is a genuine cluster-wide risk.

    Recommendations:
        Freeze the affected tables to advance relfrozenxid: run VACUUM (or VACUUM
        FREEZE) on them, prioritizing the oldest first, or let the anti-wraparound
        ("to prevent wraparound") autovacuum complete rather than cancelling it.
        Investigate why freezing fell behind — the usual culprits are long-running
        or idle-in-transaction sessions and stale replication slots that hold back
        the oldest xmin and block freezing, or autovacuum being disabled/too slow on
        specific tables; identify and clear these first, since VACUUM cannot freeze
        past them. Confirm autovacuum is enabled on all tables (including
        abandoned/test tables), review autovacuum_freeze_max_age and per-table
        autovacuum settings, and consider making autovacuum more aggressive
        (workers, cost delay) on high-write tables. Monitor age(relfrozenxid) and
        age(datfrozenxid) trends over time so intervention happens early rather
        than as an emergency.

    Scope : database-level
    Category : Maintenance

    More info:
        https://www.postgresql.org/docs/current/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND
        https://www.postgresql.org/docs/current/runtime-config-autovacuum.html#GUC-AUTOVACUUM-FREEZE-MAX-AGE
        https://www.postgresql.org/docs/current/sql-vacuum.html
*/

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