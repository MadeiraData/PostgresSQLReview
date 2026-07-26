
/* DESCRIPTION:
   What This Means: shared_buffers appears to be very small. This may indicate
   that PostgreSQL has not been tuned for the server workload or available
   memory.

   WHY THIS MATTERS:
   shared_buffers is PostgreSQL's main shared memory area for caching table and
   index pages. If it is too small, PostgreSQL may rely more heavily on the
   operating system cache and perform more physical I/O than necessary.

   Recommendations:
   Review shared_buffers together with total server RAM, workload type,
   effective_cache_size, checkpoint behavior, and operating system memory usage.
   For dedicated PostgreSQL servers, shared_buffers is commonly sized as a
   meaningful portion of RAM, but should be tested before changing in production.

   Scope : Cluster-level
   Category : Performance

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-resource.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN pg_size_bytes(current_setting('shared_buffers')) >= 134217728 -- 128 MB
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'SharedBuffers', current_setting('shared_buffers', true),
            'SharedBuffersBytes', pg_size_bytes(current_setting('shared_buffers')),
            'EffectiveCacheSize', current_setting('effective_cache_size', true),
            'BlockSize', current_setting('block_size', true),
            'FindingReason',
                'shared_buffers is configured below 128 MB, which appears very small for many production PostgreSQL servers.'
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'shared_buffers does not appear to be very small.'
        ELSE
            'Review shared_buffers sizing and tune it according to server RAM, workload characteristics, and production testing.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';