/* DESCRIPTION:
   Data modeling: user tables exist without a primary key.

   WHY THIS MATTERS:
   Tables without a primary key can allow duplicate or hard-to-identify rows,
   complicate application logic, replication, change tracking, data cleanup,
   and foreign key relationships. Primary keys also provide a clear row identity
   for operational and maintenance tasks.

   REMEDIATION:
   Review each table and define an appropriate primary key. If a natural key is
   not available, consider adding a surrogate key such as bigint identity or UUID,
   depending on application requirements.

   REFERENCES:
   https://www.postgresql.org/docs/current/ddl-constraints.html
   https://www.postgresql.org/docs/current/ddl-identity-columns.html
*/

v_AdditionalInfo := (
    WITH user_tables_without_pk AS (
        SELECT
            nsp.nspname AS schema_name,
            cls.relname AS table_name,
            cls.relkind AS relation_kind,
            pg_total_relation_size(cls.oid) AS table_size_bytes,
            COALESCE(st.n_live_tup, 0) AS estimated_live_rows
        FROM pg_class cls
        JOIN pg_namespace nsp
            ON nsp.oid = cls.relnamespace
        LEFT JOIN pg_stat_user_tables st
            ON st.relid = cls.oid
        WHERE cls.relkind IN ('r', 'p')
          AND nsp.nspname NOT IN ('pg_catalog', 'information_schema')
          AND NOT EXISTS (
              SELECT 1
              FROM pg_constraint con
              WHERE con.conrelid = cls.oid
                AND con.contype = 'p'
          )
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM user_tables_without_pk)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'UserTablesWithoutPrimaryKey',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schema_name,
                        'TableName', table_name,
                        'RelationKind', relation_kind,
                        'EstimatedLiveRows', estimated_live_rows,
                        'TableSizeBytes', table_size_bytes
                    )
                    ORDER BY table_size_bytes DESC
                )
                FROM user_tables_without_pk
            ),
            'FindingReason',
            'One or more user tables do not have a primary key.'
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
    'Data Modeling',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'All user tables have primary keys.'
        ELSE
            'Review user tables without primary keys and add an appropriate primary key where application design allows.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';