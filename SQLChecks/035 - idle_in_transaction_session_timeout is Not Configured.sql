
/* DESCRIPTION:
   What This Means: idle_in_transaction_session_timeout is not configured. This
   allows sessions that are idle while holding an open transaction to remain
   open indefinitely.

   WHY THIS MATTERS:
   Idle transactions can hold locks, prevent vacuum cleanup, retain old row
   versions, increase table and index bloat, and contribute to transaction ID
   wraparound risk. They can also block DDL and other application activity.

   Recommendations:
   Configure idle_in_transaction_session_timeout to a reasonable value based on
   application behavior. Common starting values are several minutes for OLTP
   systems, but the value should be tested to avoid interrupting legitimate
   long-running workflows.

   Scope : Cluster-level
   Category : Performance

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-client.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN pg_size_bytes(current_setting('idle_in_transaction_session_timeout')) > 0
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'IdleInTransactionSessionTimeout',
                current_setting('idle_in_transaction_session_timeout', true),
            'FindingReason',
                'idle_in_transaction_session_timeout is set to 0, meaning idle transactions are allowed to remain open indefinitely.'
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'idle_in_transaction_session_timeout is configured.'
        ELSE
            'Configure idle_in_transaction_session_timeout to prevent idle transactions from remaining open indefinitely.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';