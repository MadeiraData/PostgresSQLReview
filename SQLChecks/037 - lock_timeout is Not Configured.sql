/* DESCRIPTION:
   Configuration: lock_timeout is not configured. This allows sessions to wait
   indefinitely when attempting to acquire locks held by other transactions.

   WHY THIS MATTERS:
   Long lock waits can lead to application slowdowns, blocked sessions, reduced
   throughput, and operational incidents. A lock timeout helps prevent sessions
   from waiting forever on lock contention and allows applications to handle
   blocking situations more predictably.

   REMEDIATION:
   Consider configuring lock_timeout to a value appropriate for the workload.
   Evaluate application retry logic and transaction patterns before enabling
   lock timeouts in production. Different values may be appropriate at the
   role, database, or application level.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-client.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN pg_size_bytes(current_setting('lock_timeout')) > 0
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'LockTimeout',
                current_setting('lock_timeout', true),
            'FindingReason',
                'lock_timeout is set to 0, allowing sessions to wait indefinitely for locks.'
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
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'lock_timeout is configured.'
        ELSE
            'Consider configuring lock_timeout to prevent sessions from waiting indefinitely on lock contention.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';