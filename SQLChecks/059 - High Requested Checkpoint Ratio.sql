/* DESCRIPTION:
   WAL and checkpoints: a high requested checkpoint ratio was detected.
   PostgreSQL statistics show that a significant portion of checkpoints were
   requested checkpoints rather than timed checkpoints.

   WHY THIS MATTERS:
   Requested checkpoints usually occur when WAL volume reaches max_wal_size
   before checkpoint_timeout is reached. A high requested checkpoint ratio can
   indicate that max_wal_size is too small for the workload, WAL generation is
   high, or checkpoint tuning should be reviewed. This can lead to write I/O
   spikes and latency instability.

   REMEDIATION:
   Review max_wal_size, checkpoint_timeout, checkpoint_completion_target,
   WAL generation rate, log_checkpoints output, and storage latency. Consider
   increasing max_wal_size if requested checkpoints are frequent and caused by
   normal WAL volume rather than unusual workload spikes.

   REFERENCES:
   https://www.postgresql.org/docs/current/monitoring-stats.html
   https://www.postgresql.org/docs/current/wal-configuration.html
   https://www.postgresql.org/docs/current/runtime-config-wal.html
*/

v_AdditionalInfo := (
    WITH checkpoint_stats AS (
        SELECT
            checkpoints_timed,
            checkpoints_req,
            checkpoint_write_time,
            checkpoint_sync_time,
            buffers_checkpoint,
            buffers_backend,
            buffers_backend_fsync,
            buffers_alloc,
            stats_reset,
            CASE
                WHEN (checkpoints_timed + checkpoints_req) > 0
                    THEN round(
                        checkpoints_req::numeric
                        / (checkpoints_timed + checkpoints_req)::numeric,
                        4
                    )
                ELSE 0
            END AS requested_checkpoint_ratio
        FROM pg_stat_bgwriter
    )
    SELECT CASE
        WHEN checkpoints_req < 10
          OR requested_checkpoint_ratio < 0.50
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'CheckpointsTimed',
                checkpoints_timed,
            'CheckpointsRequested',
                checkpoints_req,
            'RequestedCheckpointRatio',
                requested_checkpoint_ratio,
            'CheckpointWriteTimeMs',
                checkpoint_write_time,
            'CheckpointSyncTimeMs',
                checkpoint_sync_time,
            'BuffersCheckpoint',
                buffers_checkpoint,
            'BuffersBackend',
                buffers_backend,
            'BuffersBackendFsync',
                buffers_backend_fsync,
            'BuffersAlloc',
                buffers_alloc,
            'StatsReset',
                stats_reset,
            'MaxWalSize',
                current_setting('max_wal_size', true),
            'MinWalSize',
                current_setting('min_wal_size', true),
            'CheckpointTimeout',
                current_setting('checkpoint_timeout', true),
            'CheckpointCompletionTarget',
                current_setting('checkpoint_completion_target', true),
            'FindingReason',
                'More than 50% of checkpoints are requested checkpoints, indicating that checkpoints are often triggered by WAL volume before checkpoint_timeout.'
        )
    END
    FROM checkpoint_stats
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
            THEN 'Requested checkpoint ratio is within the expected review threshold.'
        ELSE
            'Review requested checkpoint frequency and consider increasing max_wal_size or tuning checkpoint behavior if requested checkpoints are frequent.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';