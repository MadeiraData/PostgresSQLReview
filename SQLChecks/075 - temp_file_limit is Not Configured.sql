/*
    DESCRIPTION:

    What This Means: temp_file_limit is not configured. This GUC caps the total
        disk space a single PostgreSQL process (one session, one query) may
        consume writing temporary files -- the files PostgreSQL creates when a
        sort, hash join, hash aggregate, or similar operation cannot fit inside
        work_mem / maintenance_work_mem and has to spill to disk. The default
        value is -1, meaning unlimited: no single query or session is capped in
        how much temporary file space it can use.

    Recommendations:
        Configure temp_file_limit to a value that leaves comfortable headroom
        on the volume backing the temporary file directory (the pgsql_tmp
        subdirectory of each tablespace in use, or temp_tablespaces if set) --
        for example, a large fraction of the free space on that volume, or a
        multiple of the largest legitimate temp file usage observed via
        log_temp_files / pg_stat_database.temp_bytes. Setting it too low will
        abort legitimate large sorts, reports, or batch/ETL jobs with
        "temporary file size exceeds temp_file_limit", so review typical
        workload temp file usage first and consider a higher limit at the
        role or database level for known heavy-reporting accounts rather than
        one aggressive global value. Test the chosen value against real
        workload before enforcing it in production.

    Scope : Cluster-level
    Category : Configuration

    More info:
        https://www.postgresql.org/docs/current/runtime-config-resource.html
        https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.ManagingTempFiles.html
        https://www.postgresql.org/docs/current/runtime-config-client.html
*/

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN (SELECT setting::integer FROM pg_settings WHERE name = 'temp_file_limit') >= 0
                THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'TempFileLimit', current_setting('temp_file_limit', true),
                'FindingReason', 'temp_file_limit is set to -1 (unlimited), so a single query or session generating excessive temporary files -- a large sort, hash join, or hash aggregate that spills past work_mem, often from a missing index, a bad plan, or an unbounded report -- can consume all remaining disk space on the temporary file volume. Because that volume is typically shared with WAL and/or table data, filling it can halt writes or crash every database on the instance, not only the session that caused it.'
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
    'Configuration',                                             -- Category
    'Cluster-level',                                             -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                            -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,        -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,        -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,        -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'temp_file_limit is configured, bounding how much temporary file space a single session can consume.'
        ELSE
            'Configure temp_file_limit to a value that bounds per-session temporary file usage without interrupting legitimate large sorts, reports, or batch jobs; review observed temp file usage first, consider role/database-level overrides for known heavy workloads, and test before enforcing in production.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
