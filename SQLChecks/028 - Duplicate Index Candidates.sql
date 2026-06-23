/* DESCRIPTION:
   Performance: duplicate index candidates exist in the database. These are
   indexes on the same table with the same indexed columns, expressions,
   predicates, access method, and uniqueness behavior.

   WHY THIS MATTERS:
   Duplicate indexes waste disk space and increase write overhead because
   INSERT, UPDATE, DELETE, VACUUM, and autovacuum operations must maintain
   unnecessary index structures.

   REMEDIATION:
   Review each duplicate index group. Keep the index that is required by a
   constraint or actively used by queries, and drop redundant indexes only after
   validating usage and dependency requirements.

   REFERENCES:
   https://www.postgresql.org/docs/current/indexes.html
   https://www.postgresql.org/docs/current/catalog-pg-index.html
   https://www.postgresql.org/docs/current/sql-dropindex.html
*/

v_AdditionalInfo := (
    WITH user_indexes AS (
        SELECT
            nsp.nspname AS schema_name,
            tbl.relname AS table_name,
            idx.relname AS index_name,
            idx.oid AS index_oid,
            tbl.oid AS table_oid,
            am.amname AS access_method,
            ix.indisunique AS is_unique,
            ix.indisprimary AS is_primary,
            ix.indisexclusion AS is_exclusion,
            ix.indisvalid AS is_valid,
            ix.indkey::text AS index_keys,
            pg_get_expr(ix.indexprs, ix.indrelid) AS index_expressions,
            pg_get_expr(ix.indpred, ix.indrelid) AS index_predicate,
            pg_get_indexdef(idx.oid) AS index_definition,
            pg_relation_size(idx.oid) AS index_size_bytes
        FROM pg_index ix
        JOIN pg_class idx
            ON idx.oid = ix.indexrelid
        JOIN pg_class tbl
            ON tbl.oid = ix.indrelid
        JOIN pg_namespace nsp
            ON nsp.oid = tbl.relnamespace
        JOIN pg_am am
            ON am.oid = idx.relam
        WHERE nsp.nspname NOT IN ('pg_catalog', 'information_schema')
          AND idx.relkind = 'i'
          AND ix.indisvalid = true
    ),
    duplicate_groups AS (
        SELECT
            schema_name,
            table_name,
            access_method,
            is_unique,
            index_keys,
            COALESCE(index_expressions, '') AS index_expressions,
            COALESCE(index_predicate, '') AS index_predicate,
            COUNT(*) AS duplicate_count,
            SUM(index_size_bytes) AS total_index_size_bytes,
            jsonb_agg(
                jsonb_build_object(
                    'IndexName', index_name,
                    'IndexDefinition', index_definition,
                    'IndexSizeBytes', index_size_bytes,
                    'IsPrimary', is_primary,
                    'IsExclusion', is_exclusion
                )
                ORDER BY index_size_bytes DESC
            ) AS indexes
        FROM user_indexes
        WHERE is_primary = false
          AND is_exclusion = false
        GROUP BY
            schema_name,
            table_name,
            access_method,
            is_unique,
            index_keys,
            COALESCE(index_expressions, ''),
            COALESCE(index_predicate, '')
        HAVING COUNT(*) > 1
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM duplicate_groups)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'DuplicateIndexCandidates',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'AccessMethod', access_method,
                        'IsUnique', is_unique,
                        'DuplicateCount', duplicate_count,
                        'TotalIndexSizeBytes', total_index_size_bytes,
                        'IndexKeys', index_keys,
                        'IndexExpressions', index_expressions,
                        'IndexPredicate', index_predicate,
                        'Indexes', indexes
                    )
                    ORDER BY total_index_size_bytes DESC
                )
                FROM duplicate_groups
            ),
            'FindingReason',
            'One or more groups of duplicate index candidates were found.'
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
    'Performance',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No duplicate index candidates were found.'
        ELSE
            'Review duplicate index candidates carefully. Drop only indexes proven to be redundant and not required by constraints, query patterns, or operational procedures.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';