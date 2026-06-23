/* DESCRIPTION:
   Observability: slow statement logging is disabled. PostgreSQL is not
   configured to log long-running statements.

   WHY THIS MATTERS:
   Slow query logging is one of the most effective methods for identifying
   inefficient SQL statements, missing indexes, plan regressions, application
   bottlenecks, and workload changes. Without it, performance troubleshooting
   often requires reactive investigation after issues occur.

   REMEDIATION:
   Configure log_min_duration_statement to an appropriate threshold for the
   workload. Common starting values range from 500 ms to several seconds,
   depending on application requirements and logging volume considerations.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-logging.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('log_min_duration_statement', true)::integer >= 0
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'LogMinDurationStatement',
                current_setting('log_min_duration_statement', true),
            'FindingReason',
                'log_min_duration_statement is disabled (-1), so slow statements are not being logged.'
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
            THEN 'Slow statement logging is configured.'
        ELSE
            'Consider configuring log_min_duration_statement to capture long-running queries and improve performance troubleshooting capabilities.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';