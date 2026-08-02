/*
    DESCRIPTION:

    What This Means: One or more PostgreSQL sequences -- typically backing a SERIAL/BIGSERIAL/IDENTITY primary key column -- have consumed at least 75% of the maximum value their data type allows (32,767 for smallint/smallserial sequences, 2,147,483,647 for integer/serial sequences, or 9,223,372,036,854,775,807 for bigint/bigserial sequences). A non-cycling sequence that reaches its maximum value cannot generate any further value: every subsequent nextval() call raises "ERROR: nextval: reached maximum value of sequence ...", and every INSERT that relies on that sequence's default fails immediately. This is not a gradual slowdown -- it is a hard, sudden application outage on every table that uses the exhausted sequence, and it strikes without warning unless the sequence's fill level is checked proactively. This exact failure mode has caused real, documented production outages (for example the widely referenced "the night the Postgres IDs ran out" incident), almost always on a table whose primary key was originally declared int4/SERIAL and received far more inserts over its lifetime than the original schema author expected -- a very common and easy-to-make data modeling mistake, since PostgreSQL's default SERIAL type is 4 bytes, not 8. The good state is a sequence with comfortable headroom (or one already using bigint/BIGSERIAL, whose practical range is never exhausted); the bad state is a sequence within reach of its ceiling, where every additional day of normal application traffic shortens the runway to an unplanned outage.

    Recommendations:
        For each flagged sequence, use the owning table/column reported below to plan a conversion of that column (and any dependent foreign key columns) to bigint before the sequence is exhausted. Prefer an online/low-lock migration on large or hot tables -- add a new bigint column, backfill it in batches while keeping it in sync with the original via a trigger or dual-write, then switch the application and constraints over -- rather than a blocking ALTER TABLE ... ALTER COLUMN TYPE bigint, which takes an exclusive lock and rewrites the whole table. As a short-term-only mitigation, ALTER SEQUENCE ... RESTART WITH a negative value combined with MINVALUE can buy limited extra runway, but it does not remove the underlying capacity limit and should not replace the bigint migration. For all new primary keys, use BIGSERIAL or GENERATED ... AS IDENTITY with bigint so this situation cannot recur.

    Scope : Database-level
    Category : Data Modeling

    More info:
        https://www.postgresql.org/docs/current/sql-createsequence.html
        https://www.postgresql.org/docs/current/view-pg-sequences.html
        https://www.crunchydata.com/blog/postgres-serials-should-be-bigint-and-how-to-migrate
        https://www.cybertec-postgresql.com/en/integer-overflow-in-sequence-generated-primary-keys/
        https://pganalyze.com/blog/5mins-postgres-integer-overflow
*/

/* ============================================================
   CHECK: Sequences Approaching Maximum Value
   ============================================================ */

v_AdditionalInfo := (
    WITH seq_usage AS (
        SELECT
            s.schemaname,
            s.sequencename,
            s.data_type,
            s.last_value,
            s.max_value,
            round(s.last_value::numeric / s.max_value::numeric * 100, 2) AS percent_used,
            d.refobjid::regclass::text AS owning_table,
            a.attname AS owning_column
        FROM pg_sequences s
        JOIN pg_class c
            ON c.relname = s.sequencename
           AND c.relnamespace = (SELECT n.oid FROM pg_namespace n WHERE n.nspname = s.schemaname)
        LEFT JOIN pg_depend d
            ON d.objid = c.oid
           AND d.classid = 'pg_class'::regclass
           AND d.refclassid = 'pg_class'::regclass
           AND d.deptype = 'a'
        LEFT JOIN pg_attribute a
            ON a.attrelid = d.refobjid
           AND a.attnum = d.refobjsubid
        WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema')
          AND s.increment_by > 0
          AND NOT s.cycle
          AND s.last_value IS NOT NULL
          AND s.max_value > 0
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object(
                'FindingReason', 'One or more non-cycling sequences have consumed at least 75% of their maximum value and risk exhausting their range, causing INSERT failures once reached.',
                'ThresholdPercentUsed', 75,
                'Sequences',
                jsonb_agg(
                    jsonb_build_object(
                        'SchemaName', schemaname,
                        'SequenceName', sequencename,
                        'DataType', data_type,
                        'LastValue', last_value,
                        'MaxValue', max_value,
                        'PercentUsed', percent_used,
                        'OwningTable', owning_table,
                        'OwningColumn', owning_column
                    )
                    ORDER BY percent_used DESC
                )
            )
        END
    FROM seq_usage
    WHERE percent_used >= 75
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
    'Data Modeling',
    'Database-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3, -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END, -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END, -- High: bigint migration on a large/hot table is nontrivial
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END, -- Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No sequences approaching their maximum value were detected.'
        ELSE
            'Convert the affected column(s) to bigint using an online/low-lock migration approach before the sequence is exhausted. Prefer BIGSERIAL or GENERATED ... AS IDENTITY with bigint for new primary keys.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';