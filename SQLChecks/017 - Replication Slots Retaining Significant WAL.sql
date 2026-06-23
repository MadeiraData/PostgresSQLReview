/* ============================================================
   CHECK: Replication Slots Retaining Significant WAL
   ============================================================ */

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more replication slots are retaining significant WAL.',
                'ThresholdBytes', 10737418240,
                'ThresholdDescription', 'More than 10 GB WAL retained by a replication slot.',
                'ReplicationSlots',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'SlotName', slot_name,
                        'SlotType', slot_type,
                        'Database', database,
                        'Active', active,
                        'RestartLsn', restart_lsn,
                        'ConfirmedFlushLsn', confirmed_flush_lsn,
                        'WalRetainedBytes', wal_retained_bytes,
                        'WalRetainedGB', ROUND(wal_retained_bytes::numeric / 1024 / 1024 / 1024, 2)
                    )
                    ORDER BY wal_retained_bytes DESC
                )
            )
        END
    FROM
    (
        SELECT
            slot_name,
            slot_type,
            database,
            active,
            restart_lsn,
            confirmed_flush_lsn,
            pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS wal_retained_bytes
        FROM pg_replication_slots
        WHERE restart_lsn IS NOT NULL
    ) s
    WHERE wal_retained_bytes > 10737418240
);

INSERT INTO pg_review_results
(
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
            THEN 'No replication slots retaining significant WAL were detected.'
        ELSE
            'Review replication slot consumers. Confirm whether lagging or inactive slots are required, fix the consumer, or drop unused slots carefully after validation.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';