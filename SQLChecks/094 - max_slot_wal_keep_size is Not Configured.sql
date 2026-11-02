/*
    DESCRIPTION:

    What This Means: max_slot_wal_keep_size caps how much WAL a replication slot
        may retain in pg_wal before PostgreSQL invalidates the slot instead of
        letting retention grow without bound. This instance has it at its default
        of -1 (unlimited), so every replication slot - physical or logical - is
        free to pin an unbounded amount of WAL. A replication slot guarantees WAL
        retention for its consumer: the primary will not recycle a WAL segment any
        slot still needs, regardless of wal_keep_size or checkpoint activity. If a
        consumer stalls or is abandoned (a disconnected standby, a crashed CDC
        connector such as Debezium, a leftover pg_upgrade slot, or simply a
        logical slot on an otherwise idle database that never advances), nothing
        on this instance stops pg_wal from growing until the volume holding it
        fills up. A full WAL volume stops PostgreSQL from accepting any further
        write transaction cluster-wide - every database on the instance goes
        down, not just the one the lagging slot belongs to. This is a proactive
        configuration gap, not a symptom: it can be true on a cluster that
        currently has zero slots, and the risk only becomes visible once a slot
        is created and its consumer later stops making progress, with no warning
        in between.

    Recommendations:
        Set max_slot_wal_keep_size to a finite value sized to the amount of WAL
        the environment can safely retain on the volume backing pg_wal (for
        example, a comfortable fraction of free disk space, converted to the
        expected WAL generation rate). Once set, a slot that falls behind that
        limit is invalidated at checkpoint time rather than being allowed to fill
        the disk - the trade-off is that an invalidated physical standby needs a
        fresh base backup, and an invalidated logical subscriber needs a new slot
        plus a connector-specific resync, so pair the cap with monitoring of
        pg_replication_slots (wal_status, safe_wal_size, and the distance between
        restart_lsn and the current WAL position) to catch a stalled consumer
        before the cap is reached. On PostgreSQL 18+, idle_replication_slot_timeout
        is a complementary safety valve that auto-invalidates slots that have been
        completely idle for too long. This GUC takes effect on reload, no restart
        required.

    Scope : Cluster-level
    Category : Replication

    More info:
        https://www.postgresql.org/docs/current/runtime-config-replication.html#GUC-MAX-SLOT-WAL-KEEP-SIZE
        https://www.postgresql.org/docs/current/view-pg-replication-slots.html
*/


v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN current_setting('max_slot_wal_keep_size') <> '-1' THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'MaxSlotWalKeepSize', current_setting('max_slot_wal_keep_size'),
                'FindingReason', 'max_slot_wal_keep_size is -1 (unlimited), so a stalled or abandoned replication slot can retain WAL without bound and fill the disk.'
            )
        END
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
    'Replication',                                               -- Category
    'Cluster-level',                                              -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High: unbounded WAL retention can fill the disk and halt writes cluster-wide
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,        -- None / Medium: no symptom until a slot actually stalls
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,        -- None / Low: a single GUC change, reload only
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,        -- None / Low: a sized cap invalidates a slot instead of silently retaining more WAL
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'max_slot_wal_keep_size is configured with a finite WAL retention cap for replication slots.'
        ELSE
            'Set max_slot_wal_keep_size to a finite value sized to the available disk space so a stalled or abandoned replication slot is invalidated at checkpoint time instead of filling pg_wal, and monitor pg_replication_slots for slots approaching that limit.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
