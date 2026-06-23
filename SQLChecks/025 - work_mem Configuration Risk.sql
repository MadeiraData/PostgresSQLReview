/*
    DESCRIPTION:
        Configuration: work_mem configuration may create memory pressure risk.

        work_mem controls the memory available to each sort, hash join, materialize,
        and similar operation before PostgreSQL writes temporary files to disk.
        This setting is applied per operation, not per session, so total memory usage
        can become much higher than work_mem multiplied by active connections.

        A high work_mem value combined with many allowed connections can increase
        the risk of memory pressure, swapping, out-of-memory events, or degraded
        database performance.

    Remediation:
        Review work_mem together with max_connections, active workload concurrency,
        query patterns, and temporary file usage.
        Avoid setting work_mem too high globally.
        Prefer targeted tuning per role, per database, or per session for known
        reporting or maintenance workloads.
        Consider connection pooling to reduce concurrent memory risk.

    More info:
        https://www.postgresql.org/docs/current/runtime-config-resource.html
        https://www.postgresql.org/docs/current/runtime-config-resource.html#GUC-WORK-MEM
*/

/* ============================================================
   CHECK: work_mem Configuration Risk
   ============================================================ */


v_AdditionalInfo :=
(
    WITH settings AS
    (
        SELECT
            pg_size_bytes(current_setting('work_mem')) AS work_mem_bytes,
            current_setting('work_mem') AS work_mem,
            current_setting('max_connections')::int AS max_connections,
            current_setting('superuser_reserved_connections')::int AS superuser_reserved_connections
    ),
    calculated AS
    (
        SELECT
            work_mem,
            work_mem_bytes,
            max_connections,
            superuser_reserved_connections,
            GREATEST(max_connections - superuser_reserved_connections, 0) AS usable_connections,
            work_mem_bytes * GREATEST(max_connections - superuser_reserved_connections, 0) AS theoretical_single_operation_memory_bytes,
            ROUND
            (
                (
                    work_mem_bytes * GREATEST(max_connections - superuser_reserved_connections, 0)
                )::numeric / 1024 / 1024 / 1024,
                2
            ) AS theoretical_single_operation_memory_gb
        FROM settings
    )
    SELECT
        CASE
            WHEN theoretical_single_operation_memory_bytes < 8589934592
                 AND work_mem_bytes < 67108864
                THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'Global work_mem may create memory pressure risk when combined with allowed connection count.',
                'WorkMem', work_mem,
                'WorkMemBytes', work_mem_bytes,
                'MaxConnections', max_connections,
                'SuperuserReservedConnections', superuser_reserved_connections,
                'UsableConnections', usable_connections,
                'TheoreticalSingleOperationMemoryBytes', theoretical_single_operation_memory_bytes,
                'TheoreticalSingleOperationMemoryGB', theoretical_single_operation_memory_gb,
                'RiskNote', 'work_mem is applied per sort/hash operation, not per session. A single query can use work_mem multiple times.'
            )
        END
    FROM calculated
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
    'Configuration',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'work_mem configuration does not indicate elevated global memory risk.'
        ELSE
            'Review global work_mem and max_connections together. Prefer targeted work_mem increases for specific roles, sessions, or workloads instead of a high cluster-wide default.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';