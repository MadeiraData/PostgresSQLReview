
/*
    DESCRIPTION:

    What This Means: One or more tables are members of a logical replication
        publication that replicates UPDATE and/or DELETE operations, but the
        table itself has no adequate REPLICA IDENTITY -- it has neither a
        primary key nor an explicit REPLICA IDENTITY FULL/USING INDEX setting.
        Logical replication must send enough of the *old* row to the
        subscriber to identify which row to change on an UPDATE or a DELETE;
        for an INSERT the new row is self-contained, so REPLICA IDENTITY never
        matters there. PostgreSQL's default REPLICA IDENTITY DEFAULT silently
        falls back to using the table's primary key -- and if the table has no
        primary key, there is nothing for the publisher to send. This is not a
        replication-lag symptom: the very next UPDATE or DELETE statement
        issued against the table raises "ERROR: cannot update/delete a row in
        relation \"...\" because it does not have a replica identity and
        publishes updates/deletes" *on the publisher itself*, inside the
        application's own transaction. The write is rejected outright, not
        merely delayed -- every UPDATE and DELETE against that table fails
        until the identity is fixed or the table is removed from the
        publication, which is exactly the kind of outage that logical
        replication setups for CDC pipelines (Debezium, AWS DMS), read
        replicas, multi-region fan-out, and near-zero-downtime major-version
        upgrades are built to avoid causing in the first place.

    Recommendations:
        For each flagged table, either add a primary key (ALTER TABLE ...
        ADD CONSTRAINT ... PRIMARY KEY, ideally backed by a unique index
        already built with CREATE UNIQUE INDEX CONCURRENTLY to avoid a long
        exclusive lock), or set an explicit replica identity: ALTER TABLE ...
        REPLICA IDENTITY USING INDEX <a suitable unique, NOT NULL index> is
        the efficient choice when a natural key exists; ALTER TABLE ...
        REPLICA IDENTITY FULL is a one-line, no-rewrite fallback when no
        suitable key exists, at the cost of the subscriber having to match
        rows by comparing every column (slower on wide tables or tables
        without any usable index on the subscriber side). Validate which
        tables are actually reachable from a publication first (a table added
        to a FOR ALL TABLES publication is affected even if it was never
        explicitly listed) before deciding whether FULL is an acceptable
        trade-off or a proper key should be added instead.

    Scope : Database-level
    Category : Replication

    More info:
        https://www.postgresql.org/docs/current/logical-replication-publication.html
        https://www.postgresql.org/docs/current/sql-altertable.html#SQL-ALTERTABLE-REPLICA-IDENTITY
        https://www.postgresql.org/docs/current/sql-createpublication.html
*/

v_AdditionalInfo :=
(
    WITH publications_needing_identity AS
    (
        SELECT
            p.oid,
            p.puballtables
        FROM pg_publication p
        WHERE p.pubupdate OR p.pubdelete
    ),
    published_tables AS
    (
        SELECT DISTINCT
            c.oid AS relid,
            n.nspname AS schema_name,
            c.relname AS table_name,
            c.relreplident
        FROM pg_class c
        JOIN pg_namespace n
            ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
        AND   n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND   n.nspname NOT LIKE 'pg\_toast%'
        AND
        (
            EXISTS
            (
                SELECT 1
                FROM pg_publication_rel pr
                JOIN publications_needing_identity pni
                    ON pni.oid = pr.prpubid
                WHERE pr.prrelid = c.oid
            )
            OR EXISTS (SELECT 1 FROM publications_needing_identity pni WHERE pni.puballtables)
        )
    ),
    offenders AS
    (
        SELECT
            pt.schema_name,
            pt.table_name,
            pt.relreplident,
            pg_total_relation_size(pt.relid) AS table_size_bytes
        FROM published_tables pt
        WHERE pt.relreplident = 'n'
        OR
        (
            pt.relreplident = 'd'
            AND NOT EXISTS
            (
                SELECT 1
                FROM pg_constraint con
                WHERE con.conrelid = pt.relid
                AND   con.contype = 'p'
            )
        )
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM offenders) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'OffenderCount', (SELECT count(*) FROM offenders),
                'Offenders',
                (
                    SELECT jsonb_agg
                    (
                        jsonb_build_object
                        (
                            'SchemaName', schema_name,
                            'TableName', table_name,
                            'ReplicaIdentity', relreplident,
                            'TableSizeBytes', table_size_bytes
                        )
                        ORDER BY table_size_bytes DESC
                    )
                    FROM offenders
                ),
                'FindingReason', 'One or more tables published for UPDATE/DELETE replication have no primary key and no explicit REPLICA IDENTITY, so UPDATE and DELETE statements against them will be rejected outright with "cannot update/delete a row ... because it does not have a replica identity".'
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
    'Replication',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                           -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'All tables published for UPDATE/DELETE replication have an adequate replica identity (a primary key, or an explicit REPLICA IDENTITY FULL/USING INDEX).'
        ELSE
            'Add a primary key, or set an explicit REPLICA IDENTITY (USING INDEX for an efficient key, or FULL as a no-rewrite fallback), on every flagged table before the next UPDATE or DELETE is attempted against it through a publication that replicates updates or deletes.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
