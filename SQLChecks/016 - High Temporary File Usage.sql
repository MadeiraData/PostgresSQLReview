/*
    DESCRIPTION:

    What This Means: One or more databases have written a large volume of temporary
        files (more than 1 GB since the last statistics reset). PostgreSQL writes
        temporary files to disk when an operation cannot complete within work_mem
        and has to spill. This commonly happens with large sorts (ORDER BY,
        DISTINCT, merge joins), hash joins, and hash-based aggregation. Disk spills
        are far slower than in-memory processing, so heavy temporary file usage
        signals queries that are degrading performance and consuming disk I/O and
        space in the temporary tablespace ($PGDATA/base/pgsql_tmp by default).
        Note that temp_bytes in pg_stat_database is cumulative since stats_reset,
        so a high value can reflect long uptime rather than a current spike.

    Recommendations:
        Enable log_temp_files (e.g. a low threshold in KB) to capture which queries
        are spilling and how large the temporary files are, then use
        EXPLAIN (ANALYZE, BUFFERS) to confirm external merge sorts or batched hash
        joins. Address the heaviest offenders by adding or improving indexes to
        avoid large sorts, rewriting expensive queries, and limiting result sets.
        Tune work_mem carefully — it is allocated per operation per query, so a
        complex query with several sorts/hashes and many concurrent sessions can
        multiply memory use quickly; prefer raising it per-session or per-query for
        known heavy workloads rather than globally. Consider setting a
        temp_file_limit to protect against runaway queries filling the disk, and
        optionally a dedicated temp_tablespaces location to isolate temporary file
        I/O from data files. pg_stat_statements (temp_blks_written) helps rank the
        queries responsible.

    Scope : database-level
    Category : Performance

    More info:
        https://www.postgresql.org/docs/current/runtime-config-resource.html#GUC-WORK-MEM
        https://www.postgresql.org/docs/current/runtime-config-logging.html#GUC-LOG-TEMP-FILES
        https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-VIEW
*/


v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more databases have high temporary file usage.',
                'ThresholdTempBytes', 1073741824,
                'ThresholdDescription', 'More than 1 GB temporary file usage since statistics reset.',
                'Databases',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'DatabaseName', datname,
                        'TempFiles', temp_files,
                        'TempBytes', temp_bytes,
                        'TempGB', ROUND(temp_bytes::numeric / 1024 / 1024 / 1024, 2),
                        'StatsReset', stats_reset
                    )
                    ORDER BY temp_bytes DESC
                )
            )
        END
    FROM pg_stat_database
    WHERE temp_bytes > 1073741824
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
            THEN 'Temporary file usage is within the expected range.'
        ELSE
            'Review queries that spill to disk. Consider tuning work_mem carefully, improving indexes, rewriting expensive sorts/hash joins, and reviewing temporary file logging.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';