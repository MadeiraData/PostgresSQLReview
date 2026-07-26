/*
    DESCRIPTION:
        What This Means: High cache miss ratio detected in one or more databases.

        PostgreSQL reports block reads from disk and block hits from shared buffers
        in pg_stat_database. A high cache miss ratio means a larger percentage of
        reads are coming from disk instead of memory, which may indicate memory
        pressure, inefficient queries, missing indexes, large scans, or a workload
        that does not fit well in shared buffers and OS cache.

    Recommendations:
        Review query patterns, indexes, table scans, and memory pressure.
        Investigate databases with high disk reads using pg_stat_statements if
        available.
        Consider tuning shared_buffers carefully, improving indexes, reducing
        unnecessary full scans, and validating whether the working set fits in memory.

        Scope : Cluster-level
        Category : Performance

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
        https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-VIEW
*/

/* ============================================================
   CHECK: High Cache Miss Ratio
   ============================================================ */

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more databases have a high cache miss ratio.',
                'ThresholdCacheMissPercent', 5,
                'MinimumBlockAccesses', 100000,
                'Databases',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'DatabaseName', datname,
                        'BlockHits', blks_hit,
                        'BlockReads', blks_read,
                        'TotalBlockAccesses', blks_hit + blks_read,
                        'CacheHitPercent',
                            ROUND
                            (
                                blks_hit::numeric
                                / NULLIF(blks_hit + blks_read, 0) * 100,
                                2
                            ),
                        'CacheMissPercent',
                            ROUND
                            (
                                blks_read::numeric
                                / NULLIF(blks_hit + blks_read, 0) * 100,
                                2
                            ),
                        'StatsReset', stats_reset
                    )
                    ORDER BY
                        ROUND
                        (
                            blks_read::numeric
                            / NULLIF(blks_hit + blks_read, 0) * 100,
                            2
                        ) DESC
                )
            )
        END
    FROM pg_stat_database
    WHERE blks_hit + blks_read >= 100000
      AND
      (
          blks_read::numeric
          / NULLIF(blks_hit + blks_read, 0) * 100
      ) > 5
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
    'Performance',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Cache miss ratio is within the expected range.'
        ELSE
            'Investigate disk reads, inefficient queries, missing indexes, large scans, and memory pressure. Use pg_stat_statements if available to identify the main read-heavy queries.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';