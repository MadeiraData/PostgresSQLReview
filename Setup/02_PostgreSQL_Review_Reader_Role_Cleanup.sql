/*
    PostgreSQL Review - Reader Role Cleanup

    Purpose:
    Remove the role created by 01_PostgreSQL_Review_Reader_Role_Setup.sql after
    the review is finished.

    What the setup granted, and how this script removes it:
    - Membership in pg_monitor (or pg_read_all_stats / pg_read_all_settings /
      pg_stat_scan_tables)                    -> removed with the role.
    - CONNECT and TEMPORARY on databases      -> removed by DROP OWNED BY
                                                 (run in any database).
    - USAGE on the pg_stat_statements schema and SELECT on pg_stat_statements,
      in the database where the setup ran    -> removed by DROP OWNED BY
                                                 run in THAT database.

    How to run:
    - Run as the same admin / DBA user that ran the setup script.
    - Run it in the database where you ran the setup script first. It removes
      the role's privileges there and then tries to drop the role.
    - If the role still has privileges in other databases, the script names
      them and does not fail: run it again in each named database. The run
      that clears the last one drops the role.
    - Safe to run more than once; if the role no longer exists it only says so.

        psql -h <host> -p 5432 -U <admin_user> -d <database> -f 02_PostgreSQL_Review_Reader_Role_Cleanup.sql

    For pgAdmin:
        Open Query Tool against the database and run this script.

    It does not touch application data. The role owns no objects (the setup
    never grants ownership), so DROP OWNED BY only revokes its privileges.
*/

DO $$
DECLARE
    -- Must match p_healthcheck_role_name in the setup script.
    p_healthcheck_role_name text := 'review_reader';

    v_role_oid          oid;
    v_remaining         text;
BEGIN
    SELECT oid
    INTO   v_role_oid
    FROM   pg_catalog.pg_roles
    WHERE  rolname = p_healthcheck_role_name;

    IF v_role_oid IS NULL THEN
        RAISE NOTICE 'Role "%" does not exist - nothing to clean up.', p_healthcheck_role_name;
        RETURN;
    END IF;

    IF p_healthcheck_role_name = current_user THEN
        RAISE EXCEPTION 'Connected as "%" itself. Run this cleanup as the admin user that ran the setup script.', p_healthcheck_role_name;
    END IF;

    -- Revokes the role's privileges in this database and on shared objects
    -- (databases), and drops anything it owns here (the setup grants nothing to own).
    EXECUTE format('DROP OWNED BY %I', p_healthcheck_role_name);
    RAISE NOTICE 'Removed the privileges of "%" in database "%".', p_healthcheck_role_name, current_database();

    BEGIN
        EXECUTE format('DROP ROLE %I', p_healthcheck_role_name);
        RAISE NOTICE 'Role "%" dropped. Cleanup complete.', p_healthcheck_role_name;

    EXCEPTION
        WHEN dependent_objects_still_exist THEN
            SELECT string_agg(DISTINCT d.datname, ', ' ORDER BY d.datname)
            INTO   v_remaining
            FROM   pg_catalog.pg_shdepend s
            JOIN   pg_catalog.pg_database d ON d.oid = s.dbid
            WHERE  s.refclassid = 'pg_catalog.pg_authid'::regclass
            AND    s.refobjid   = v_role_oid;

            RAISE WARNING 'Role "%" still has privileges in: %. Run this script in each of those databases; the last run drops the role.',
                p_healthcheck_role_name, COALESCE(v_remaining, '(unknown - see the error detail)');
            RAISE NOTICE 'Detail: %', SQLERRM;
    END;
END
$$;
