/* DESCRIPTION:
   Configuration: effective_cache_size appears to be very small. This may cause
   the PostgreSQL planner to underestimate the amount of data likely to be
   cached by PostgreSQL and the operating system.

   WHY THIS MATTERS:
   effective_cache_size is a planner cost estimate, not a memory allocation.
   If it is too low, PostgreSQL may avoid index scans even when they would be
   beneficial, potentially leading to inefficient query plans.

   REMEDIATION:
   Review effective_cache_size together with total server RAM, shared_buffers,
   operating system cache, workload type, and concurrent services on the server.
   For dedicated PostgreSQL servers, configure it to reflect the estimated memory
   available for caching data.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-query.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN pg_size_bytes(current_setting('effective_cache_size')) >= 536870912 -- 512 MB
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'EffectiveCacheSize', current_setting('effective_cache_size', true),
            'EffectiveCacheSizeBytes', pg_size_bytes(current_setting('effective_cache_size')),
            'SharedBuffers', current_setting('shared_buffers', true),
            'SharedBuffersBytes', pg_size_bytes(current_setting('shared_buffers')),
            'FindingReason',
                'effective_cache_size is configured below 512 MB, which appears very small for many production PostgreSQL servers.'
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
            THEN 'effective_cache_size does not appear to be very small.'
        ELSE
            'Review effective_cache_size and tune it to reflect the estimated memory available for PostgreSQL and operating system caching.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';