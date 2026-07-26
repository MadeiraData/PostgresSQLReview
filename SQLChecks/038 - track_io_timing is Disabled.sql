
/* DESCRIPTION:
   What This Means: track_io_timing is disabled. This prevents PostgreSQL from
   collecting block read and write timing information for query and database
   activity.

   WHY THIS MATTERS:
   Without I/O timing data, it is harder to distinguish CPU-bound workloads from
   I/O-bound workloads and to diagnose slow queries, storage latency, cache
   efficiency, and read/write bottlenecks.

   Recommendations:
   Consider enabling track_io_timing, especially for production systems where
   query performance troubleshooting is important. Test overhead in the target
   environment before enabling globally.

   Scope : Cluster-level
   Category : Monitoring

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-statistics.html
   https://www.postgresql.org/docs/current/monitoring-stats.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('track_io_timing', true) = 'on'
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'TrackIOTiming',
                current_setting('track_io_timing', true),
            'FindingReason',
                'track_io_timing is disabled, so PostgreSQL is not collecting I/O timing statistics.'
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
    'Observability',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'track_io_timing is enabled.'
        ELSE
            'Consider enabling track_io_timing to improve visibility into PostgreSQL I/O latency and performance bottlenecks.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';