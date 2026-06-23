/*
    ====================================================================================
    PostgreSQL Review - Template Footer

    Purpose: Generate the final PostgreSQL Review output as a single JSON document.

    This footer collects:
        - System introduction data collected by Template_Header.sql
        - Review score
        - Summary counters
        - Failed checks that require attention
        - Passed checks that do not require attention
        - Check execution errors
        - Header collection errors

    Important:
        This file should be included at the end of the generated script: PostgreSQL_Review_Full_Check_Script.sql

    Expected flow:
        Template_Header.sql
        SQLChecks\*.sql
        Template_Footer.sql

    Notes:
        - This footer should be the only section that returns the final result.
        - Header and individual check scripts should not return final output directly.
        - This makes pgAdmin and psql execution easier.
    ====================================================================================
*/

/*
    ====================================================================================
    Footer section - Final JSON output
    ====================================================================================
*/

WITH
score AS
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL
            WHEN SUM(WorstCaseImpact) IS NULL OR SUM(WorstCaseImpact) = 0 THEN NULL
            ELSE
                GREATEST
                (
                    0,
                    LEAST
                    (
                        100,
                        ROUND
                        (
                            100
                            -
                            (
                                COALESCE(SUM(CurrentStateImpact), 0)::numeric
                                / NULLIF(SUM(WorstCaseImpact), 0)::numeric
                            ) * 100
                        )::integer
                    )
                )
        END AS ClusterScore
    FROM pg_review_results
),
summary AS
(
    SELECT
        COUNT(*) AS TotalChecks,
        COUNT(*) FILTER (WHERE RequiresAttention = true) AS FailedChecksCount,
        COUNT(*) FILTER (WHERE RequiresAttention = false) AS PassedChecksCount,
        COUNT(*) FILTER (WHERE RequiresAttention = true AND CurrentStateImpact = 3) AS HighImpactFindings,
        COUNT(*) FILTER (WHERE RequiresAttention = true AND CurrentStateImpact = 2) AS MediumImpactFindings,
        COUNT(*) FILTER (WHERE RequiresAttention = true AND CurrentStateImpact = 1) AS LowImpactFindings,
        COUNT(*) FILTER (WHERE RequiresAttention = true AND RecommendationEffort = 3) AS HighEffortRecommendations,
        COUNT(*) FILTER (WHERE RequiresAttention = true AND RecommendationRisk = 3) AS HighRiskRecommendations,
        (SELECT COUNT(*) FROM pg_review_errors) AS CheckErrorsCount
    FROM pg_review_results
),
score_note AS
(
    SELECT
        CASE
            WHEN (SELECT COUNT(*) FROM pg_review_results) = 0
                THEN 'No checks were executed. Score is NULL.'
            WHEN (SELECT COUNT(*) FROM pg_review_errors) > 0
                THEN 'Some checks failed to execute and are reported in CheckErrors. Failed checks are not included in the score calculation.'
            ELSE
                'Score is calculated from checks that executed successfully.'
        END AS ScoreNote
),
system_introduction AS
(
    SELECT jsonb_build_object
    (
        'HostVisibility',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_host_visibility t LIMIT 1),
                '{}'::jsonb
            ),

        'ServerIdentity',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_server_identity t LIMIT 1),
                '{}'::jsonb
            ),

        'DistributionDetection',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_distribution_detection t LIMIT 1),
                '{}'::jsonb
            ),

        'ExecutionContext',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_execution_context t LIMIT 1),
                '{}'::jsonb
            ),

        'Licensing',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_licensing t LIMIT 1),
                '{}'::jsonb
            ),

        'Databases',
            COALESCE
            (
                (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.DatabaseName) FROM pg_review_header_databases t),
                '[]'::jsonb
            ),

        'CurrentDatabaseSession',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_current_database_session t LIMIT 1),
                '{}'::jsonb
            ),

        'ImportantSettings',
            COALESCE
            (
                (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.SettingName) FROM pg_review_header_important_settings t),
                '[]'::jsonb
            ),

        'Tablespaces',
            COALESCE
            (
                (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.TablespaceName) FROM pg_review_header_tablespaces t),
                '[]'::jsonb
            ),

        'Extensions',
            COALESCE
            (
                (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.ExtensionName) FROM pg_review_header_extensions t),
                '[]'::jsonb
            ),

        'DatabaseStatistics',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_database_statistics t LIMIT 1),
                '{}'::jsonb
            ),

        'ActivitySummary',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_activity_summary t LIMIT 1),
                '{}'::jsonb
            ),

        'ReplicationState',
            COALESCE
            (
                (SELECT to_jsonb(t) FROM pg_review_header_replication_state t LIMIT 1),
                '{}'::jsonb
            ),

        'Capabilities',
            COALESCE
            (
                (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.CapabilityName) FROM pg_review_header_capabilities t),
                '[]'::jsonb
            )
    ) AS SystemIntroduction
),
failed_checks AS
(
    SELECT
        COALESCE
        (
            jsonb_agg
            (
                jsonb_build_object
                (
                    'CheckId', CheckId,
                    'Title', Title,
                    'Category', Category,
                    'Scope', Scope,
                    'Impact', CurrentStateImpact,
                    'WorstCaseImpact', WorstCaseImpact,
                    'RecommendationEffort', RecommendationEffort,
                    'RecommendationRisk', RecommendationRisk,
                    'Recommendation', Recommendation,
                    'AdditionalInfo', AdditionalInfo,
                    'ResponsibleDbaTeam', ResponsibleDbaTeam
                )
                ORDER BY
                    CurrentStateImpact DESC,
                    RecommendationRisk DESC,
                    RecommendationEffort DESC,
                    CheckId ASC
            ),
            '[]'::jsonb
        ) AS FailedChecks
    FROM pg_review_results
    WHERE RequiresAttention = true
),
passed_checks AS
(
    SELECT
        COALESCE
        (
            jsonb_agg
            (
                jsonb_build_object
                (
                    'CheckId', CheckId,
                    'Title', Title,
                    'Category', Category,
                    'Scope', Scope,
                    'AdditionalInfo', AdditionalInfo
                )
                ORDER BY CheckId ASC
            ),
            '[]'::jsonb
        ) AS PassedChecks
    FROM pg_review_results
    WHERE RequiresAttention = false
),
check_errors AS
(
    SELECT
        COALESCE
        (
            jsonb_agg
            (
                jsonb_build_object
                (
                    'CheckId', CheckId,
                    'Title', Title,
                    'ErrorSqlState', ErrorSqlState,
                    'ErrorMessage', ErrorMessage,
                    'ErrorDetail', ErrorDetail,
                    'ErrorHint', ErrorHint,
                    'ErrorContext', ErrorContext,
                    'IsDeadlockRetry', IsDeadlockRetry,
                    'ErrorTime', ErrorTime
                )
                ORDER BY ErrorTime ASC, CheckId ASC
            ),
            '[]'::jsonb
        ) AS CheckErrors
    FROM pg_review_errors
),
header_errors AS
(
    SELECT
        COALESCE
        (
            jsonb_agg
            (
                jsonb_build_object
                (
                    'SectionName', SectionName,
                    'ErrorMessage', ErrorMessage,
                    'ErrorTime', ErrorTime
                )
                ORDER BY ErrorTime ASC, SectionName ASC
            ),
            '[]'::jsonb
        ) AS HeaderErrors
    FROM pg_review_header_errors
),
review_warnings AS
(
    SELECT jsonb_build_array
    (
        'PostgreSQL distribution/flavor detection is best-effort and may not be fully accurate in managed services.',
        'Some checks are cluster-level, while table, index, schema, pg_stat_statements, and database statistics checks apply to the current database.',
        'Session, lock, connection, and transaction findings are snapshot-based and should be correlated with monitoring data.',
        'Some findings are based on cumulative PostgreSQL statistics since the last statistics reset.',
        'Checks that fail to execute are reported in CheckErrors and are not included in the score calculation.',
        'PostgreSQL does not expose full operating system and hardware inventory through standard SQL.'
    ) AS ReviewWarnings
)
SELECT
    jsonb_pretty
    (
        jsonb_build_object
        (
            'AssessmentType', 'PostgreSQL Review',
            'ReviewGeneratedAt', now(),
            'ReviewScriptName', 'PostgreSQL_Review_Full_Check_Script.sql',

            'PostgreSQLClusterName',
                COALESCE
                (
                    (
                        SELECT PostgreSQLClusterName
                        FROM pg_review_header_server_identity
                        LIMIT 1
                    ),
                    'Not provided'
                ),

            'CurrentDatabase',
                current_database(),

            'ExecutedBy',
                current_user,

            'ClusterScore',
                score.ClusterScore,

            'ScoreNote',
                score_note.ScoreNote,

            'Summary',
                jsonb_build_object
                (
                    'TotalChecks', summary.TotalChecks,
                    'FailedChecksCount', summary.FailedChecksCount,
                    'PassedChecksCount', summary.PassedChecksCount,
                    'HighImpactFindings', summary.HighImpactFindings,
                    'MediumImpactFindings', summary.MediumImpactFindings,
                    'LowImpactFindings', summary.LowImpactFindings,
                    'HighEffortRecommendations', summary.HighEffortRecommendations,
                    'HighRiskRecommendations', summary.HighRiskRecommendations,
                    'CheckErrorsCount', summary.CheckErrorsCount
                ),

            'SystemIntroduction',
                system_introduction.SystemIntroduction,

            'ReviewWarnings',
                review_warnings.ReviewWarnings,

            'FailedChecksThatRequireAttention',
                failed_checks.FailedChecks,

            'PassedChecksThatDoNotRequireAttention',
                passed_checks.PassedChecks,

            'CheckErrors',
                check_errors.CheckErrors,

            'HeaderErrors',
                header_errors.HeaderErrors
        )
    ) AS postgresql_review_json
FROM score
CROSS JOIN summary
CROSS JOIN score_note
CROSS JOIN system_introduction
CROSS JOIN review_warnings
CROSS JOIN failed_checks
CROSS JOIN passed_checks
CROSS JOIN check_errors
CROSS JOIN header_errors;