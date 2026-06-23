/* DESCRIPTION:
   Configuration: statement_timeout is not configured. This allows queries to
   run indefinitely unless they are cancelled manually or terminated by another
   mechanism.

   WHY THIS MATTERS:
   Runaway queries, inefficient execution plans, application bugs, or accidental
   full-table operations can consume CPU, memory, I/O, and locks for extended
   periods. A statement timeout provides a safety mechanism that helps prevent
   individual queries from impacting overall database availability.

   REMEDIATION:
   Configure statement_timeout to a value appropriate for the workload.
   Consider applying different timeout values at the role, database, or
   application level rather than a single global setting. Validate application
   behavior before enabling timeouts in production.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-client.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN pg_size_bytes(current_setting('statement_timeout')) > 0
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'StatementTimeout',
                current_setting('statement_timeout', true),
            'FindingReason',
                'statement_timeout is set to 0, allowing queries to run without a timeout.'
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
    'Configuration',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'statement_timeout is configured.'
        ELSE
            'Consider configuring statement_timeout to prevent runaway queries from consuming resources indefinitely.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';