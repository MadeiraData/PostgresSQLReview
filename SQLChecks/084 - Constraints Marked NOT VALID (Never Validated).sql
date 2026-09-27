/*
    DESCRIPTION:

    What This Means: A CHECK or FOREIGN KEY constraint created with the NOT VALID
    clause (or added and then never followed by ALTER TABLE ... VALIDATE
    CONSTRAINT) is enforced only against rows inserted or updated from the moment
    it was created onward. PostgreSQL deliberately skips scanning the table's
    existing rows when the constraint is declared NOT VALID -- that is the whole
    point of the clause, since it lets a constraint be added to a large, busy
    table without taking the long-held lock a full validation scan would need.
    The cost of that shortcut is silent: pg_constraint.convalidated stays false
    until someone explicitly runs VALIDATE CONSTRAINT, and until then nothing
    tells a DBA or a developer that rows already in the table may violate the
    constraint. Application code, reporting queries, and every other constraint
    or join that assumes the table's FOREIGN KEY or CHECK constraints hold for
    ALL rows can silently produce wrong results -- orphaned child rows with no
    matching parent, or rows that fail a CHECK a report or later migration
    assumes is universally true -- with no error raised anywhere, because the
    constraint genuinely does not cover those rows. A constraint stuck in this
    state is easy to forget entirely once the deployment or migration that
    created it is over.

    Recommendations:
        For each flagged constraint, run "ALTER TABLE <table> VALIDATE CONSTRAINT
        <name>;". This scans existing rows and marks the constraint valid, but
        -- unlike adding the constraint fresh -- it only takes a
        SHARE UPDATE EXCLUSIVE lock, so normal reads and writes continue
        throughout the scan; only other DDL on the same table is blocked. Expect
        the validation to fail with the offending row(s) reported if data already
        violates the constraint, at which point the data must be corrected (or the
        constraint redefined) before it can be marked valid. Prefer VALIDATE
        CONSTRAINT over dropping and recreating the constraint, which would
        re-incur the full validation scan under a much heavier lock.

    Scope : Database-level
    Category : Data Integrity

    More info:
        https://www.postgresql.org/docs/current/sql-altertable.html
        https://www.postgresql.org/docs/current/catalog-pg-constraint.html
        https://www.postgresql.org/docs/current/ddl-constraints.html
*/

v_AdditionalInfo :=
(
    WITH offenders AS
    (
        SELECT
            n.nspname                             AS schema_name,
            c.relname                              AS table_name,
            con.conname                            AS constraint_name,
            CASE con.contype
                WHEN 'f' THEN 'FOREIGN KEY'
                WHEN 'c' THEN 'CHECK'
            END                                     AS constraint_type,
            pg_get_constraintdef(con.oid)           AS constraint_definition
        FROM   pg_catalog.pg_constraint con
        JOIN   pg_catalog.pg_class      c   ON c.oid = con.conrelid
        JOIN   pg_catalog.pg_namespace  n   ON n.oid = c.relnamespace
        WHERE  con.contype IN ('c', 'f')
        AND    con.convalidated = false
        AND    con.conrelid <> 0
        AND    c.relkind IN ('r', 'p')
        AND    n.nspname NOT IN ('pg_catalog', 'information_schema')
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM offenders) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'OffenderCount', (SELECT count(*) FROM offenders),
                'Offenders',     (SELECT jsonb_agg(to_jsonb(o) ORDER BY o.schema_name, o.table_name, o.constraint_name)
                                  FROM (SELECT * FROM offenders LIMIT 50) o),
                'FindingReason', 'One or more CHECK or FOREIGN KEY constraints are marked NOT VALID: PostgreSQL enforces them only for rows inserted or updated after the constraint was created, and has never verified that pre-existing rows satisfy them.'
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No CHECK or FOREIGN KEY constraints are marked NOT VALID; every such constraint has been validated against the data currently in its table.'
        ELSE
            'Run ALTER TABLE <table> VALIDATE CONSTRAINT <name> for each flagged constraint so PostgreSQL confirms existing rows satisfy it. This takes only a SHARE UPDATE EXCLUSIVE lock and does not block normal reads or writes.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
