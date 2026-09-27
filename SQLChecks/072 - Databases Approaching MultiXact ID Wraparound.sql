/*
    DESCRIPTION:

    What This Means: One or more databases have a MultiXact ID age
        (mxid_age(datminmxid)) at or above half of
        autovacuum_multixact_freeze_max_age, capped at 1 billion. MultiXact IDs
        are a second, completely separate 32-bit counter from ordinary
        transaction IDs. PostgreSQL allocates a MultiXact ID whenever a single
        row has to record more than one locker at once - concurrent
        SELECT ... FOR SHARE / FOR KEY SHARE, the FOR KEY SHARE locks taken by
        foreign key checks on parent rows, a row locked and then updated by a
        subtransaction, and the implicit subtransactions created by SAVEPOINTs
        and by PL/pgSQL blocks with an EXCEPTION clause. Like transaction IDs,
        MultiXact IDs are only reclaimed by freezing during VACUUM, and like
        transaction IDs they wrap around: once the age of the oldest unfrozen
        MultiXact reaches roughly 2 billion, PostgreSQL refuses to allocate new
        MultiXact IDs and stops accepting the write transactions that would need
        one, exactly the same outage as transaction ID wraparound. The trap is
        that this counter is invisible to every transaction-ID check: a cluster
        can show a perfectly healthy age(datfrozenxid) and zero dead tuples
        while its MultiXact age climbs, because MultiXact consumption is driven
        by locking patterns rather than by row churn. Workloads that rely
        heavily on foreign keys, on row-level share locks, or on ORMs and
        drivers that wrap every statement in a savepoint can burn MultiXacts far
        faster than they burn transaction IDs. High MultiXact age also means the
        pg_multixact/offsets and pg_multixact/members SLRU areas keep growing,
        which consumes disk and produces LWLock:MultiXact* contention that
        degrades throughput long before the hard limit is reached. The good
        state is a cluster where routine and aggressive VACUUM freeze old
        MultiXacts continuously, so datminmxid keeps advancing and the age stays
        far below the point where PostgreSQL must force an anti-wraparound
        MultiXact VACUUM. Reaching half of autovacuum_multixact_freeze_max_age
        means freezing is already losing ground, and every day of normal traffic
        from that point shortens the runway to a hard, cluster-wide write
        outage.

    Recommendations:
        Identify the tables holding the oldest MultiXacts in the affected
        databases with
        SELECT c.oid::regclass, mxid_age(c.relminmxid) FROM pg_class c
        WHERE c.relkind IN ('r','m','t') AND c.relminmxid <> '0'::xid
        ORDER BY 2 DESC LIMIT 20;
        and freeze them with VACUUM (FREEZE), oldest first, or let a running
        anti-wraparound autovacuum finish rather than cancelling it.
        Investigate why freezing fell behind before tuning anything: long-running
        or idle-in-transaction sessions, abandoned prepared transactions, and
        inactive replication slots hold back the oldest xmin and stop VACUUM from
        advancing relminmxid at all, so they must be cleared first.
        Confirm autovacuum is enabled globally and on every table, including
        rarely-touched and abandoned ones, since a single unfrozen table sets
        datminmxid for its whole database.
        Reduce MultiXact consumption where the workload allows it: index foreign
        key columns so parent-row lock traffic is cheaper, avoid unnecessary
        SELECT ... FOR SHARE, and turn off driver or ORM options that wrap every
        statement in a savepoint (for example the JDBC autosave setting).
        For a database that reports allow_connections = false (typically
        template0), autovacuum still freezes it, but if its age keeps climbing it
        can be frozen manually after temporarily running
        ALTER DATABASE template0 ALLOW_CONNECTIONS true.
        Only after freezing is healthy again, consider lowering
        autovacuum_multixact_freeze_max_age from its 400 million default on
        clusters that consume MultiXacts quickly, so freezing is forced earlier
        and in smaller increments; note that this parameter requires a server
        restart. Monitor mxid_age(datminmxid) on the same dashboard as
        age(datfrozenxid) - they are two independent counters and the MultiXact
        one is usually the one nobody is watching.

    Scope : Cluster-level
    Category : Maintenance

    More info:
        https://www.postgresql.org/docs/current/routine-vacuuming.html#VACUUM-FOR-MULTIXACT-WRAPAROUND
        https://www.postgresql.org/docs/current/runtime-config-autovacuum.html#GUC-AUTOVACUUM-MULTIXACT-FREEZE-MAX-AGE
        https://www.postgresql.org/docs/current/functions-info.html
        https://aws.amazon.com/blogs/database/multixacts-in-postgresql-usage-side-effects-and-monitoring/
*/

/* ============================================================
   CHECK: Databases Approaching MultiXact ID Wraparound
   ============================================================ */

v_AdditionalInfo :=
(
    WITH multixact_limits AS
    (
        SELECT
            COALESCE(NULLIF(current_setting('autovacuum_multixact_freeze_max_age', true), '')::bigint, 400000000::bigint) AS autovacuum_multixact_freeze_max_age,
            LEAST
            (
                1000000000::bigint,
                COALESCE(NULLIF(current_setting('autovacuum_multixact_freeze_max_age', true), '')::bigint, 400000000::bigint) / 2
            ) AS threshold_mxid_age
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more databases have a high MultiXact ID age and may be approaching MultiXact ID wraparound.',
                'ThresholdMxidAge', (SELECT threshold_mxid_age FROM multixact_limits),
                'AutovacuumMultixactFreezeMaxAge', (SELECT autovacuum_multixact_freeze_max_age FROM multixact_limits),
                'MultixactWraparoundLimit', 2000000000,
                'Databases',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'DatabaseName', d.datname,
                        'MxidAge', mxid_age(d.datminmxid),
                        'DatMinMxid', d.datminmxid::text,
                        'PctOfWraparoundLimit', round(100.0 * mxid_age(d.datminmxid) / 2000000000, 2),
                        'AllowConnections', d.datallowconn,
                        'IsTemplate', d.datistemplate
                    )
                    ORDER BY mxid_age(d.datminmxid) DESC
                )
            )
        END
    FROM pg_catalog.pg_database d
    CROSS JOIN multixact_limits l
    WHERE d.datminmxid <> '0'::xid
      AND mxid_age(d.datminmxid) >= l.threshold_mxid_age
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
    'Maintenance',                                              -- Category
    'Cluster-level',                                            -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                          -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No databases approaching MultiXact ID wraparound risk were detected.'
        ELSE
            'Freeze the oldest MultiXacts in the affected databases: find the tables with the highest mxid_age(relminmxid) and run VACUUM (FREEZE) on them oldest first, or let an anti-wraparound autovacuum finish instead of cancelling it. First clear anything that holds back the oldest xmin and prevents freezing - long-running or idle-in-transaction sessions, abandoned prepared transactions, and inactive replication slots - and confirm autovacuum is enabled on every table. Then reduce MultiXact consumption at the source (index foreign key columns, avoid unnecessary SELECT FOR SHARE, disable driver or ORM options that wrap every statement in a savepoint), and only afterwards consider lowering autovacuum_multixact_freeze_max_age so freezing is forced earlier.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
