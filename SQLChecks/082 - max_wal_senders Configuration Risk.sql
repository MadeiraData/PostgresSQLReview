/*
    DESCRIPTION:

    What This Means: max_wal_senders limits how many concurrent WAL sender
        processes the server can run at once. Every physical streaming replica,
        every pg_basebackup (or WAL-G / pgBackRest) invocation using
        --wal-method=stream, and every logical replication subscriber each
        occupies one WAL sender for as long as it stays connected. When the
        number of currently connected senders (pg_stat_replication) is close to
        max_wal_senders, or max_wal_senders is set to 0, the server has little or
        no spare capacity to accept another one.

    Recommendations:
        Review current WAL sender usage against max_wal_senders together with
        max_replication_slots and max_connections (max_wal_senders is reserved
        out of max_connections, so raising it also requires headroom there).
        Raising max_wal_senders requires a server restart, so plan the change
        during a maintenance window rather than during an incident, when a new
        standby or backup connection is most likely to be needed urgently. If
        max_wal_senders is 0, decide deliberately whether physical/logical
        replication and streaming base backups should ever be possible on this
        instance, and raise it if they should.

    Scope : Cluster-level
    Category : Replication

    More info:
        https://www.postgresql.org/docs/current/runtime-config-replication.html#GUC-MAX-WAL-SENDERS
        https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION
        https://www.postgresql.org/docs/current/app-pgbasebackup.html
*/

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN max_wal_senders = 0 THEN jsonb_build_object
            (
                'MaxWalSenders', max_wal_senders,
                'ActiveWalSenders', active_wal_senders,
                'WalSenderUsagePercent', NULL,
                'FindingReason', 'max_wal_senders is 0, so this server cannot accept any physical replica, streaming base backup, or logical replication subscriber connection at all.'
            )
            WHEN wal_sender_usage_percent >= 80 THEN jsonb_build_object
            (
                'MaxWalSenders', max_wal_senders,
                'ActiveWalSenders', active_wal_senders,
                'WalSenderUsagePercent', wal_sender_usage_percent,
                'FindingReason', 'Active WAL sender connections are close to max_wal_senders, leaving little or no capacity to attach a new replica, backup tool, or logical subscriber.'
            )
            ELSE NULL::jsonb
        END
    FROM
    (
        SELECT
            max_wal_senders,
            active_wal_senders,
            ROUND
            (
                active_wal_senders::numeric
                / NULLIF(max_wal_senders::numeric, 0) * 100,
                2
            ) AS wal_sender_usage_percent
        FROM
        (
            SELECT
                current_setting('max_wal_senders')::int AS max_wal_senders,
                (SELECT COUNT(*) FROM pg_stat_replication)::int AS active_wal_senders
        ) base
    ) s
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
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'max_wal_senders has adequate spare capacity for the currently connected replication clients.'
        ELSE
            'Raise max_wal_senders (requires a restart) with enough headroom for expected replicas, backup tools, and logical subscribers, and keep it aligned with max_replication_slots and max_connections.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
