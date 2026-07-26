/*
    DESCRIPTION:
        Indexing: large indexes have zero recorded scans.
        This may indicate unused indexes, but counters must be validated before action.

    Recommendations:
        Validate over a full business cycle before dropping indexes.
        Check constraints, rare reports, maintenance jobs, and statistics reset time.

    Scope : Database-level
    Category : Performance

    More info:
        https://www.postgresql.org/docs/current/monitoring-stats.html
        https://www.postgresql.org/docs/current/indexes.html
*/

v_AdditionalInfo :=
(
    WITH large_zero_scan_indexes AS
    (
        SELECT
            s.schemaname AS SchemaName,
            s.relname AS TableName,
            s.indexrelname AS IndexName,
            s.idx_scan AS IndexScans,
            pg_relation_size(s.indexrelid) AS IndexSizeBytes,
            pg_size_pretty(pg_relation_size(s.indexrelid)) AS IndexSize,
            i.indisunique AS IsUnique,
            i.indisprimary AS IsPrimaryKey,
            i.indisexclusion AS IsExclusionConstraint,
            d.stats_reset AS DatabaseStatisticsResetTime
        FROM pg_stat_user_indexes s
        JOIN pg_index i
            ON i.indexrelid = s.indexrelid
        LEFT JOIN pg_stat_database d
            ON d.datname = current_database()
        WHERE s.idx_scan = 0
          AND pg_relation_size(s.indexrelid) > 104857600
        ORDER BY pg_relation_size(s.indexrelid) DESC
        LIMIT 50
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'ImportantNote', 'Zero scans alone is not enough evidence to drop an index.',
                    'Thresholds',
                    jsonb_build_object
                    (
                        'MinimumIndexSizeBytes', 104857600,
                        'MinimumIndexSize', '100 MB',
                        'IndexScans', 0
                    ),
                    'ValidationRequired',
                    jsonb_build_array
                    (
                        'Validate usage over a full business cycle.',
                        'Check whether the index supports constraints or unique enforcement.',
                        'Check rare reports, batch jobs, maintenance jobs, and application releases.',
                        'Check the database statistics reset time before making a decision.'
                    ),
                    'Indexes',
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', SchemaName,
                            'TableName', TableName,
                            'IndexName', IndexName,
                            'IndexSize', IndexSize,
                            'IndexSizeBytes', IndexSizeBytes,
                            'IndexScans', IndexScans,
                            'IsUnique', IsUnique,
                            'IsPrimaryKey', IsPrimaryKey,
                            'IsExclusionConstraint', IsExclusionConstraint,
                            'DatabaseStatisticsResetTime', DatabaseStatisticsResetTime
                        )
                        ORDER BY IndexSizeBytes DESC
                    )
                )
        END
    FROM large_zero_scan_indexes
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
    'Indexing',
    'Object-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No large indexes with zero scans were detected.'
        ELSE
            'Review large indexes with zero scans. Do not drop indexes based only on zero scans; validate over a full business cycle and check constraints, rare reports, maintenance jobs, and statistics reset time.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production/Development';

