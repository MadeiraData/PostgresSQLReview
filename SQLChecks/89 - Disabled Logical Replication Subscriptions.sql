/*
    DESCRIPTION:

    What This Means: one or more logical replication subscriptions on this
        database are disabled (pg_subscription.subenabled = false), meaning
        their apply worker is not running and no changes are being replicated
        from the publisher. A subscription can end up disabled two ways: an
        administrator ran ALTER SUBSCRIPTION ... DISABLE (often for planned
        maintenance) and never re-enabled it, or PostgreSQL's own
        disable_on_error feature automatically disabled it after the apply
        worker hit a replication conflict or error, to stop it from looping
        forever on the same failure. Either way there is no crash and no
        obvious symptom to the application - the subscriber simply stops
        receiving changes and silently falls further and further behind the
        publisher with every passing minute. If this subscriber is later
        queried for reporting, promoted, used as a migration cutover target,
        or relied on for failover, it can be missing an unknown and growing
        amount of data with nothing in its own state to flag that gap.

    Recommendations:
        Check the PostgreSQL server log around the time the subscription
        stopped for the apply worker error that caused it (constraint
        violation, missing replica identity, schema mismatch, or a manual
        DISABLE). Resolve the underlying cause first - blindly re-enabling a
        subscription that was auto-disabled by disable_on_error can simply
        hit the same conflict again. Once resolved, re-enable it with
        ALTER SUBSCRIPTION <name> ENABLE and confirm it is catching up via
        pg_stat_subscription. If the subscription was deliberately disabled
        on purpose (for example, paused ahead of a planned cutover), no
        further action is required beyond confirming that is still the
        intended state.

    Scope : Database-level
    Category : Replication

    More info:
        https://www.postgresql.org/docs/current/logical-replication-subscription.html
        https://www.postgresql.org/docs/current/sql-altersubscription.html
        https://www.postgresql.org/docs/current/logical-replication-conflicts.html
*/

v_AdditionalInfo :=
(
    WITH disabled_subscriptions AS
    (
        SELECT
            s.subname,
            s.subpublications,
            s.subdisableonerr,
            s.subslotname
        FROM pg_catalog.pg_subscription s
        WHERE s.subdbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database())
          AND s.subenabled = false
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM disabled_subscriptions) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'DisabledSubscriptionCount', (SELECT count(*) FROM disabled_subscriptions),
                'DisabledSubscriptions', (SELECT jsonb_agg(to_jsonb(d)) FROM disabled_subscriptions d),
                'FindingReason', 'One or more logical replication subscriptions are disabled, so their apply workers are not running and no changes are being replicated from the publisher.'
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
    'Replication',                                               -- Category
    'Database-level',                                            -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No logical replication subscriptions on this database are disabled.'
        ELSE
            'Diagnose why the listed subscription(s) are disabled from the server log (a replication conflict, an apply-worker error, or a deliberate ALTER SUBSCRIPTION ... DISABLE), resolve the underlying cause, then re-enable with ALTER SUBSCRIPTION <name> ENABLE and confirm it catches up via pg_stat_subscription.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
