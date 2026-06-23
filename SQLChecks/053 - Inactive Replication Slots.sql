/* DESCRIPTION:
   Replication: inactive replication slots exist. These slots are not currently
   connected to an active replication client but may still retain WAL.

   WHY THIS MATTERS:
   Inactive replication slots can prevent PostgreSQL from recycling old WAL
   files. If the slot is unused or abandoned, retained WAL can grow until disk
   space is exhausted. This can cause database outages and interrupt backup or
   replication operations.

   REMEDIATION:
   Review each inactive replication slot and confirm whether it is still needed.
   Drop abandoned slots only after validating with the application, backup,
   replication, or CDC owner. For PostgreSQL versions that support it, consider
   max_slot_wal_keep_size to limit WAL retention risk.

   REFERENCES:
   https://www.postgresql.org/docs/current/view-pg-replication-slots.html
   https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS
   https://www.postgresql.org/docs/current/runtime-config-replication.html
*/

v_AdditionalInfo := (
    WITH inactive_slots AS (
        SELECT
            slot_name,
            plugin,
            slot_type,
            datoid,
            database,
            temporary,
            active,
            active_pid,
            restart_lsn,
            confirmed_flush_lsn,
            wal_status,
            safe_wal_size,
            two_phase,
            xmin,
            catalog_xmin,
            pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_wal_bytes
        FROM pg_replication_slots
        WHERE active = false
          AND temporary = false
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM inactive_slots)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'InactiveReplicationSlots',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SlotName', slot_name,
                        'Plugin', plugin,
                        'SlotType', slot_type,
                        'Database', database,
                        'Active', active,
                        'RestartLsn', restart_lsn,
                        'ConfirmedFlushLsn', confirmed_flush_lsn,
                        'WalStatus', wal_status,
                        'SafeWalSize', safe_wal_size,
                        'TwoPhase', two_phase,
                        'Xmin', xmin,
                        'CatalogXmin', catalog_xmin,
                        'RetainedWalBytes', retained_wal_bytes
                    )
                    ORDER BY retained_wal_bytes DESC NULLS LAST
                )
                FROM inactive_slots
            ),
            'FindingReason',
            'One or more persistent replication slots are inactive and may retain WAL.'
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No inactive persistent replication slots were found.'
        ELSE
            'Review inactive replication slots and drop abandoned slots only after confirming they are no longer required.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';