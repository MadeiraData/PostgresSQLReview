/*
    DESCRIPTION:

    What This Means: one or more schemas grant the CREATE privilege to PUBLIC,
        meaning every authenticated role in the database can create objects
        (tables, views, functions, etc.) inside that schema. This is the classic
        PostgreSQL "public schema" exposure: an untrusted or low-privilege user
        can create an object that shadows one the application relies on (a
        schema search_path attack), or plant a function/view that later runs
        with another user's privileges. Most documented PostgreSQL privilege
        escalation techniques rely on being able to create an object in a
        schema an unintended role can reach. PostgreSQL 15 changed the built-in
        "public" schema's default specifically to close this exposure, but
        instances upgraded from an earlier version, or any schema where CREATE
        was explicitly (re-)granted to PUBLIC, remain open.

    Recommendations:
        Revoke CREATE from PUBLIC on the affected schema(s): REVOKE CREATE ON
        SCHEMA <schema> FROM PUBLIC. Grant CREATE only to the specific roles or
        application accounts that need to create objects there. If applications
        currently rely on writing into a shared schema, move them to a
        dedicated, owned schema instead of leaving it open to every role.
        Validate with the application owners before revoking, in case a
        workflow depends on the broad create access.

    Scope : Database-level
    Category : Security

    More info:
        https://www.postgresql.org/docs/current/ddl-schemas.html#DDL-SCHEMAS-PATTERNS
        https://www.percona.com/blog/public-schema-security-upgrade-in-postgresql-15/
        https://www.cybertec-postgresql.com/en/postgresql-security-things-to-avoid-in-real-life/
*/

v_AdditionalInfo := (
    WITH public_create_schemas AS (
        SELECT
            n.nspname AS schema_name,
            pg_get_userbyid(n.nspowner) AS schema_owner
        FROM pg_namespace n
        CROSS JOIN LATERAL aclexplode(n.nspacl) AS acl
        WHERE acl.grantee = 0
          AND acl.privilege_type = 'CREATE'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM public_create_schemas)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'One or more schemas grant the CREATE privilege to PUBLIC, allowing any authenticated role to create objects in the schema.',
            'Schemas',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'SchemaOwner', schema_owner
                    )
                    ORDER BY schema_name
                )
                FROM public_create_schemas
            )
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
    'Security',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                          -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No schemas grant the CREATE privilege to PUBLIC.'
        ELSE
            'Revoke CREATE from PUBLIC on the listed schema(s) (REVOKE CREATE ON SCHEMA <schema> FROM PUBLIC) and grant it only to the specific roles/applications that need to create objects there. Validate with application owners before revoking.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';