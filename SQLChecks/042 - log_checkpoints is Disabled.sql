/* DESCRIPTION:
   Observability: log_checkpoints is disabled. PostgreSQL is not configured to
   log checkpoint activity.

   WHY THIS MATTERS:
   Checkpoint logging helps identify checkpoint frequency, write pressure,
   sync time, and potential I/O spikes. Without it, it is harder to diagnose
   performance issues related to checkpoint tuning, WAL volume, storage latency,
   or sudden bursts of disk writes.

   REMEDIATION:
   Enable log_checkpoints to improve visibility into checkpoint behavior.
   Review checkpoint_timeout, max_wal_size, checkpoint_completion_target, and
   storage performance when checkpoint activity appears excessive.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-logging.html
   https://www.postgresql.org/docs/current/wal-configuration.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('log_checkpoints', true) = 'on'
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'LogCheckpoints',
                current_setting('log_checkpoints', true),
            'CheckpointTimeout',
                current_setting('checkpoint_timeout', true),
            'MaxWalSize',
                current_setting('max_wal_size', true),
            'CheckpointCompletionTarget',
                current_setting('checkpoint_completion_target', true),
            'FindingReason',
                'log_checkpoints is disabled, so PostgreSQL is not logging checkpoint activity.'
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
            THEN 'log_checkpoints is enabled.'
        ELSE
            'Enable log_checkpoints to improve visibility into checkpoint frequency, checkpoint duration, and storage write pressure.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';