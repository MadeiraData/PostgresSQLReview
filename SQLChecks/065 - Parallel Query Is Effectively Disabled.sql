/*
    DESCRIPTION:

    What This Means: parallel query is effectively disabled
        (max_parallel_workers_per_gather = 0, or max_parallel_workers = 0, or
        max_worker_processes = 0). Parallel query lets a single large query use
        multiple worker processes to scan, join, and aggregate at once. If
        max_parallel_workers_per_gather is 0 the planner never parallelizes; if
        either worker pool is 0 there are no workers to use. On analytical /
        reporting / warehouse workloads this can turn plans that would run in
        seconds into minutes. (For a pure fast-OLTP workload parallelism is often
        unnecessary, so this may be intentional.)

    Recommendations:
        Confirm whether disabling parallelism was intentional for this workload. For
        analytical or mixed workloads, enable parallel query: max_parallel_workers_per_gather
        is commonly set toward half the CPU count (bounded by max_parallel_workers
        and max_worker_processes). max_parallel_workers_per_gather and
        max_parallel_workers are reloadable; max_worker_processes requires a restart.
        This is a cluster-wide planner change, so validate representative queries
        before and after.

    Scope : Cluster-level
    Category : Performance

    More info:
        https://www.postgresql.org/docs/current/how-parallel-query-works.html
        https://www.postgresql.org/docs/current/runtime-config-resource.html
        https://www.pgmustard.com/blog/max-parallel-workers-per-gather
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN s.per_gather > 0 AND s.max_parallel > 0 AND s.worker_procs > 0
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason',
                'Parallel query is effectively disabled. The planner cannot use parallel workers for large or analytical queries, which can significantly increase their runtime.',
            'MaxParallelWorkersPerGather', s.per_gather,
            'MaxParallelWorkers', s.max_parallel,
            'MaxWorkerProcesses', s.worker_procs
        )
    END
    FROM (
        SELECT
            (SELECT setting::integer FROM pg_settings WHERE name = 'max_parallel_workers_per_gather') AS per_gather,
            (SELECT setting::integer FROM pg_settings WHERE name = 'max_parallel_workers')             AS max_parallel,
            (SELECT setting::integer FROM pg_settings WHERE name = 'max_worker_processes')             AS worker_procs
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
    'Performance',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,                                                          -- Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'Parallel query is enabled (workers are available and max_parallel_workers_per_gather > 0).'
        ELSE
            'According to PostgreSQL documentation and community best practices, confirm whether disabling parallelism was intentional for this workload. For analytical or mixed workloads, enable parallel query (max_parallel_workers_per_gather is commonly set toward half the CPU count, bounded by max_parallel_workers and max_worker_processes). Per-gather and max_parallel_workers are reloadable; max_worker_processes requires a restart. This is a cluster-wide planner change, so validate representative queries before and after.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';