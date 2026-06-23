
/* ============================================================
   CHECK: High Temporary File Usage
   ============================================================ */


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