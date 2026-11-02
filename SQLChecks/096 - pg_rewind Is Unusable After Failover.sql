/*
    DESCRIPTION:

    What This Means: Neither data checksums (data_checksums) nor write-ahead
        log hint-bit logging (wal_log_hints) is enabled on this server. Either
        one, on its own, is enough to let PostgreSQL safely reconstruct hint-bit
        changes from WAL, which is the information pg_rewind (and comparable
        tools used by HA frameworks such as Patroni and repmgr) needs to
        resynchronize a diverged former primary back into the cluster as a new
        standby after a failover. With both disabled, pg_rewind refuses to run
        and documents no workaround: the old primary cannot be rewound onto the
        new timeline at all. This failure surfaces at the worst possible moment
        -- during an active failover, when a DBA is already trying to restore
        redundancy under pressure -- and the only remaining option is to
        discard the diverged data directory entirely and re-seed it with a full
        pg_basebackup, which can take hours on a large database and leaves the
        cluster running without a standby for that entire window. Turning
        either setting on after the failover has already happened does not
        retroactively fix the branch that already diverged; both must be
        enabled in advance for this safety net to exist when it's needed.

    Recommendations:
        Enable data checksums (ideally via "pg_upgrade --data-checksums" at the
        next major-version upgrade, or by scheduling an offline
        "pg_checksums --enable" maintenance window on PostgreSQL 12+), or, if a
        checksums rollout is not currently feasible, enable the lighter-weight
        wal_log_hints = on and reload the configuration. Either setting alone
        is sufficient to keep pg_rewind usable; enabling it ahead of time, not
        after a failover has already occurred, is what matters. Note that
        data_checksums is fixed at initdb/pg_upgrade time and cannot be
        changed with ALTER SYSTEM or a simple restart, while wal_log_hints
        takes effect on the next server restart.

    Scope : Cluster-level
    Category : Backup and Recovery

    More info:
        https://www.postgresql.org/docs/current/app-pgrewind.html
        https://www.postgresql.org/docs/current/runtime-config-wal.html
        https://www.postgresql.org/docs/current/checksums.html
*/

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN current_setting('data_checksums', true) = 'on'
                OR current_setting('wal_log_hints', true) = 'on'
                THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'DataChecksums', current_setting('data_checksums', true),
                'WalLogHints', current_setting('wal_log_hints', true),
                'FindingReason', 'Neither data_checksums nor wal_log_hints is enabled, so pg_rewind (and similar HA tooling) cannot resynchronize a diverged former primary after a failover; a full pg_basebackup re-seed would be required instead.'
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
    'Backup and Recovery',                                      -- Category
    'Cluster-level',                                             -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'pg_rewind remains usable after a failover: data checksums or wal_log_hints (or both) are enabled.'
        ELSE
            'Enable data checksums or wal_log_hints so pg_rewind can resynchronize a diverged former primary after a failover instead of requiring a full pg_basebackup re-seed.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
