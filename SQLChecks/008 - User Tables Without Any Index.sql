/*
    DESCRIPTION:
        What This Means: user tables were found without any indexes.
        This may cause full table scans and poor performance as data grows.

    Recommendations:
        Review access patterns before adding indexes.
        For large active tables, prefer CREATE INDEX CONCURRENTLY where appropriate.

    Scope : Database-level
    Category : Performance

    More info:
        https://www.postgresql.org/docs/current/indexes.html
        https://www.postgresql.org/docs/current/sql-createindex.html
*/

v_AdditionalInfo :=
(
    WITH tables_without_indexes AS
    (
        SELECT
            n.nspname AS SchemaName,
            c.relname AS TableName,
            c.reltuples::bigint AS EstimatedRows,
            pg_total_relation_size(c.oid) AS TotalSizeBytes,
            pg_size_pretty(pg_total_relation_size(c.oid)) AS TotalSize
        FROM pg_class c
        JOIN pg_namespace n
            ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND c.relpersistence = 'p'
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE 'pg_toast%'
          AND NOT EXISTS
          (
              SELECT 1
              FROM pg_index i
              WHERE i.indrelid = c.oid
          )
          AND
          (
              c.reltuples > 1000
              OR pg_total_relation_size(c.oid) > 10485760
          )
        ORDER BY pg_total_relation_size(c.oid) DESC, n.nspname, c.relname
        LIMIT 50
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0
                THEN NULL::jsonb
            ELSE
                jsonb_build_object
                (
                    'Thresholds',
                    jsonb_build_object
                    (
                        'MinimumEstimatedRows', 1000,
                        'MinimumTotalSizeBytes', 10485760
                    ),
                    'Tables',
                    jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', SchemaName,
                            'TableName', TableName,
                            'EstimatedRows', EstimatedRows,
                            'TotalSize', TotalSize,
                            'TotalSizeBytes', TotalSizeBytes
                        )
                        ORDER BY TotalSizeBytes DESC
                    )
                )
        END
    FROM tables_without_indexes
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
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No relevant user tables without indexes were detected.'
        ELSE
            'Review table access patterns before adding indexes. For large active tables, use CONCURRENTLY-aware rollout planning and validate resource impact.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production/Development';

