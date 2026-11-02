/*
    DESCRIPTION:

    What This Means: One or more replication slots on this instance have
        wal_status = 'lost', meaning PostgreSQL has already removed WAL
        segments that slot needed and the slot is now permanently unusable.
        This is a harder failure than a slot merely retaining a lot of WAL or
        sitting inactive: those states are still recoverable if the consumer
        reconnects or is fixed in time, but once wal_status reaches 'lost'
        there is no WAL left to replay, and PostgreSQL will never let that
        slot stream again. The consumer behind it - a physical standby, a
        CDC connector such as Debezium, a logical subscriber, or a backup
        tool using pg_basebackup's --slot option - fails outright the next
        time it tries to use the slot, and the only way back is to drop the
        slot and rebuild the consumer from a fresh base backup or full
        resync, which can mean hours of downtime or missed changes on a
        large database. A slot reaches 'lost' when the WAL it still needs is
        removed before the consumer can read it: this happens once
        max_slot_wal_keep_size (PG13+) or wal_removed horizon pressure forces
        checkpoint-time WAL recycling past what the slot reserved, when a
        standby's recovery conflicts with a logical slot, or (PG18+) when
        idle_replication_slot_timeout expires on a slot nobody has used in
        too long. Because the slot's catalog row keeps existing after
        invalidation, nothing crashes or pages anyone at the moment it
        happens - the failure surfaces later and loudly, when whatever
        depended on that slot stops receiving data.

    Recommendations:
        Treat any slot with wal_status = 'lost' as already broken, not merely
        at risk: identify the consumer that owned it and rebuild it from a
        fresh base backup (physical) or re-create the subscription/publication
        slot pair (logical) rather than waiting for it to recover on its own -
        it will not. Then address the root cause so another slot does not
        suffer the same fate: if max_slot_wal_keep_size is unbounded (-1), a
        lagging or abandoned consumer can grow pg_wal without limit, while too
        small a value invalidates slower-but-healthy consumers prematurely -
        size it to the slowest consumer's realistic catch-up window, not to
        zero risk. On PostgreSQL 18+, idle_replication_slot_timeout can also
        invalidate a slot nobody has used in a long time; confirm its value
        matches how long a legitimate consumer may legitimately sit idle.
        Monitor pg_replication_slots.wal_status continuously going forward
        rather than relying on a point-in-time check, since a slot can move
        from healthy to lost between review cycles.

    Scope : Cluster-level
    Category : Replication

    More info:
        https://www.postgresql.org/docs/current/view-pg-replication-slots.html
        https://www.postgresql.org/docs/current/runtime-config-replication.html#GUC-MAX-SLOT-WAL-KEEP-SIZE
        https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS
*/


v_AdditionalInfo :=
(
    WITH offenders AS
    (
        SELECT
            slot_name,
            slot_type,
            database,
            active,
            wal_status,
            invalidation_reason,
            conflicting
        FROM pg_replication_slots
        WHERE wal_status = 'lost'
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM offenders) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'OffenderCount', (SELECT count(*) FROM offenders),
                'InvalidatedSlots', (SELECT jsonb_agg(to_jsonb(o)) FROM offenders o),
                'FindingReason', 'One or more replication slots have been invalidated (wal_status = ''lost'') and can never stream again; the consumer behind each one needs a full resync.'
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
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No replication slot has been invalidated; every slot retains the WAL it needs.'
        ELSE
            'Rebuild the consumer behind each invalidated slot from a fresh base backup or re-created subscription, then review max_slot_wal_keep_size and idle_replication_slot_timeout so another slot does not reach the same state.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
