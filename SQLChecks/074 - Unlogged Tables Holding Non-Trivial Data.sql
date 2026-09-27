/*
    DESCRIPTION:

    What This Means: One or more UNLOGGED tables or materialized views in this
        database contain data. An UNLOGGED relation skips Write-Ahead Log (WAL)
        writes entirely in exchange for faster writes, but that trade-off has
        three consequences that are easy to forget once the object is in
        production use: (1) PostgreSQL automatically and silently truncates
        every UNLOGGED relation during crash recovery after an unclean
        shutdown, OS crash, or OOM kill -- there is no warning and no undo;
        (2) UNLOGGED relations are never streamed to physical replicas, so a
        failover or switchover to a standby leaves the relation permanently
        empty on the new primary even though the original primary never
        crashed; and (3) pg_dump and physical base backups exclude UNLOGGED
        relation contents by default, so the usual backup and restore path
        does not protect this data either. Together this means an UNLOGGED
        relation that quietly accumulated real data can lose that data
        completely and irrecoverably, with no error at write time to hint
        that anything was ever at risk.

    Recommendations:
        Review each listed relation with the table/schema owner and confirm
        its contents are genuinely disposable or can be cheaply regenerated
        (for example a request-scoped cache, a session store, or a staging
        table reloaded by ETL). UNLOGGED is often the correct, intentional
        choice for exactly that kind of data and does not need to change.
        If instead the data must survive a crash, an unclean shutdown, a
        replica promotion, or must appear in pg_dump/base backups, convert
        the table with ALTER TABLE <table> SET LOGGED -- note this rewrites
        the entire table and takes an ACCESS EXCLUSIVE lock, so schedule it
        for a maintenance window on large tables. A materialized view has no
        SET LOGGED equivalent; recreate it with CREATE MATERIALIZED VIEW
        (without UNLOGGED) and swap it in.

    Scope : Database-level
    Category : Data Integrity

    More info:
        https://www.postgresql.org/docs/current/sql-createtable.html
        https://www.postgresql.org/docs/current/sql-altertable.html
        https://www.postgresql.org/docs/current/catalog-pg-class.html
        https://www.crunchydata.com/blog/postgresl-unlogged-tables
        https://pganalyze.com/blog/5mins-postgres-unlogged-tables
*/

v_AdditionalInfo :=
(
    WITH unlogged_relations_with_data AS
    (
        SELECT
            n.nspname AS schema_name,
            c.relname AS relation_name,
            CASE c.relkind WHEN 'r' THEN 'Table' WHEN 'm' THEN 'Materialized View' END AS relation_kind,
            c.reltuples::bigint AS estimated_row_count,
            pg_total_relation_size(c.oid) AS relation_size_bytes,
            pg_size_pretty(pg_total_relation_size(c.oid)) AS relation_size
        FROM pg_class c
        JOIN pg_namespace n
            ON n.oid = c.relnamespace
        WHERE c.relpersistence = 'u'
          AND c.relkind IN ('r', 'm')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND c.reltuples > 0
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM unlogged_relations_with_data) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more UNLOGGED tables or materialized views contain data. UNLOGGED relations are truncated on crash recovery, are never sent to physical replicas, and are excluded from pg_dump and physical base backups by default.',
                'ImportantNote', 'UNLOGGED is often an intentional, valid choice for disposable cache or staging data. Review each relation to confirm its contents are truly disposable or cheaply regenerable before treating this as a problem.',
                'UnloggedRelations',
                (
                    SELECT jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', schema_name,
                            'RelationName', relation_name,
                            'RelationKind', relation_kind,
                            'EstimatedRowCount', estimated_row_count,
                            'RelationSize', relation_size,
                            'RelationSizeBytes', relation_size_bytes
                        )
                        ORDER BY relation_size_bytes DESC
                    )
                    FROM unlogged_relations_with_data
                )
            )
        END
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
    'Data Integrity',                                            -- Category
    'Database-level',                                            -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                            -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,        -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,        -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,        -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No UNLOGGED tables or materialized views containing data were found.'
        ELSE
            'Review each listed UNLOGGED relation with its owner to confirm the data is disposable or cheaply regenerable. If it must survive a crash, unclean shutdown, replica promotion, or must be captured by pg_dump/base backups, convert it to a logged relation (ALTER TABLE ... SET LOGGED for tables; recreate without UNLOGGED for materialized views).'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
