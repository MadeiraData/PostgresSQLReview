/*
    DESCRIPTION:

    What This Means: random_page_cost may not be tuned for SSD, flash, or cloud
        block storage (it is more than twice seq_page_cost). random_page_cost tells
        the planner how expensive a random page fetch is relative to a sequential
        one; the default of 4.0 models spinning disks. On SSD/flash/cloud storage
        random access is close to sequential, so leaving it high can bias the
        planner toward sequential scans instead of index scans, producing slower
        plans.

    Recommendations:
        Confirm the underlying storage type first. For SSD/flash/cloud storage a
        value close to seq_page_cost (commonly ~1.1) is frequently recommended so
        the planner does not over-penalize index/random access. Adjust and validate
        representative query plans before and after. This is a cluster-wide,
        reloadable change (takes effect via pg_reload_conf, no restart) and affects
        all query planning. If the value was set intentionally for spinning disks,
        confirm that before changing it.

    Scope : Cluster-level
    Category : Configuration

    More info:
        https://www.postgresql.org/docs/current/runtime-config-query.html
        https://www.cybertec-postgresql.com/en/better-postgresql-performance-on-ssds/
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN s.rpc <= s.spc * 2
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'random_page_cost is more than twice seq_page_cost (the traditional spinning-disk assumption). On SSD, flash, or cloud block storage this can bias the planner toward sequential scans instead of index scans.',
            'Thresholds', jsonb_build_object(
                'FlaggedWhenRandomOverSeqRatioAbove', 2,
                'SpinningDiskDefault', 4.0,
                'TypicalSsdRecommendation', 1.1
            ),
            'RandomPageCost', s.rpc,
            'SeqPageCost', s.spc,
            'RandomToSeqRatio', round(s.rpc / NULLIF(s.spc, 0), 2)
        )
    END
    FROM (
        SELECT
            (SELECT setting::numeric FROM pg_settings WHERE name = 'random_page_cost') AS rpc,
            (SELECT setting::numeric FROM pg_settings WHERE name = 'seq_page_cost')     AS spc
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
    2,                                                          -- Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'random_page_cost is within about 2x of seq_page_cost, consistent with SSD/flash-aware planner tuning.'
        ELSE
            'According to PostgreSQL documentation and community best practices, review random_page_cost against the underlying storage. The default of 4.0 models spinning disks; for SSD, flash, or cloud block storage a value near 1.1 (close to seq_page_cost) is commonly recommended so the planner does not over-penalize index/random access. Confirm the storage type, then adjust and validate query plans. This is a cluster-wide, reloadable change (no restart) affecting all query planning, so test representative queries before and after.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';