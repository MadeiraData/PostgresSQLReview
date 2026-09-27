/*
    DESCRIPTION:

    What This Means: One or more functions or procedures in this database are
        defined SECURITY DEFINER but have no search_path attached to their
        definition. A SECURITY DEFINER routine executes with the privileges of
        the role that owns it, not the role that calls it, so it is the standard
        way to hand a low-privilege application role a narrow, controlled piece
        of elevated access. The danger is that name resolution inside the routine
        still happens against the *caller's* search_path unless the routine
        pins its own. Any unqualified reference in the body -- a table, a view,
        a type, a function, or even an operator -- is therefore resolved using a
        setting the caller fully controls. A user who can create objects in any
        schema the caller's search_path reaches (most commonly a "public" schema
        that still grants CREATE to PUBLIC, or the temporary schema pg_temp,
        which is searched ahead of everything else for relation and type names
        and is writable by every role) can plant a decoy object that shadows the
        one the routine intended, and the routine will then run the attacker's
        table, function, or operator with the owner's privileges. That is a
        direct privilege escalation: the attacker gains whatever the owner has,
        and when the owner is a superuser, rds_superuser, or the role owning the
        application schema, it is a full compromise of the database's data. This
        is not theoretical -- it is the class of defect behind CVE-2007-2138 and
        CVE-2018-1058, and the PostgreSQL documentation devotes a dedicated
        section ("Writing SECURITY DEFINER Functions Safely") to it. The exposure
        is completely silent: the routine returns correct results and raises no
        error until someone actually exploits it, so it survives code review and
        monitoring indefinitely. The bad state is a SECURITY DEFINER routine
        whose resolution of unqualified names is left to whoever calls it; the
        good state is one that pins its own search_path so its body always
        resolves to the objects its author intended, no matter who calls it.

    Recommendations:
        For each routine listed below, attach an explicit search_path to its
        definition: ALTER FUNCTION <schema>.<name>(<args>) SET search_path =
        <trusted schemas>, pg_temp -- or ALTER PROCEDURE for a procedure. List
        only schemas that untrusted roles cannot create objects in, and put
        pg_temp last so the temporary schema can no longer shadow a relation or
        type the body references. Where the body can be edited, the strongest
        form is SET search_path = '' together with fully schema-qualifying every
        reference in the body, which removes name resolution from the picture
        entirely. Before applying either, confirm the routine does not
        deliberately rely on the caller's search_path to pick between
        same-named objects in different schemas (a legitimate but rare pattern
        in multi-tenant designs) -- pinning the path would change its behaviour.
        Separately, review the ExecuteGrantedToPublic flag reported for each
        routine: PostgreSQL grants EXECUTE to PUBLIC on new routines by default,
        so REVOKE EXECUTE ON FUNCTION <schema>.<name>(<args>) FROM PUBLIC and
        grant it only to the roles that genuinely need it, which shrinks the set
        of callers who could attempt the attack in the first place. Finally,
        confirm that SECURITY DEFINER is actually required for each routine at
        all -- if the caller's own privileges suffice, SECURITY INVOKER (the
        default) removes the escalation path completely.

    Scope : Database-level
    Category : Security

    More info:
        https://www.postgresql.org/docs/current/sql-createfunction.html#SQL-CREATEFUNCTION-SECURITY
        https://wiki.postgresql.org/wiki/A_Guide_to_CVE-2018-1058:_Protect_Your_Search_Path
        https://www.postgresql.org/support/security/CVE-2007-2138/
        https://www.postgresql.org/docs/current/ddl-schemas.html#DDL-SCHEMAS-PATH
        https://www.cybertec-postgresql.com/en/abusing-security-definer-functions/
*/

/* ============================================================
   CHECK: SECURITY DEFINER Functions Without a Fixed search_path
   ============================================================ */

v_AdditionalInfo := (
    WITH secdef_functions AS (
        SELECT
            n.nspname                                                       AS schema_name,
            p.proname                                                       AS function_name,
            pg_catalog.pg_get_function_identity_arguments(p.oid)            AS function_arguments,
            CASE p.prokind
                WHEN 'f' THEN 'function'
                WHEN 'p' THEN 'procedure'
                WHEN 'a' THEN 'aggregate'
                WHEN 'w' THEN 'window function'
                ELSE p.prokind::text
            END                                                             AS object_kind,
            pg_catalog.pg_get_userbyid(p.proowner)                          AS function_owner,
            l.lanname                                                       AS language,
            pg_catalog.has_function_privilege('public', p.oid, 'EXECUTE')   AS execute_granted_to_public
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n
            ON n.oid = p.pronamespace
        JOIN pg_catalog.pg_language l
            ON l.oid = p.prolang
        WHERE p.prosecdef
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE 'pg_toast%'
          AND n.nspname NOT LIKE 'pg_temp%'
          /* Routines installed by an extension are the extension author's to fix, and
             editing them breaks pg_dump and extension upgrades, so they are out of scope. */
          AND NOT EXISTS (
                  SELECT 1
                  FROM   pg_catalog.pg_depend d
                  WHERE  d.classid = 'pg_catalog.pg_proc'::regclass
                    AND  d.objid   = p.oid
                    AND  d.deptype = 'e'
              )
          /* The finding condition: no search_path entry among the routine's own
             configuration settings (pg_proc.proconfig holds them as 'name=value'). */
          AND NOT EXISTS (
                  SELECT 1
                  FROM   unnest(COALESCE(p.proconfig, '{}'::text[])) AS cfg
                  WHERE  split_part(cfg, '=', 1) = 'search_path'
              )
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM secdef_functions)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'One or more SECURITY DEFINER functions or procedures have no search_path attached to their definition, so unqualified object references inside them are resolved using the caller''s search_path and can be shadowed to run attacker-supplied code with the owner''s privileges.',
            'SecurityDefinerFunctionsWithoutSearchPath',
                (SELECT count(*) FROM secdef_functions),
            'AlsoExecutableByPublic',
                (SELECT count(*) FROM secdef_functions WHERE execute_granted_to_public),
            'ReportedFunctionLimit', 50,
            'Functions',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName',              f.schema_name,
                        'FunctionName',            f.function_name,
                        'FunctionArguments',       f.function_arguments,
                        'ObjectKind',              f.object_kind,
                        'FunctionOwner',           f.function_owner,
                        'Language',                f.language,
                        'ExecuteGrantedToPublic',  f.execute_granted_to_public
                    )
                    ORDER BY f.execute_granted_to_public DESC, f.schema_name, f.function_name
                )
                FROM (
                    SELECT *
                    FROM   secdef_functions
                    ORDER BY execute_granted_to_public DESC, schema_name, function_name
                    LIMIT  50
                ) f
            )
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
    'Security',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3, -- High: escalation to the routine owner's privileges, up to full database compromise when the owner is highly privileged
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END, -- None / Medium: a real and silent exposure, but exploiting it also requires the attacker to be able to execute the routine and to create a shadowing object in a searched schema
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END, -- None / Medium: one ALTER FUNCTION/PROCEDURE per routine, but each needs its unqualified references reviewed and retested
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END, -- None / Medium: pinning search_path changes name resolution, which can break a routine that deliberately relied on the caller's path
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No SECURITY DEFINER functions or procedures are missing a search_path setting.'
        ELSE
            'Attach an explicit search_path to each listed routine (ALTER FUNCTION/PROCEDURE <schema>.<name>(<args>) SET search_path = <trusted schemas>, pg_temp), listing only schemas untrusted roles cannot create objects in and keeping pg_temp last. Where the body can be edited, prefer SET search_path = '''' with every reference fully schema-qualified. Verify no routine deliberately relies on the caller''s search_path before changing it, revoke EXECUTE from PUBLIC where it is not needed, and drop SECURITY DEFINER entirely from any routine that does not require it.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production/Development';
