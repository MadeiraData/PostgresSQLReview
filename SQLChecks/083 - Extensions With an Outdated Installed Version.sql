
/*
    DESCRIPTION:

    What This Means: One or more extensions installed in this database are running an older
        version than the version currently available on this PostgreSQL server. This happens
        when an extension's files on disk are upgraded (by a package update or a PostgreSQL
        major-version upgrade) but ALTER EXTENSION ... UPDATE was never run afterward, so
        pg_extension still records the old version even though newer extension code is present.
        PostgreSQL never upgrades an installed extension's SQL objects on its own.

    Recommendations:
        Review each outdated extension and run ALTER EXTENSION <name> UPDATE (optionally
        TO '<version>') during a maintenance window to bring the installed objects in line
        with the version available on this server. Test first for extensions with documented
        behavior changes between versions (for example PostGIS raster/geometry changes), and
        confirm the new version's SQL and shared library files are actually present before
        running the update.

    Scope : Database-level
    Category : Version and Patching

    More info:
        https://www.postgresql.org/docs/current/sql-alterextension.html
        https://www.postgresql.org/docs/current/extend-extensions.html
        https://www.percona.com/blog/upgrading-postgresql-extensions/
*/

v_AdditionalInfo :=
(
    WITH outdated_extensions AS
    (
        SELECT
            name,
            installed_version,
            default_version
        FROM pg_available_extensions
        WHERE installed_version IS NOT NULL
          AND default_version IS NOT NULL
          AND installed_version <> default_version
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM outdated_extensions) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'CurrentDatabase', current_database(),
                'OutdatedExtensionCount', (SELECT count(*) FROM outdated_extensions),
                'OutdatedExtensions', (SELECT jsonb_agg(to_jsonb(o)) FROM outdated_extensions o),
                'FindingReason', 'One or more installed extensions are running an older version than the version available on this server; ALTER EXTENSION ... UPDATE has not been run.'
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
    'Version and Patching',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High: some extension versions carry documented security fixes (e.g. CVEs in PostGIS/pgcrypto), unpatched until updated
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'All installed extensions in this database are already at the version available on this PostgreSQL server.'
        ELSE
            'Review each outdated extension and run ALTER EXTENSION <name> UPDATE during a maintenance window, testing first for extensions with documented behavior changes between versions.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
