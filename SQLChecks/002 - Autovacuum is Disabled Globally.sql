
/*
    DESCRIPTION:
        Maintenance: autovacuum is disabled globally.
        This can cause bloat, stale statistics, and wraparound risk.

    Remediation:
        Enable autovacuum unless a documented manual maintenance process exists.
        Review autovacuum settings before changing cluster-wide configuration.

    More info:
        https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
        https://www.postgresql.org/docs/current/routine-vacuuming.html
*/

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN current_setting('autovacuum', true) = 'on'
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'Autovacuum', current_setting('autovacuum', true),
                    'TrackCounts', current_setting('track_counts', true),
                    'FindingReason', 'autovacuum is disabled at the PostgreSQL cluster level.'
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
    'Maintenance',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Autovacuum is enabled globally.'
        ELSE
            'Enable autovacuum globally unless there is a documented and reliable manual maintenance process.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';

