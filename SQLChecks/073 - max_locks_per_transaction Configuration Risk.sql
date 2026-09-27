
/*
    DESCRIPTION:

    What This Means: max_locks_per_transaction, together with max_connections
        and max_prepared_transactions, sizes a single shared hash table that
        PostgreSQL uses to track every heavyweight lock held anywhere in the
        cluster. Its capacity is max_locks_per_transaction * (max_connections +
        max_prepared_transactions). Despite the name, this is not a per-transaction
        cap -- it is the total shared pool every backend draws from. When the
        number of relations in a database (tables, partitions, indexes,
        sequences) approaches or exceeds a large share of that pool, an
        operation that must touch most of them in a single transaction --
        pg_dump, a full-database ANALYZE, a schema migration tool, or a query
        against a heavily partitioned table -- can exhaust the pool on its own.
        Once exhausted, every other session in the cluster starts failing with
        "ERROR: out of shared memory" and the hint to increase
        max_locks_per_transaction, even though those other sessions did nothing
        wrong -- this is a cluster-wide outage triggered by a single operation.

    Recommendations:
        Increase max_locks_per_transaction so the shared lock table comfortably
        exceeds the number of relations a single full-database operation would
        need to touch, then restart PostgreSQL -- max_locks_per_transaction is a
        postmaster-context setting and only takes effect after a restart (on
        Amazon RDS, changing it via the DB parameter group triggers this restart
        automatically). Where practical, also reduce the relation count itself,
        for example by consolidating excessive table partitioning or per-tenant
        schemas, since that lowers the risk independently of the lock table size.

    Scope : Cluster/database-level
    Category : Configuration

    More info:
        https://www.postgresql.org/docs/current/runtime-config-locks.html
        https://www.cybertec-postgresql.com/en/postgresql-you-might-need-to-increase-max_locks_per_transaction/
*/

v_AdditionalInfo :=
(
    WITH settings AS
    (
        SELECT
            current_setting('max_locks_per_transaction')::bigint AS max_locks_per_transaction,
            current_setting('max_connections')::bigint AS max_connections,
            current_setting('max_prepared_transactions')::bigint AS max_prepared_transactions
    ),
    capacity AS
    (
        SELECT
            max_locks_per_transaction,
            max_connections,
            max_prepared_transactions,
            max_locks_per_transaction * (max_connections + max_prepared_transactions) AS total_lock_slots
        FROM settings
    ),
    relations AS
    (
        SELECT count(*) AS user_relation_count
        FROM   pg_class c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  c.relkind IN ('r', 'p', 'i', 'S')
        AND    n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND    n.nspname NOT LIKE 'pg\_toast%'
    )
    SELECT
        CASE
            WHEN relations.user_relation_count <= (capacity.total_lock_slots / 2)
                THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'MaxLocksPerTransaction', capacity.max_locks_per_transaction,
                'MaxConnections', capacity.max_connections,
                'MaxPreparedTransactions', capacity.max_prepared_transactions,
                'TotalLockTableSlots', capacity.total_lock_slots,
                'UserRelationCountInDatabase', relations.user_relation_count,
                'FindingReason', 'A single transaction that locks every relation in this database (as pg_dump, a full ANALYZE, or a broad DDL/migration does) would already consume more than half of the cluster''s entire shared lock table, leaving little or no headroom for concurrent sessions and risking "ERROR: out of shared memory, you might need to increase max_locks_per_transaction".'
            )
        END
    FROM capacity, relations
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
    'Configuration',
    'Cluster/database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                           -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,       -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'max_locks_per_transaction provides comfortable headroom for the number of relations in this database.'
        ELSE
            'Increase max_locks_per_transaction (requires a server restart) so the shared lock table can safely accommodate a full-database operation such as pg_dump, ANALYZE, or a migration alongside normal concurrent traffic. Where practical, also reduce the relation count, for example by consolidating excessive partitioning or per-tenant schemas.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
