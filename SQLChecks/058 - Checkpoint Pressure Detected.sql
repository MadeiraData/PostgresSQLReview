
/* DESCRIPTION:
   What This Means: checkpoint pressure was detected. PostgreSQL statistics
   show that checkpoints are occurring because WAL volume reaches max_wal_size,
   not only because checkpoint_timeout is reached.

   WHY THIS MATTERS:
   Frequent requested checkpoints can create write spikes, increase I/O
   pressure, reduce throughput, and cause latency instability. This often
   indicates that max_wal_size is too small for the WAL generation rate, or that
   checkpoint tuning and storage performance should be reviewed.

   Recommendations:
   Review pg_stat_bgwriter checkpoint activity together with max_wal_size,
   checkpoint_timeout, checkpoint_completion_target, log_checkpoints, WAL
   generation rate, and storage latency. Consider increasing max_wal_size if
   checkpoints are frequently requested before checkpoint_timeout is reached.

   Scope : Cluster-level
   Category : Backup

   REFERENCES:
   https://www.postgresql.org/docs/current/monitoring-stats.html
   https://www.postgresql.org/docs/current/runtime-config-wal.html
   https://www.postgresql.org/docs/current/wal-configuration.html
*/

v_AdditionalInfo := (
    WITH checkpoint_stats AS (
        SELECT
            checkpoints_timed,
            checkpoints_req,
            checkpoint_write_time,
            checkpoint_sync_time,
            buffers_checkpoint,
            buffers_clean,
            maxwritten_clean,
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
          OR requested_checkpoint_ratio < 0.25
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
            'BuffersClean',
                buffers_clean,
            'MaxwrittenClean',
                maxwritten_clean,
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
            'CheckpointTimeout',
                current_setting('checkpoint_timeout', true),
            'CheckpointCompletionTarget',
                current_setting('checkpoint_completion_target', true),
            'LogCheckpoints',
                current_setting('log_checkpoints', true),
            'FindingReason',
                'A significant portion of checkpoints are requested checkpoints, which may indicate checkpoint pressure from WAL volume.'
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
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Checkpoint pressure was not detected based on pg_stat_bgwriter requested checkpoint activity.'
        ELSE
            'Review checkpoint pressure and consider increasing max_wal_size or tuning checkpoint behavior if requested checkpoints are frequent.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';