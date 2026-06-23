/* DESCRIPTION:
   Maintenance: invalid indexes exist in the database. Invalid indexes may be
   left behind by failed CREATE INDEX CONCURRENTLY, REINDEX CONCURRENTLY, or
   interrupted index maintenance operations.

   WHY THIS MATTERS:
   Invalid indexes are not usable by the query planner for normal query
   execution, but they can still consume disk space and create operational
   confusion. They may also indicate a failed or incomplete maintenance task.

   REMEDIATION:
   Review each invalid index. If the index is still required, rebuild it using
   REINDEX INDEX CONCURRENTLY or recreate it. If it is not required, drop it.

   REFERENCES:
   https://www.postgresql.org/docs/current/catalog-pg-index.html
   https://www.postgresql.org/docs/current/sql-reindex.html
   https://www.postgresql.org/docs/current/sql-createindex.html
*/

v_AdditionalInfo := (
    WITH invalid_indexes AS (
        SELECT
            nsp.nspname AS schema_name,
            tbl.relname AS table_name,
            idx.relname AS index_name,
            pg_get_indexdef(idx.oid) AS index_definition,
            pg_relation_size(idx.oid) AS index_size_bytes,
            ix.indisvalid AS is_valid,
            ix.indisready AS is_ready,
            ix.indislive AS is_live
        FROM pg_index ix
        JOIN pg_class idx
            ON idx.oid = ix.indexrelid
        JOIN pg_class tbl
            ON tbl.oid = ix.indrelid
        JOIN pg_namespace nsp
            ON nsp.oid = tbl.relnamespace
        WHERE ix.indisvalid = false
          AND nsp.nspname NOT IN ('pg_catalog', 'information_schema')
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM invalid_indexes)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'InvalidIndexes',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'IndexName', index_name,
                        'IndexDefinition', index_definition,
                        'IndexSizeBytes', index_size_bytes,
                        'IsValid', is_valid,
                        'IsReady', is_ready,
                        'IsLive', is_live
                    )
                    ORDER BY index_size_bytes DESC
                )
                FROM invalid_indexes
            ),
            'FindingReason',
            'One or more invalid indexes exist in the database.'
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
    'Maintenance',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No invalid indexes were found.'
        ELSE
            'Review invalid indexes. Rebuild required indexes using REINDEX INDEX CONCURRENTLY where supported, or drop indexes that are no longer needed.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';