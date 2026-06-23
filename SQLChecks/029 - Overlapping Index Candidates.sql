/* DESCRIPTION:
   Performance: overlapping index candidates exist in the database. These are
   indexes where one index starts with the same leading columns as another
   index on the same table.

   WHY THIS MATTERS:
   A wider index may sometimes make a narrower index redundant when the narrower
   index is a left-prefix of the wider index. Redundant overlapping indexes
   waste disk space and increase write overhead for INSERT, UPDATE, DELETE,
   VACUUM, and autovacuum operations.

   REMEDIATION:
   Review each overlapping index pair. Do not automatically drop indexes.
   Validate query usage, uniqueness, constraints, predicates, sort order,
   included columns, and index-only scan behavior before removing any index.

   REFERENCES:
   https://www.postgresql.org/docs/current/indexes.html
   https://www.postgresql.org/docs/current/indexes-multicolumn.html
   https://www.postgresql.org/docs/current/catalog-pg-index.html
   https://www.postgresql.org/docs/current/sql-dropindex.html
*/

v_AdditionalInfo := (
    WITH user_indexes AS (
        SELECT
            nsp.nspname AS schema_name,
            tbl.relname AS table_name,
            tbl.oid AS table_oid,
            idx.relname AS index_name,
            idx.oid AS index_oid,
            am.amname AS access_method,
            ix.indisunique AS is_unique,
            ix.indisprimary AS is_primary,
            ix.indisexclusion AS is_exclusion,
            ix.indisvalid AS is_valid,
            ix.indkey::int[] AS index_keys,
            ix.indnkeyatts AS key_column_count,
            ix.indnatts AS total_column_count,
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
          AND ix.indisready = true
          AND ix.indisprimary = false
          AND ix.indisexclusion = false
    ),
    overlapping_indexes AS (
        SELECT
            narrow.schema_name,
            narrow.table_name,
            narrow.index_name AS narrower_index_name,
            wide.index_name AS wider_index_name,
            narrow.index_definition AS narrower_index_definition,
            wide.index_definition AS wider_index_definition,
            narrow.index_size_bytes AS narrower_index_size_bytes,
            wide.index_size_bytes AS wider_index_size_bytes,
            narrow.access_method,
            narrow.is_unique AS narrower_is_unique,
            wide.is_unique AS wider_is_unique,
            narrow.index_predicate AS narrower_predicate,
            wide.index_predicate AS wider_predicate,
            narrow.index_expressions AS narrower_expressions,
            wide.index_expressions AS wider_expressions,
            narrow.key_column_count AS narrower_key_column_count,
            wide.key_column_count AS wider_key_column_count
        FROM user_indexes narrow
        JOIN user_indexes wide
            ON wide.table_oid = narrow.table_oid
           AND wide.index_oid <> narrow.index_oid
           AND wide.access_method = narrow.access_method
           AND COALESCE(wide.index_predicate, '') = COALESCE(narrow.index_predicate, '')
           AND COALESCE(wide.index_expressions, '') = COALESCE(narrow.index_expressions, '')
           AND wide.key_column_count > narrow.key_column_count
           AND wide.index_keys[1:narrow.key_column_count]
               = narrow.index_keys[1:narrow.key_column_count]
        WHERE narrow.is_unique = false
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM overlapping_indexes)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'OverlappingIndexCandidates',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'NarrowerIndexName', narrower_index_name,
                        'WiderIndexName', wider_index_name,
                        'AccessMethod', access_method,
                        'NarrowerIndexDefinition', narrower_index_definition,
                        'WiderIndexDefinition', wider_index_definition,
                        'NarrowerIndexSizeBytes', narrower_index_size_bytes,
                        'WiderIndexSizeBytes', wider_index_size_bytes,
                        'NarrowerIsUnique', narrower_is_unique,
                        'WiderIsUnique', wider_is_unique,
                        'NarrowerPredicate', narrower_predicate,
                        'WiderPredicate', wider_predicate,
                        'NarrowerExpressions', narrower_expressions,
                        'WiderExpressions', wider_expressions
                    )
                    ORDER BY narrower_index_size_bytes DESC
                )
                FROM overlapping_indexes
            ),
            'FindingReason',
            'One or more overlapping index candidates were found where a narrower index is a left-prefix of a wider index.'
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
            THEN 'No overlapping index candidates were found.'
        ELSE
            'Review overlapping index candidates carefully. Drop only indexes proven to be redundant after validating workload usage, constraints, predicates, ordering, and index-only scan requirements.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';