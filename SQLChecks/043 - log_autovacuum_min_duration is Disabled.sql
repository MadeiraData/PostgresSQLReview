
/* DESCRIPTION:
   What This Means: log_autovacuum_min_duration is disabled. PostgreSQL is not
   configured to log autovacuum activity.

   WHY THIS MATTERS:
   Autovacuum logging helps identify tables with heavy churn, slow vacuum
   activity, frequent analyze operations, dead tuple accumulation, wraparound
   prevention activity, and maintenance pressure. Without it, it is harder to
   troubleshoot table bloat, stale statistics, and autovacuum performance issues.

   Recommendations:
   Configure log_autovacuum_min_duration to an appropriate threshold. A common
   starting value is several seconds, such as 5000 ms or 10000 ms, to capture
   expensive autovacuum activity without excessive logging. Use 0 temporarily
   when deeper autovacuum diagnostics are required.

   Scope : Cluster-level
   Category : Monitoring

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-logging.html
   https://www.postgresql.org/docs/current/routine-vacuuming.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('log_autovacuum_min_duration', true)::integer >= 0
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'LogAutovacuumMinDuration',
                current_setting('log_autovacuum_min_duration', true),
            'Autovacuum',
                current_setting('autovacuum', true),
            'AutovacuumNaptime',
                current_setting('autovacuum_naptime', true),
            'FindingReason',
                'log_autovacuum_min_duration is disabled (-1), so autovacuum activity is not being logged.'
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
    'Observability',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'log_autovacuum_min_duration is configured.'
        ELSE
            'Configure log_autovacuum_min_duration to improve visibility into autovacuum activity and table maintenance behavior.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';