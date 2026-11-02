/*
    DESCRIPTION:

    What This Means: One or more triggers on user tables have been explicitly
        disabled (ALTER TABLE ... DISABLE TRIGGER, or the equivalent single-
        trigger form) and no longer fire at all during normal application
        traffic. PostgreSQL keeps a disabled trigger fully defined in the
        catalog -- it still shows up in \d, still appears to exist to anyone
        who does not specifically check whether it is enabled -- but it
        silently stops running on every INSERT, UPDATE, or DELETE that would
        have fired it. There is no error, no warning, and no log entry at the
        moment a disabled trigger is skipped. Whatever business logic that
        trigger enforced -- audit/changelog trail, computed or denormalized
        column maintenance, trigger-based referential integrity, row-level
        security emulation, or trigger-based replication feeds (e.g. Slony,
        Londiste) -- stops happening the instant the trigger is disabled, and
        every row written afterward is written without it. PostgreSQL's own
        documentation for ALTER TABLE warns that disabling an internally
        generated constraint trigger means "the constraint will not be
        enforced any more", and a documented behavior (PostgreSQL bug #18516)
        shows that re-enabling a disabled trigger later does NOT retroactively
        validate or reconcile rows written while it was off -- the gap it left
        behind is permanent unless someone separately audits and backfills the
        affected rows. A table can accumulate this exposure for months with
        every query against it returning fine, because the data it holds
        simply never had the trigger's logic applied in the first place.

    Recommendations:
        For each flagged trigger, confirm with the owning application team
        whether it was disabled intentionally (for example, to speed up a
        bulk load) and, if so, whether it has already been re-enabled.
        Re-enable it with "ALTER TABLE <table> ENABLE TRIGGER <name>;" once
        the reason for disabling it no longer applies. Because re-enabling
        does not retroactively run the trigger against rows written while it
        was disabled, also assess whether a backfill or reconciliation query
        is needed to repair any audit trail, computed column, or referential
        integrity gap the disabled window left behind. If a trigger is
        intentionally disabled long-term (for example, an inapplicable legacy
        constraint trigger), document that decision so it is not mistaken for
        an oversight on the next review.

    Scope : Database-level
    Category : Data Integrity

    More info:
        https://www.postgresql.org/docs/current/sql-altertable.html
        https://www.postgresql.org/docs/current/catalog-pg-trigger.html
        https://www.postgresql.org/docs/current/sql-createtrigger.html
*/

v_AdditionalInfo :=
(
    WITH offenders AS
    (
        SELECT
            n.nspname                              AS schema_name,
            c.relname                               AS table_name,
            t.tgname                                AS trigger_name,
            p.proname                               AS function_name
        FROM   pg_catalog.pg_trigger    t
        JOIN   pg_catalog.pg_class      c   ON c.oid = t.tgrelid
        JOIN   pg_catalog.pg_namespace  n   ON n.oid = c.relnamespace
        JOIN   pg_catalog.pg_proc       p   ON p.oid = t.tgfoid
        WHERE  t.tgenabled = 'D'
        AND    t.tgisinternal = false
        AND    c.relkind IN ('r', 'p')
        AND    n.nspname NOT IN ('pg_catalog', 'information_schema')
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM offenders) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'OffenderCount', (SELECT count(*) FROM offenders),
                'Offenders',     (SELECT jsonb_agg(to_jsonb(o) ORDER BY o.schema_name, o.table_name, o.trigger_name)
                                  FROM (SELECT * FROM offenders LIMIT 50) o),
                'FindingReason', 'One or more user-defined triggers are disabled (tgenabled = ''D''): PostgreSQL keeps them defined but silently skips them on every INSERT/UPDATE/DELETE, so whatever logic they enforced has not run since they were disabled.'
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
            THEN 'No user-defined triggers on user tables are disabled; all are active and will fire normally.'
        ELSE
            'Review each disabled trigger with the owning application team, re-enable it with ALTER TABLE <table> ENABLE TRIGGER <name> once the reason for disabling it no longer applies, and assess whether rows written while it was disabled need a backfill or reconciliation pass, since re-enabling does not retroactively apply the trigger to them.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production/Development';
