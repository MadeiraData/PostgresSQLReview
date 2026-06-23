/* DESCRIPTION:
   Configuration: maintenance_work_mem appears to be too low. This can make
   maintenance operations such as VACUUM, CREATE INDEX, ALTER TABLE ADD FOREIGN
   KEY, and other index-related operations slower than necessary.

   WHY THIS MATTERS:
   maintenance_work_mem controls the maximum memory used by maintenance
   operations. If it is too small, PostgreSQL may need more passes or more
   temporary disk work during maintenance tasks, increasing runtime and I/O.

   REMEDIATION:
   Review maintenance_work_mem together with server RAM, maintenance workload,
   autovacuum settings, and concurrent maintenance operations. Consider
   increasing it for production systems, especially before large index builds or
   maintenance windows.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-resource.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN pg_size_bytes(current_setting('maintenance_work_mem')) >= 67108864 -- 64 MB
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'MaintenanceWorkMem', current_setting('maintenance_work_mem', true),
            'MaintenanceWorkMemBytes', pg_size_bytes(current_setting('maintenance_work_mem')),
            'AutovacuumWorkMem', current_setting('autovacuum_work_mem', true),
            'MaxParallelMaintenanceWorkers', current_setting('max_parallel_maintenance_workers', true),
            'FindingReason',
                'maintenance_work_mem is configured below 64 MB, which may slow maintenance operations.'
        )
    END
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
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'maintenance_work_mem does not appear to be too low.'
        ELSE
            'Review maintenance_work_mem and consider increasing it to improve maintenance operation performance, while accounting for available RAM and concurrency.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';