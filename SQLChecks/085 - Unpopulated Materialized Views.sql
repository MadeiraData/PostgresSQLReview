/*
    DESCRIPTION:

    What This Means: A materialized view created with CREATE MATERIALIZED VIEW
        ... WITH NO DATA (or last refreshed with REFRESH MATERIALIZED VIEW ...
        WITH NO DATA) stores no rows at all until an explicit REFRESH
        MATERIALIZED VIEW is run without that clause. PostgreSQL tracks this
        directly in pg_matviews.ispopulated. Unlike a normal view, a
        materialized view is a physical relation: querying an unpopulated one
        does not return an empty result set, it raises "ERROR: materialized
        view ... has not been populated / HINT: Use the REFRESH MATERIALIZED
        VIEW command." on every single SELECT, join, or dependent view or
        function that touches it. This is a common deployment mistake -- a
        migration or seed script creates the view WITH NO DATA to avoid a slow
        build during a schema change, and the follow-up REFRESH step is
        forgotten, fails silently, or is never wired into the job that is
        supposed to keep the view current. The result is not stale data or a
        performance regression, it is a hard, immediate failure for every
        application code path, report, or downstream object that reads the
        materialized view, and it keeps failing indefinitely until someone
        runs REFRESH MATERIALIZED VIEW by hand.

    Recommendations:
        For each flagged materialized view, run REFRESH MATERIALIZED VIEW
        <schema>.<view>; to populate it before anything depends on it. Use
        REFRESH MATERIALIZED VIEW CONCURRENTLY <schema>.<view>; instead if a
        unique index already exists on the view and the ACCESS EXCLUSIVE lock
        taken by the plain form is unacceptable -- CONCURRENTLY requires that
        unique index and also requires the view to already have been
        populated once, so the very first refresh of a never-populated view
        must use the plain form. Add the view to whatever scheduled job or
        deployment step is meant to keep its data current, so this state
        cannot silently recur. If a listed view is an intentional placeholder
        that nothing should query yet, drop it or document that explicitly
        rather than leaving an unpopulated view reachable by applications.

    Scope : Database-level
    Category : Maintenance

    More info:
        https://www.postgresql.org/docs/current/sql-creatematerializedview.html
        https://www.postgresql.org/docs/current/sql-refreshmaterializedview.html
        https://www.postgresql.org/docs/current/view-pg-matviews.html
*/

v_AdditionalInfo :=
(
    WITH offenders AS
    (
        SELECT
            schemaname,
            matviewname,
            matviewowner,
            hasindexes
        FROM   pg_catalog.pg_matviews
        WHERE  NOT ispopulated
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM offenders) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'OffenderCount', (SELECT count(*) FROM offenders),
                'MaterializedViews', (SELECT jsonb_agg(to_jsonb(o)) FROM offenders o),
                'FindingReason', 'One or more materialized views have never been populated (created or last refreshed WITH NO DATA), so any query against them fails immediately with "materialized view ... has not been populated".'
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
    'Maintenance',                                               -- Category
    'Database-level',                                            -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,        -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,        -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,        -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'All materialized views in the database are currently populated.'
        ELSE
            'Run REFRESH MATERIALIZED VIEW on each listed view to populate it before applications rely on it, and ensure it is included in whatever job keeps its data current.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
