/* DESCRIPTION:
   Performance: foreign keys exist without supporting indexes on the referencing
   columns. This can slow down DELETE and UPDATE operations on the parent table
   because PostgreSQL must check referencing rows in the child table.

   WHY THIS MATTERS:
   PostgreSQL does not automatically create indexes for foreign key columns.
   Missing indexes can cause long-running statements, excessive locking, and
   poor performance during parent-table updates or deletes.

   REMEDIATION:
   Create indexes on foreign key referencing columns where appropriate,
   especially for active OLTP tables and large child tables.

   REFERENCES:
   https://www.postgresql.org/docs/current/ddl-constraints.html
   https://www.postgresql.org/docs/current/indexes.html
*/

v_AdditionalInfo := (
    WITH fk_columns AS (
        SELECT
            con.oid AS constraint_oid,
            con.conname AS constraint_name,
            con.conrelid AS child_table_oid,
            con.confrelid AS parent_table_oid,
            nsp.nspname AS child_schema,
            cls.relname AS child_table,
            pnsp.nspname AS parent_schema,
            pcls.relname AS parent_table,
            con.conkey AS fk_attnums
        FROM pg_constraint con
        JOIN pg_class cls
            ON cls.oid = con.conrelid
        JOIN pg_namespace nsp
            ON nsp.oid = cls.relnamespace
        JOIN pg_class pcls
            ON pcls.oid = con.confrelid
        JOIN pg_namespace pnsp
            ON pnsp.oid = pcls.relnamespace
        WHERE con.contype = 'f'
          AND nsp.nspname NOT IN ('pg_catalog', 'information_schema')
    ),
    fk_with_columns AS (
        SELECT
            fk.*,
            array_agg(att.attname ORDER BY ord.ordinality) AS fk_columns
        FROM fk_columns fk
        JOIN unnest(fk.fk_attnums) WITH ORDINALITY AS ord(attnum, ordinality)
            ON true
        JOIN pg_attribute att
            ON att.attrelid = fk.child_table_oid
           AND att.attnum = ord.attnum
        GROUP BY
            fk.constraint_oid,
            fk.constraint_name,
            fk.child_table_oid,
            fk.parent_table_oid,
            fk.child_schema,
            fk.child_table,
            fk.parent_schema,
            fk.parent_table,
            fk.fk_attnums
    ),
    fk_without_index AS (
        SELECT
            fk.constraint_name,
            fk.child_schema,
            fk.child_table,
            fk.parent_schema,
            fk.parent_table,
            fk.fk_columns,
            pg_total_relation_size(fk.child_table_oid) AS child_table_size_bytes
        FROM fk_with_columns fk
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_index idx
            WHERE idx.indrelid = fk.child_table_oid
              AND idx.indisvalid
              AND idx.indisready
              AND idx.indpred IS NULL
              AND (
                  string_to_array(idx.indkey::text, ' ')::smallint[]
              )[1:array_length(fk.fk_attnums, 1)] = fk.fk_attnums
        )
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM fk_without_index)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'ForeignKeysWithoutSupportingIndexes',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'ConstraintName', constraint_name,
                        'ChildSchema', child_schema,
                        'ChildTable', child_table,
                        'ChildColumns', fk_columns,
                        'ParentSchema', parent_schema,
                        'ParentTable', parent_table,
                        'ChildTableSizeBytes', child_table_size_bytes
                    )
                    ORDER BY child_table_size_bytes DESC
                )
                FROM fk_without_index
            ),
            'FindingReason',
            'One or more foreign keys do not have a supporting index on the referencing columns.'
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
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'All foreign keys appear to have supporting indexes.'
        ELSE
            'Create supporting indexes on the referencing columns of foreign keys, prioritizing large and frequently modified child tables.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';