
/*
    DESCRIPTION:

    What This Means: One or more indexes, columns, or constraints depend on a named
        collation whose recorded version (pg_collation.collversion) no longer matches
        the version the operating system or ICU library currently provides
        (pg_collation_actual_version()). PostgreSQL records a collation's version at
        creation time and compares it on use so it can warn when the underlying
        library has changed. A routine OS package upgrade, a glibc/ICU security patch,
        or a container base-image bump can silently change how that collation orders
        strings while the cluster keeps running -- there is no crash and no error at
        the moment the library changes. Every B-tree index built on the affected
        collation may now be sorted inconsistently with the library's current rules,
        which can make index scans skip or misorder rows, and a UNIQUE or PRIMARY KEY
        constraint that relied on the old sort order to distinguish values may no
        longer actually prevent duplicates. Because nothing fails loudly when the
        library changes, this can go unnoticed for months until a query returns wrong
        results or a duplicate value that should have been rejected appears.

    Recommendations:
        For each affected object listed in AdditionalInfo, rebuild it so its on-disk
        order matches the collation's current rules: REINDEX INDEX CONCURRENTLY (or
        REINDEX TABLE CONCURRENTLY) for indexes, and re-validate any UNIQUE/PRIMARY KEY
        constraint that depends on the collation for values that may have become
        duplicates under the new sort order. Only after rebuilding, run
        ALTER COLLATION <name> REFRESH VERSION to update the recorded version and
        silence the warning -- REFRESH VERSION only updates catalog bookkeeping, it
        does not rebuild anything itself, so running it first would silence a real
        problem without fixing it. Going forward, pin collation versions explicitly
        where the platform allows it, and rebuild collation-dependent indexes as a
        matter of course after any OS/library upgrade.

    Scope : Database-level
    Category : Data Integrity

    More info:
        https://www.postgresql.org/docs/current/sql-altercollation.html
        https://www.postgresql.org/docs/current/collation.html
*/

v_AdditionalInfo :=
(
    WITH mismatched_collations AS
    (
        SELECT
            c.oid,
            c.collname,
            n.nspname                            AS collation_schema,
            c.collversion                         AS recorded_version,
            pg_collation_actual_version(c.oid)    AS actual_version
        FROM   pg_collation c
        JOIN   pg_namespace n ON n.oid = c.collnamespace
        WHERE  c.collversion IS NOT NULL
        AND    c.collversion <> ''
        AND    c.collversion <> pg_collation_actual_version(c.oid)
    ),
    affected_objects AS
    (
        SELECT
            mc.collname,
            mc.collation_schema,
            mc.recorded_version,
            mc.actual_version,
            pg_describe_object(d.classid, d.objid, d.objsubid) AS dependent_object
        FROM   mismatched_collations mc
        JOIN   pg_depend d
               ON d.refclassid = 'pg_collation'::regclass
              AND d.refobjid = mc.oid
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM affected_objects) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'MismatchedCollationCount', (SELECT count(DISTINCT collname) FROM affected_objects),
                'AffectedObjectCount',      (SELECT count(*) FROM affected_objects),
                'Details',                  (SELECT jsonb_agg(to_jsonb(a)) FROM affected_objects a),
                'FindingReason',            'One or more database objects depend on a collation whose recorded version no longer matches the version the operating system or ICU library currently provides. Sort order used to build these objects may have changed since they were created, risking corrupted indexes, broken uniqueness guarantees, and incorrect query results.'
            )
        END
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
    'Data Integrity',                                            -- Category
    'Database-level',                                            -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No database objects currently depend on a collation with a recorded version different from what the operating system or ICU library provides.'
        ELSE
            'Rebuild each affected object (REINDEX INDEX CONCURRENTLY / REINDEX TABLE CONCURRENTLY) so it is re-sorted under the collation''s current rules, re-validate any dependent UNIQUE or PRIMARY KEY constraint for values that may have become duplicates, and only then run ALTER COLLATION <name> REFRESH VERSION to update the recorded version.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
