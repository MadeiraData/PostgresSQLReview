/*
    DESCRIPTION:

    What This Means: a core crash-safety setting is disabled — fsync and/or
        full_page_writes is off. fsync forces WAL and data changes to be physically
        written to disk so the cluster can recover to a consistent state after an
        OS crash or power failure. full_page_writes stores a full image of each page
        the first time it changes after a checkpoint, so a page that was only
        partially written during a crash can still be restored. With either turned
        off, an operating-system crash or power loss can leave the database with
        unrecoverable or SILENT data corruption. This is one of the highest-severity
        things to catch on a customer's instance.

    Recommendations:
        Unless this is a throwaway/bulk-load instance whose data can be fully
        recreated, set fsync = on and full_page_writes = on and reload. These are
        reloadable (no restart). If they were disabled to speed up a one-off load,
        re-enable them immediately afterward. For a safer performance tradeoff on
        non-critical transactions, prefer relaxing synchronous_commit rather than
        disabling fsync/full_page_writes. Because this changes durability behaviour
        cluster-wide, confirm the intent and validate write performance after the
        change.

    Scope : Cluster-level
    Category : Configuration

    More info:
        https://www.postgresql.org/docs/current/non-durability.html
        https://www.postgresql.org/docs/current/runtime-config-wal.html
        https://www.postgresql.org/docs/current/wal-reliability.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN s.fsync_on AND s.fpw_on
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'A core durability setting is disabled. Turning off fsync or full_page_writes can cause unrecoverable or silent data corruption after an operating-system crash or power failure.',
            'Fsync', CASE WHEN s.fsync_on THEN 'on' ELSE 'off' END,
            'FullPageWrites', CASE WHEN s.fpw_on THEN 'on' ELSE 'off' END,
            'SynchronousCommit', s.sync_commit
        )
    END
    FROM (
        SELECT
            (SELECT setting FROM pg_settings WHERE name = 'fsync') = 'on'            AS fsync_on,
            (SELECT setting FROM pg_settings WHERE name = 'full_page_writes') = 'on' AS fpw_on,
            (SELECT setting FROM pg_settings WHERE name = 'synchronous_commit')      AS sync_commit
    ) s
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
    'Configuration',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                          -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Core durability settings are enabled (fsync = on and full_page_writes = on); the cluster is configured to recover safely from a crash.'
        ELSE
            'According to the PostgreSQL documentation, disabling fsync or full_page_writes risks unrecoverable or silent data corruption after a crash. Unless this is a throwaway/bulk-load instance whose data can be fully recreated, set fsync = on and full_page_writes = on and reload (no restart required). For a safer performance tradeoff on non-critical transactions, relax synchronous_commit instead. This changes durability cluster-wide, so confirm intent and validate write performance after the change.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';