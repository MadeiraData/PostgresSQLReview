/*
    DESCRIPTION:

    What This Means: autovacuum_vacuum_insert_threshold is set to -1, which
        turns off autovacuum's insert-driven vacuum trigger cluster-wide for
        every table that does not override the setting with its own
        autovacuum_vacuum_insert_threshold storage parameter. PostgreSQL 13
        added this trigger specifically to fix a long-standing problem: a
        table that only ever receives INSERTs (a log, event, audit, or
        time-series table) generates no dead tuples, so the ordinary
        dead-tuple-ratio trigger that drives autovacuum on every other table
        never fires for it. Before this feature existed, such a table was
        left completely unvacuumed until PostgreSQL's anti-wraparound
        autovacuum eventually forced a vacuum on it - typically the single
        largest, least incremental, and most disruptive vacuum the table
        will ever undergo, arriving with no warning once relfrozenxid age
        crosses autovacuum_freeze_max_age. In the meantime the table's
        visibility map is never updated, so index-only scans on it keep
        falling back to the heap, and both bloat and transaction ID age
        grow unchecked. Setting autovacuum_vacuum_insert_threshold to -1
        disables the fix and reopens exactly this gap.

    Recommendations:
        Set autovacuum_vacuum_insert_threshold back to a positive value (the
        PostgreSQL 13+ default is 1000) unless a specific table's insert
        rate genuinely warrants disabling it, in which case prefer disabling
        it per table via that table's own autovacuum_vacuum_insert_threshold
        storage parameter rather than cluster-wide. This is a reloadable
        GUC (context = sighup): applying it via ALTER SYSTEM / the
        parameter group plus a config reload takes effect immediately, no
        restart required. Review autovacuum_vacuum_insert_scale_factor
        alongside it so insert-only tables on larger installs are not
        vacuumed excessively often either.

    Scope : Cluster-level
    Category : Maintenance

    More info:
        https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
        https://www.postgresql.org/docs/current/routine-vacuuming.html#AUTOVACUUM
        https://www.postgresql.org/docs/current/sql-createtable.html#SQL-CREATETABLE-STORAGE-PARAMETERS
*/

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN s.insert_threshold IS DISTINCT FROM -1
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'AutovacuumVacuumInsertThreshold', s.insert_threshold,
                    'AutovacuumVacuumInsertScaleFactor', s.insert_scale_factor,
                    'Autovacuum', s.autovacuum_enabled,
                    'FindingReason', 'autovacuum_vacuum_insert_threshold is set to -1, disabling autovacuum''s insert-driven vacuum trigger cluster-wide, so insert-only tables are not vacuumed until a disruptive anti-wraparound vacuum is eventually forced.'
                )
        END
    FROM
    (
        SELECT
            (SELECT setting::integer FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_threshold')    AS insert_threshold,
            (SELECT setting::numeric FROM pg_settings WHERE name = 'autovacuum_vacuum_insert_scale_factor') AS insert_scale_factor,
            (SELECT setting FROM pg_settings WHERE name = 'autovacuum')                                     AS autovacuum_enabled
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
    'Maintenance',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                          -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'autovacuum_vacuum_insert_threshold is enabled (not -1); autovacuum''s insert-driven vacuum trigger is active for insert-only tables.'
        ELSE
            'Set autovacuum_vacuum_insert_threshold back to a positive value (PostgreSQL 13+ default is 1000) so insert-only tables are vacuumed proactively instead of only at anti-wraparound time. Disable it per table via a storage parameter instead of cluster-wide if a specific table genuinely needs it off.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
