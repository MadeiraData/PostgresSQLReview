
/*
    DESCRIPTION:
        Observability: pg_stat_statements is missing or not fully enabled.
        Without it, workload-level query analysis is limited.

    Remediation:
        Enable pg_stat_statements using the appropriate PostgreSQL or managed-service configuration.
        This may require shared_preload_libraries, a restart, and CREATE EXTENSION in relevant databases.

    More info:
        https://www.postgresql.org/docs/current/pgstatstatements.html
        https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-SHARED-PRELOAD-LIBRARIES
*/

v_AdditionalInfo :=
(
    WITH pgss_status AS
    (
        SELECT
            EXISTS
            (
                SELECT 1
                FROM pg_extension
                WHERE extname = 'pg_stat_statements'
            ) AS ExtensionInstalledInCurrentDatabase,

            COALESCE(current_setting('shared_preload_libraries', true), '') ILIKE '%pg_stat_statements%' AS LoadedInSharedPreloadLibraries,

            to_regclass('public.pg_stat_statements') IS NOT NULL
            OR to_regclass('pg_catalog.pg_stat_statements') IS NOT NULL AS PgStatStatementsViewVisible,

            current_setting('shared_preload_libraries', true) AS SharedPreloadLibraries
    )
    SELECT
        CASE
            WHEN ExtensionInstalledInCurrentDatabase
             AND LoadedInSharedPreloadLibraries
             AND PgStatStatementsViewVisible
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'CurrentDatabase', current_database(),
                    'ExtensionInstalledInCurrentDatabase', ExtensionInstalledInCurrentDatabase,
                    'LoadedInSharedPreloadLibraries', LoadedInSharedPreloadLibraries,
                    'PgStatStatementsViewVisible', PgStatStatementsViewVisible,
                    'SharedPreloadLibraries', SharedPreloadLibraries,
                    'FindingReason',
                        CASE
                            WHEN NOT LoadedInSharedPreloadLibraries
                                THEN 'pg_stat_statements is not listed in shared_preload_libraries.'
                            WHEN NOT ExtensionInstalledInCurrentDatabase
                                THEN 'pg_stat_statements extension is not installed in the current database.'
                            WHEN NOT PgStatStatementsViewVisible
                                THEN 'pg_stat_statements view is not visible to the current user or is not available.'
                            ELSE
                                'pg_stat_statements is not fully available.'
                        END,
                    'Note', 'pg_stat_statements requires both cluster-level preload configuration and database-level extension creation.'
                )
        END
    FROM pgss_status
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
    'Observability',
    'Cluster/database-level',
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN false
        ELSE
            true
    END,
    3,      -- High
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 0  -- None
        ELSE
            3  -- High
    END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 0  -- None
        ELSE
            2  -- Medium
    END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 0  -- None
        ELSE
            2  -- Medium
    END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'pg_stat_statements is installed, loaded, and visible in the current database.'
        ELSE
            'Enable pg_stat_statements in a controlled way to support workload-level query analysis. This may require shared_preload_libraries configuration and a PostgreSQL restart depending on the environment. The extension must also be created in each relevant database where query statistics are required.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';

