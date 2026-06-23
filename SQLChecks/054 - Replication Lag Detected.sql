/* DESCRIPTION:
   Replication: replication lag was detected. One or more connected replicas
   appear to be behind the primary based on WAL write, flush, replay, or byte
   lag information.

   WHY THIS MATTERS:
   Replication lag can increase recovery point exposure, delay read replica
   visibility, affect failover readiness, and cause stale reads for applications
   using replicas. Large or growing lag may indicate network issues, slow
   storage, replica resource pressure, long-running queries, or WAL apply
   bottlenecks.

   REMEDIATION:
   Review replication lag together with replica health, network latency,
   storage performance, WAL generation rate, long-running queries on replicas,
   replication slots, and PostgreSQL logs. Investigate replicas with high or
   increasing lag and confirm whether they are suitable for failover or reads.

   REFERENCES:
   https://www.postgresql.org/docs/current/monitoring-stats.html
   https://www.postgresql.org/docs/current/warm-standby.html
   https://www.postgresql.org/docs/current/view-pg-stat-replication.html
*/

v_AdditionalInfo := (
    WITH replication_lag AS (
        SELECT
            pid,
            usename AS user_name,
            application_name,
            client_addr::text AS client_address,
            state,
            sync_state,
            sent_lsn,
            write_lsn,
            flush_lsn,
            replay_lsn,
            write_lag,
            flush_lag,
            replay_lag,
            pg_wal_lsn_diff(sent_lsn, write_lsn) AS write_lag_bytes,
            pg_wal_lsn_diff(sent_lsn, flush_lsn) AS flush_lag_bytes,
            pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes
        FROM pg_stat_replication
        WHERE state IS DISTINCT FROM 'streaming'
           OR COALESCE(pg_wal_lsn_diff(sent_lsn, write_lsn), 0) > 104857600
           OR COALESCE(pg_wal_lsn_diff(sent_lsn, flush_lsn), 0) > 104857600
           OR COALESCE(pg_wal_lsn_diff(sent_lsn, replay_lsn), 0) > 104857600
           OR write_lag > interval '5 minutes'
           OR flush_lag > interval '5 minutes'
           OR replay_lag > interval '5 minutes'
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM replication_lag)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'ReplicationLagDetected',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'Pid', pid,
                        'UserName', user_name,
                        'ApplicationName', application_name,
                        'ClientAddress', client_address,
                        'State', state,
                        'SyncState', sync_state,
                        'SentLsn', sent_lsn,
                        'WriteLsn', write_lsn,
                        'FlushLsn', flush_lsn,
                        'ReplayLsn', replay_lsn,
                        'WriteLag', write_lag,
                        'FlushLag', flush_lag,
                        'ReplayLag', replay_lag,
                        'WriteLagBytes', write_lag_bytes,
                        'FlushLagBytes', flush_lag_bytes,
                        'ReplayLagBytes', replay_lag_bytes
                    )
                    ORDER BY replay_lag_bytes DESC NULLS LAST
                )
                FROM replication_lag
            ),
            'FindingReason',
            'One or more replicas are not streaming normally or exceed the replication lag review threshold.'
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
    'Replication',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No replication lag exceeded the review threshold for connected replicas.'
        ELSE
            'Investigate replicas with lag or non-streaming state and confirm whether they are suitable for read traffic, recovery, or failover.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';