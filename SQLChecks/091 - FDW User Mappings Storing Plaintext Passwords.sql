/*
    DESCRIPTION:

    What This Means: one or more Foreign Data Wrapper user mappings (created via
        CREATE USER MAPPING, typically for postgres_fdw or dblink) store a
        plaintext password in their OPTIONS clause. PostgreSQL keeps that
        password unencrypted in the pg_user_mapping catalog, and while the
        catalog itself is restricted, the pg_user_mappings view exposes the
        stored options -- including the password -- to the mapping's owner,
        its target role, AND to any role granted USAGE on the associated
        foreign server. Granting USAGE so a role can query through the FDW
        therefore also, silently, grants that role visibility into every
        password stored for that server (and psql's \deu+ prints it directly).
        This is a documented PostgreSQL bug/design tension (bug #16682, #14600)
        and the credential-exposure class behind CVE-2007-3278 and
        CVE-2007-6601, where a leaked user-mapping password often carries
        broader privileges on the remote side than the local grant implies,
        turning a scoped FDW query permission into a path to remote
        compromise.

    Recommendations:
        Where possible, avoid storing a password directly in the user mapping:
        use certificate-based authentication for the remote connection, a
        .pgpass file readable only by the postgres OS user, or -- for
        postgres_fdw specifically -- PostgreSQL 13+'s password_required=false
        option combined with prior superuser permission, so a trusted
        non-superuser role can connect without a stored password. Where a
        password option must remain, restrict USAGE on the foreign server to
        only the roles that truly need it, since USAGE is what unlocks
        visibility into the stored password, and treat \deu+ output as
        sensitive. Validate with the application owner before revoking USAGE,
        in case a workflow depends on the current grant.

    Scope : Database-level
    Category : Security

    More info:
        https://www.postgresql.org/docs/current/sql-createusermapping.html
        https://www.postgresql.org/docs/current/postgres-fdw.html
        https://www.postgresql.org/docs/current/catalog-pg-user-mapping.html
*/

v_AdditionalInfo := (
    WITH offenders AS (
        SELECT
            um.srvname                       AS server_name,
            um.usename                        AS mapped_role,
            pg_get_userbyid(fs.srvowner)      AS server_owner
        FROM pg_catalog.pg_user_mappings um
        JOIN pg_catalog.pg_foreign_server fs ON fs.oid = um.srvid
        WHERE um.umoptions IS NOT NULL
          AND EXISTS (
                SELECT 1
                FROM unnest(um.umoptions) AS opt(kv)
                WHERE kv LIKE 'password=%'
          )
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM offenders)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'One or more foreign data wrapper user mappings store a plaintext password. PostgreSQL exposes that password via pg_user_mappings to every role granted USAGE on the associated foreign server, not only to the mapping owner.',
            'OffenderCount', (SELECT count(*) FROM offenders),
            'Offenders',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'ServerName',   server_name,
                        'MappedRole',   mapped_role,
                        'ServerOwner',  server_owner
                    )
                    ORDER BY server_name, mapped_role
                )
                FROM offenders
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No foreign data wrapper user mapping stores a plaintext password.'
        ELSE
            'Remove the stored password from the listed user mapping(s) where possible (certificate-based auth, a restricted .pgpass file, or postgres_fdw''s password_required=false with prior superuser permission), and restrict USAGE on the foreign server to only the roles that need it, since USAGE grants visibility into the stored password via pg_user_mappings. Validate with the application owner before revoking USAGE.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
