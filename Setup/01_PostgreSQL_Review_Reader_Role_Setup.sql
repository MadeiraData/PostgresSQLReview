/*
    PostgreSQL Health Check Role Setup
    Version: 0.1

    Purpose:
    Create and configure a dedicated PostgreSQL role for running the PostgreSQL Health Check script.

    This setup script is designed to be safe and adaptive:
    - It works on self-managed PostgreSQL where the executor has enough privileges.
    - It works on managed PostgreSQL services as much as the provider allows:
      Amazon RDS for PostgreSQL, Amazon Aurora PostgreSQL, Azure Database for PostgreSQL,
      Google Cloud SQL for PostgreSQL, EDB Postgres, and standard community PostgreSQL.
    - It does not require SUPERUSER for the health check role.
    - It does not grant write access to application tables.
    - It grants only monitoring and connection privileges needed for the Health Check.

    What this script creates:
    - A LOGIN role named review_reader, if it does not already exist.

    What this script grants:
    - pg_monitor if available and permitted.
    - If pg_monitor cannot be granted, it tries narrower built-in monitoring roles:
      pg_read_all_stats, pg_read_all_settings, pg_stat_scan_tables.
    - CONNECT and TEMPORARY on target databases.
    - Best-effort access to pg_stat_statements if the extension exists.

    What this script does NOT grant:
    - SUPERUSER
    - CREATEDB
    - CREATEROLE
    - REPLICATION
    - BYPASSRLS
    - SELECT on application tables
    - INSERT/UPDATE/DELETE on application tables
    - Ownership of any object

    Important:
    - Run this script using a PostgreSQL admin or DBA user.
    - In managed PostgreSQL services, some grants may fail because the cloud provider
      restricts them. The script will continue and report what succeeded or failed.
    - If a grant fails, review the final setup summary at the end of the script.

    Recommended execution:
        psql -h <host> -p 5432 -U <admin_user> -d <database> -f Setup_HealthCheck_Role.sql

    For pgAdmin:
        Open Query Tool against a target database and run this script.
*/


/*
    =====================================================================
    SECTION 1 - Configuration
    =====================================================================

    Adjust these values before running the script.

    p_healthcheck_role_name:
        The role that will run the Health Check.

    p_healthcheck_password:
        Password for the role.
        Replace CHANGE_ME_STRONG_PASSWORD before running.

    p_grant_access_to_all_databases:
        true  = try to grant CONNECT and TEMPORARY on all connectable non-template databases.
        false = grant CONNECT and TEMPORARY only on the current database.

    Recommended:
        - For a full PostgreSQL cluster health check: true
        - If the executor has limited privileges: false
        - In managed services with restricted permissions: start with false if unsure
*/

DO $$
DECLARE
    p_healthcheck_role_name text := 'review_reader';
    p_healthcheck_password  text := '9XVRTPfmjJkdZIGZQG9j';

    p_grant_access_to_all_databases boolean := true;

    v_current_database text := current_database();
    v_server_version text := current_setting('server_version', true);
    v_server_version_num integer := current_setting('server_version_num', true)::integer;

    v_distribution_flavor text;
    v_distribution_confidence text;

    v_role_exists boolean;
    v_role_can_login boolean;

    v_db record;
    v_role_name_quoted text;
    v_password_literal text;

    v_pg_monitor_exists boolean;
    v_pg_read_all_stats_exists boolean;
    v_pg_read_all_settings_exists boolean;
    v_pg_stat_scan_tables_exists boolean;

    v_pg_stat_statements_schema text;
    v_pg_stat_statements_object text;

    v_msg text;
BEGIN
    /*
        =================================================================
        SECTION 2 - Safety checks
        =================================================================

        This block validates the basic configuration before doing anything.
        The password placeholder must be changed.
    */

    RAISE NOTICE 'PostgreSQL Health Check Role Setup started.';
    RAISE NOTICE 'Current database: %', v_current_database;
    RAISE NOTICE 'PostgreSQL version: %', v_server_version;

    IF p_healthcheck_password = 'CHANGE_ME_STRONG_PASSWORD' THEN
        RAISE EXCEPTION
            'Please edit the setup script and replace CHANGE_ME_STRONG_PASSWORD with a secure password before running.';
    END IF;

    IF p_healthcheck_role_name IS NULL OR length(trim(p_healthcheck_role_name)) = 0 THEN
        RAISE EXCEPTION 'Health Check role name cannot be empty.';
    END IF;

    v_role_name_quoted := format('%I', p_healthcheck_role_name);
    v_password_literal := format('%L', p_healthcheck_password);


    /*
        =================================================================
        SECTION 3 - Best-effort environment detection
        =================================================================

        This is informational only.
        The script does not rely on this detection to decide security.
        It only prints a helpful message so the person running the script
        understands whether this looks like self-managed or managed PostgreSQL.

        Detection is best-effort because managed services do not expose all
        internal details through SQL.
    */

    WITH settings AS
    (
        SELECT
            current_setting('rds.extensions', true) AS rds_extensions,
            current_setting('azure.extensions', true) AS azure_extensions,
            current_setting('cloudsql.enable_pglogical', true) AS cloudsql_enable_pglogical,
            current_setting('edb_redwood_date', true) AS edb_redwood_date
    ),
    roles AS
    (
        SELECT
            bool_or(rolname = 'rdsadmin') AS has_rdsadmin_role,
            bool_or(rolname = 'azure_pg_admin') AS has_azure_pg_admin_role,
            bool_or(rolname = 'cloudsqlsuperuser') AS has_cloudsqlsuperuser_role
        FROM pg_roles
    ),
    databases AS
    (
        SELECT
            bool_or(datname = 'rdsadmin') AS has_rdsadmin_database
        FROM pg_database
    )
    SELECT
        CASE
            WHEN v_server_version ILIKE '%EnterpriseDB%'
              OR v_server_version ILIKE '%EDB%'
              OR settings.edb_redwood_date IS NOT NULL
            THEN 'EDB Postgres Advanced Server'

            WHEN roles.has_rdsadmin_role
              OR databases.has_rdsadmin_database
              OR settings.rds_extensions IS NOT NULL
            THEN 'Amazon RDS for PostgreSQL or Amazon Aurora PostgreSQL'

            WHEN roles.has_azure_pg_admin_role
              OR settings.azure_extensions IS NOT NULL
            THEN 'Azure Database for PostgreSQL'

            WHEN roles.has_cloudsqlsuperuser_role
              OR settings.cloudsql_enable_pglogical IS NOT NULL
            THEN 'Google Cloud SQL for PostgreSQL'

            ELSE 'PostgreSQL Community or unknown distribution'
        END,
        CASE
            WHEN roles.has_rdsadmin_role
              OR databases.has_rdsadmin_database
              OR roles.has_azure_pg_admin_role
              OR roles.has_cloudsqlsuperuser_role
              OR v_server_version ILIKE '%EnterpriseDB%'
              OR v_server_version ILIKE '%EDB%'
            THEN 'High'

            WHEN settings.rds_extensions IS NOT NULL
              OR settings.azure_extensions IS NOT NULL
              OR settings.cloudsql_enable_pglogical IS NOT NULL
              OR settings.edb_redwood_date IS NOT NULL
            THEN 'Medium'

            ELSE 'Best-effort detection'
        END
    INTO
        v_distribution_flavor,
        v_distribution_confidence
    FROM settings
    CROSS JOIN roles
    CROSS JOIN databases;

    RAISE NOTICE 'Detected PostgreSQL distribution/flavor: %', v_distribution_flavor;
    RAISE NOTICE 'Detection confidence: %', v_distribution_confidence;


    /*
        =================================================================
        SECTION 4 - Create the Health Check login role
        =================================================================

        PostgreSQL uses roles for both users and groups.
        A role with LOGIN is equivalent to a login/user account.

        This role is intentionally created without powerful permissions:
        - No SUPERUSER
        - No CREATEDB
        - No CREATEROLE
        - No REPLICATION
        - No BYPASSRLS

        INHERIT is enabled so that grants like pg_monitor are effective
        without requiring SET ROLE.
    */

    SELECT EXISTS
    (
        SELECT 1
        FROM pg_roles
        WHERE rolname = p_healthcheck_role_name
    )
    INTO v_role_exists;

    IF NOT v_role_exists THEN
        BEGIN
            EXECUTE
                'CREATE ROLE ' || v_role_name_quoted || '
                    LOGIN
                    PASSWORD ' || v_password_literal || '
                    NOSUPERUSER
                    NOCREATEDB
                    NOCREATEROLE
                    NOREPLICATION
                    NOBYPASSRLS
                    INHERIT';

            RAISE NOTICE 'Created role: %', p_healthcheck_role_name;

        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Could not create role "%". Error: %', p_healthcheck_role_name, SQLERRM;
            RAISE WARNING 'The script will continue. If the role does not exist, later grants will also fail.';
        END;
    ELSE
        RAISE NOTICE 'Role already exists: %', p_healthcheck_role_name;

        /*
            If the role already exists, do not change the password automatically.
            This avoids unexpected credential rotation.
        */
        RAISE NOTICE 'Existing role password was not changed.';
    END IF;


    /*
        =================================================================
        SECTION 5 - Validate role properties
        =================================================================

        If the role already existed, it might not have LOGIN.
        The script tries to enable LOGIN if permitted.
    */

    SELECT rolcanlogin
    INTO v_role_can_login
    FROM pg_roles
    WHERE rolname = p_healthcheck_role_name;

    IF v_role_can_login IS DISTINCT FROM true THEN
        BEGIN
            EXECUTE 'ALTER ROLE ' || v_role_name_quoted || ' LOGIN INHERIT';
            RAISE NOTICE 'Updated role to LOGIN INHERIT: %', p_healthcheck_role_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Could not alter role "%". Error: %', p_healthcheck_role_name, SQLERRM;
        END;
    END IF;


    /*
        =================================================================
        SECTION 6 - Grant monitoring privileges
        =================================================================

        Preferred option:
            pg_monitor

        Why pg_monitor:
            It is a built-in PostgreSQL role intended for monitoring.
            It provides broad visibility into PostgreSQL statistics and activity
            without making the Health Check role a superuser.

        Fallback option:
            If pg_monitor cannot be granted, the script tries narrower built-in roles:
            - pg_read_all_stats
            - pg_read_all_settings
            - pg_stat_scan_tables

        Managed PostgreSQL note:
            Some cloud providers may restrict these grants. The script will report
            warnings and continue.
    */

    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_monitor')
    INTO v_pg_monitor_exists;

    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_read_all_stats')
    INTO v_pg_read_all_stats_exists;

    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_read_all_settings')
    INTO v_pg_read_all_settings_exists;

    SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_stat_scan_tables')
    INTO v_pg_stat_scan_tables_exists;

    IF v_pg_monitor_exists THEN
        BEGIN
            EXECUTE format('GRANT pg_monitor TO %I', p_healthcheck_role_name);
            RAISE NOTICE 'Granted pg_monitor to %.', p_healthcheck_role_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Could not grant pg_monitor to %. Error: %', p_healthcheck_role_name, SQLERRM;

            /*
                If pg_monitor fails, try narrower monitoring roles.
            */

            IF v_pg_read_all_stats_exists THEN
                BEGIN
                    EXECUTE format('GRANT pg_read_all_stats TO %I', p_healthcheck_role_name);
                    RAISE NOTICE 'Granted pg_read_all_stats to %.', p_healthcheck_role_name;
                EXCEPTION WHEN OTHERS THEN
                    RAISE WARNING 'Could not grant pg_read_all_stats to %. Error: %', p_healthcheck_role_name, SQLERRM;
                END;
            END IF;

            IF v_pg_read_all_settings_exists THEN
                BEGIN
                    EXECUTE format('GRANT pg_read_all_settings TO %I', p_healthcheck_role_name);
                    RAISE NOTICE 'Granted pg_read_all_settings to %.', p_healthcheck_role_name;
                EXCEPTION WHEN OTHERS THEN
                    RAISE WARNING 'Could not grant pg_read_all_settings to %. Error: %', p_healthcheck_role_name, SQLERRM;
                END;
            END IF;

            IF v_pg_stat_scan_tables_exists THEN
                BEGIN
                    EXECUTE format('GRANT pg_stat_scan_tables TO %I', p_healthcheck_role_name);
                    RAISE NOTICE 'Granted pg_stat_scan_tables to %.', p_healthcheck_role_name;
                EXCEPTION WHEN OTHERS THEN
                    RAISE WARNING 'Could not grant pg_stat_scan_tables to %. Error: %', p_healthcheck_role_name, SQLERRM;
                END;
            END IF;
        END;
    ELSE
        RAISE WARNING 'Built-in role pg_monitor does not exist on this PostgreSQL version. Trying narrower monitoring roles.';

        IF v_pg_read_all_stats_exists THEN
            BEGIN
                EXECUTE format('GRANT pg_read_all_stats TO %I', p_healthcheck_role_name);
                RAISE NOTICE 'Granted pg_read_all_stats to %.', p_healthcheck_role_name;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Could not grant pg_read_all_stats to %. Error: %', p_healthcheck_role_name, SQLERRM;
            END;
        END IF;

        IF v_pg_read_all_settings_exists THEN
            BEGIN
                EXECUTE format('GRANT pg_read_all_settings TO %I', p_healthcheck_role_name);
                RAISE NOTICE 'Granted pg_read_all_settings to %.', p_healthcheck_role_name;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Could not grant pg_read_all_settings to %. Error: %', p_healthcheck_role_name, SQLERRM;
            END;
        END IF;

        IF v_pg_stat_scan_tables_exists THEN
            BEGIN
                EXECUTE format('GRANT pg_stat_scan_tables TO %I', p_healthcheck_role_name);
                RAISE NOTICE 'Granted pg_stat_scan_tables to %.', p_healthcheck_role_name;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Could not grant pg_stat_scan_tables to %. Error: %', p_healthcheck_role_name, SQLERRM;
            END;
        END IF;
    END IF;


    /*
        =================================================================
        SECTION 7 - Grant database access
        =================================================================

        The Health Check role needs CONNECT on every database where the check
        will be executed.

        The Health Check script also uses temporary tables, so the role needs
        TEMPORARY on those databases.

        This section can work in two modes:
        - p_grant_access_to_all_databases = true:
          Try all connectable, non-template databases.
        - p_grant_access_to_all_databases = false:
          Grant only on the current database.

        If the executor does not own a database and is not sufficiently privileged,
        the grant may fail for that database. The script will continue and report it.
    */

    IF p_grant_access_to_all_databases THEN
        RAISE NOTICE 'Database access mode: trying all connectable non-template databases.';

        FOR v_db IN
            SELECT datname
            FROM pg_database
            WHERE datallowconn = true
              AND datistemplate = false
            ORDER BY datname
        LOOP
            BEGIN
                EXECUTE format(
                    'GRANT CONNECT ON DATABASE %I TO %I',
                    v_db.datname,
                    p_healthcheck_role_name
                );

                EXECUTE format(
                    'GRANT TEMPORARY ON DATABASE %I TO %I',
                    v_db.datname,
                    p_healthcheck_role_name
                );

                RAISE NOTICE 'Granted CONNECT and TEMPORARY on database "%".', v_db.datname;

            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Could not grant CONNECT/TEMPORARY on database "%". Error: %', v_db.datname, SQLERRM;
            END;
        END LOOP;
    ELSE
        RAISE NOTICE 'Database access mode: current database only.';

        BEGIN
            EXECUTE format(
                'GRANT CONNECT ON DATABASE %I TO %I',
                v_current_database,
                p_healthcheck_role_name
            );

            EXECUTE format(
                'GRANT TEMPORARY ON DATABASE %I TO %I',
                v_current_database,
                p_healthcheck_role_name
            );

            RAISE NOTICE 'Granted CONNECT and TEMPORARY on current database "%".', v_current_database;

        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Could not grant CONNECT/TEMPORARY on current database "%". Error: %', v_current_database, SQLERRM;
        END;
    END IF;


    /*
        =================================================================
        SECTION 8 - Best-effort pg_stat_statements access
        =================================================================

        pg_stat_statements is commonly used by the Health Check script.

        Important PostgreSQL behavior:
        - pg_stat_statements must be loaded through shared_preload_libraries.
        - The extension must exist in the current database.
        - Creating or enabling the extension is not done here, because that may
          require restart or change control.

        This setup script only tries to grant access if pg_stat_statements
        already exists in the current database.

        If the object is not present, this section does nothing.
    */

    SELECT
        n.nspname,
        c.relname
    INTO
        v_pg_stat_statements_schema,
        v_pg_stat_statements_object
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'pg_stat_statements'
      AND c.relkind IN ('v', 'm', 'r')
    ORDER BY
        CASE WHEN n.nspname = 'public' THEN 0 ELSE 1 END,
        n.nspname
    LIMIT 1;

    IF v_pg_stat_statements_schema IS NOT NULL THEN
        BEGIN
            EXECUTE format(
                'GRANT USAGE ON SCHEMA %I TO %I',
                v_pg_stat_statements_schema,
                p_healthcheck_role_name
            );

            EXECUTE format(
                'GRANT SELECT ON %I.%I TO %I',
                v_pg_stat_statements_schema,
                v_pg_stat_statements_object,
                p_healthcheck_role_name
            );

            RAISE NOTICE 'Granted access to %.% for %.',
                v_pg_stat_statements_schema,
                v_pg_stat_statements_object,
                p_healthcheck_role_name;

        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Could not grant access to pg_stat_statements. Error: %', SQLERRM;
        END;
    ELSE
        RAISE NOTICE 'pg_stat_statements object was not found in current database. Skipping pg_stat_statements grants.';
    END IF;


    /*
        =================================================================
        SECTION 9 - Final summary
        =================================================================

        This section prints a simple summary that can be copied back to the DBA
        or attached to an implementation ticket.

        It does not guarantee that every Health Check query will be visible,
        because managed services and local security policies may restrict some
        catalog or monitoring access.

        However, if pg_monitor + CONNECT + TEMPORARY are present, the Health Check
        role should be suitable for the initial PostgreSQL Health Check.
    */

    RAISE NOTICE 'PostgreSQL Health Check Role Setup completed.';
    RAISE NOTICE 'Role name: %', p_healthcheck_role_name;
    RAISE NOTICE 'Recommended test command:';
    RAISE NOTICE 'psql -h <host> -p 5432 -U % -d <database>', p_healthcheck_role_name;
END $$;


/*
    =====================================================================
    SECTION 10 - Human-readable verification output
    =====================================================================

    The queries below produce result sets that are easy to review.

    They show:
    - Whether the role exists.
    - Whether it has dangerous privileges.
    - Which monitoring roles it received.
    - Whether it has CONNECT and TEMPORARY on the current database.

    These SELECT statements are safe and read-only.
*/

SELECT
    'Role properties' AS verification_section,
    r.rolname AS role_name,
    r.rolcanlogin AS can_login,
    r.rolinherit AS inherit_privileges,
    r.rolsuper AS is_superuser,
    r.rolcreatedb AS can_create_database,
    r.rolcreaterole AS can_create_role,
    r.rolreplication AS has_replication_privilege,
    r.rolbypassrls AS can_bypass_rls
FROM pg_roles r
WHERE r.rolname = 'review_reader';


SELECT
    'Monitoring role memberships' AS verification_section,
    member_role.rolname AS role_name,
    granted_role.rolname AS member_of
FROM pg_auth_members am
JOIN pg_roles member_role
    ON member_role.oid = am.member
JOIN pg_roles granted_role
    ON granted_role.oid = am.roleid
WHERE member_role.rolname = 'review_reader'
  AND granted_role.rolname IN
  (
      'pg_monitor',
      'pg_read_all_stats',
      'pg_read_all_settings',
      'pg_stat_scan_tables'
  )
ORDER BY granted_role.rolname;


SELECT
    'Current database access' AS verification_section,
    current_database() AS database_name,
    has_database_privilege('review_reader', current_database(), 'CONNECT') AS has_connect,
    has_database_privilege('review_reader', current_database(), 'TEMP') AS has_temp;


/*
    =====================================================================
    SECTION 11 - Optional connection test instructions
    =====================================================================

    After the setup completes, test with:

        psql -h <host> -p 5432 -U review_reader -d <database>

    Then run:

        SELECT current_user;
        SELECT current_database();

        CREATE TEMP TABLE healthcheck_temp_test(id integer);
        DROP TABLE healthcheck_temp_test;

        SELECT count(*) FROM pg_stat_activity;

    Expected:
    - current_user should be review_reader.
    - TEMP table creation should succeed.
    - pg_stat_activity query should succeed.
*/