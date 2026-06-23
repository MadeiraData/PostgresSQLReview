
/*
    DESCRIPTION:
        Maintenance: one or more user tables have autovacuum disabled.
        This can cause dead tuple accumulation, bloat, and stale statistics.

    Remediation:
        Review tables with autovacuum_enabled=false and enable autovacuum where possible.
        Keep autovacuum disabled only when a reliable manual process exists.

    More info:
        https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
        https://www.postgresql.org/docs/current/sql-createtable.html
*/

v_AdditionalInfo :=
(
    WITH tables_with_disabled_autovacuum AS
    (
        SELECT
            n.nspname AS SchemaName,
            c.relname AS TableName,
            c.reloptions AS RelOptions
        FROM pg_class c
        JOIN pg_namespace n
            ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND c.reloptions::text ILIKE '%autovacuum_enabled=false%'
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'Tables',
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', SchemaName,
                            'TableName', TableName,
                            'RelOptions', RelOptions
                        )
                        ORDER BY SchemaName, TableName
                    )
                )
        END
    FROM tables_with_disabled_autovacuum
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
    'Object-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No user tables with autovacuum disabled were detected.'
        ELSE
            'Review tables where autovacuum is disabled. Enable autovacuum unless a documented manual maintenance process exists.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production/Development';

