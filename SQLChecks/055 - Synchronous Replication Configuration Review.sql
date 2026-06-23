/* DESCRIPTION:
   Replication: synchronous replication configuration should be reviewed.
   synchronous_commit or synchronous_standby_names may indicate that synchronous
   replication is disabled, partially configured, or configured in a way that
   may affect durability, latency, or failover expectations.

   WHY THIS MATTERS:
   Synchronous replication can reduce data loss risk by waiting for WAL
   confirmation from standby servers, but it can also increase transaction
   latency or block commits if required synchronous standbys are unavailable.
   If synchronous replication is expected but not configured correctly, recovery
   point objectives may not be met.

   REMEDIATION:
   Review synchronous_commit, synchronous_standby_names, connected standby
   servers, sync_state in pg_stat_replication, and business RPO/RTO
   requirements. Configure synchronous replication only where required, and
   validate failover behavior, quorum settings, and application latency impact.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-replication.html
   https://www.postgresql.org/docs/current/warm-standby.html#SYNCHRONOUS-REPLICATION
   https://www.postgresql.org/docs/current/view-pg-stat-replication.html
*/

v_AdditionalInfo := (
    WITH sync_config AS (
        SELECT
            current_setting('synchronous_commit', true) AS synchronous_commit,
            current_setting('synchronous_standby_names', true) AS synchronous_standby_names
    ),
    replication_state AS (
        SELECT
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
            replay_lag
        FROM pg_stat_replication
    ),
    review_needed AS (
        SELECT
            sc.*,
            EXISTS (
                SELECT 1
                FROM replication_state rs
                WHERE rs.sync_state IN ('sync', 'quorum')
            ) AS has_synchronous_standby,
            EXISTS (
                SELECT 1
                FROM replication_state
            ) AS has_connected_standby
        FROM sync_config sc
    )
    SELECT CASE
        WHEN synchronous_commit IN ('on', 'remote_write', 'remote_apply')
         AND COALESCE(NULLIF(synchronous_standby_names, ''), '') <> ''
         AND has_synchronous_standby
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'SynchronousCommit',
                synchronous_commit,
            'SynchronousStandbyNames',
                synchronous_standby_names,
            'HasConnectedStandby',
                has_connected_standby,
            'HasSynchronousStandby',
                has_synchronous_standby,
            'ReplicationState',
                COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object(
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
                                'ReplayLag', replay_lag
                            )
                            ORDER BY application_name
                        )
                        FROM replication_state
                    ),
                    '[]'::jsonb
                ),
            'FindingReason',
                CASE
                    WHEN synchronous_commit = 'off'
                        THEN 'synchronous_commit is off, so commits do not wait for WAL flush confirmation.'
                    WHEN COALESCE(NULLIF(synchronous_standby_names, ''), '') = ''
                        THEN 'synchronous_standby_names is empty, so no synchronous standby requirement is configured.'
                    WHEN NOT has_connected_standby
                        THEN 'synchronous replication is configured, but no standby is currently connected.'
                    WHEN NOT has_synchronous_standby
                        THEN 'standbys are connected, but none are currently reported as synchronous or quorum.'
                    ELSE
                        'synchronous replication configuration should be reviewed against durability and latency requirements.'
                END
        )
    END
    FROM review_needed
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
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Synchronous replication appears to be configured with at least one synchronous standby.'
        ELSE
            'Review synchronous replication configuration against business RPO/RTO requirements and confirm whether synchronous standby behavior is expected.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';