/* DESCRIPTION:
   WAL configuration: max_wal_size appears to be too small. A low max_wal_size
   can cause PostgreSQL to perform checkpoints too frequently.

   WHY THIS MATTERS:
   Frequent checkpoints can increase I/O pressure, reduce write performance,
   create latency spikes, and increase WAL recycling overhead. On busy systems,
   a small max_wal_size may prevent PostgreSQL from spreading checkpoint writes
   smoothly over time.

   REMEDIATION:
   Review max_wal_size together with checkpoint frequency, checkpoint_timeout,
   checkpoint_completion_target, WAL generation rate, storage performance, and
   available disk capacity. Consider increasing max_wal_size if checkpoints are
   occurring too frequently or are caused by WAL volume rather than timeout.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-wal.html
   https://www.postgresql.org/docs/current/wal-configuration.html
   https://www.postgresql.org/docs/current/runtime-config-logging.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN pg_size_bytes(current_setting('max_wal_size')) >= 1073741824 -- 1 GB
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'MaxWalSize',
                current_setting('max_wal_size', true),
            'MaxWalSizeBytes',
                pg_size_bytes(current_setting('max_wal_size')),
            'MinWalSize',
                current_setting('min_wal_size', true),
            'CheckpointTimeout',
                current_setting('checkpoint_timeout', true),
            'CheckpointCompletionTarget',
                current_setting('checkpoint_completion_target', true),
            'LogCheckpoints',
                current_setting('log_checkpoints', true),
            'FindingReason',
                'max_wal_size is configured below 1 GB, which may cause frequent checkpoints on write-active PostgreSQL systems.'
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
    'WAL and Checkpoints',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'max_wal_size does not appear to be too small.'
        ELSE
            'Review max_wal_size and consider increasing it if checkpoint activity is too frequent for the workload.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';