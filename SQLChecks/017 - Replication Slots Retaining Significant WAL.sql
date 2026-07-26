/*
    DESCRIPTION:

    What This Means: One or more replication slots are holding on to a large volume
        of WAL (more than 10 GB, measured as the distance between the slot's
        restart_lsn and the current WAL position). A replication slot guarantees
        WAL retention for its consumer: the primary will not recycle WAL segments
        the slot still needs, regardless of wal_keep_size or checkpoint settings.
        This is exactly what makes slots dangerous — if a consumer is inactive,
        lagging, or abandoned (a decommissioned subscriber, a disconnected CDC
        connector such as Debezium, or a leftover pg_upgrade slot), the pg_wal
        directory grows without bound and can fill the disk, which stops the server
        from processing new transactions. For logical slots on an otherwise idle
        database, WAL can also accumulate simply because the slot never receives
        changes to advance past.

    Recommendations:
        Identify the consumer behind each slot and whether it is active
        (the "active" flag) and making progress. For a lagging but needed consumer,
        fix or restart it so the slot advances. For a genuinely abandoned slot,
        drop it with pg_drop_replication_slot(slot_name) after validating it is not
        required — note the downstream consumer will then need a full re-sync. As a
        safety valve, set max_slot_wal_keep_size (PG13+) so a runaway slot is
        invalidated at checkpoint rather than filling the disk, and on PG18+ use
        idle_replication_slot_timeout to auto-invalidate long-idle slots. Monitor
        pg_replication_slots (retained WAL, wal_status, safe_wal_size) and alert
        before WAL volume approaches disk capacity.

    Scope : cluster-level
    Category : Replication

    More info:
        https://www.postgresql.org/docs/current/view-pg-replication-slots.html
        https://www.postgresql.org/docs/current/runtime-config-replication.html#GUC-MAX-SLOT-WAL-KEEP-SIZE
        https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-REPLICATION
*/


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