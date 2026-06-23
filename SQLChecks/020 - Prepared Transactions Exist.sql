/*
    DESCRIPTION:
        Transactions: Prepared transactions exist in the PostgreSQL cluster.

        Prepared transactions are created by two-phase commit using PREPARE TRANSACTION.
        If they remain open for a long time, they can hold locks, retain transaction IDs,
        prevent vacuum cleanup, increase bloat, and create operational risk.

    Remediation:
        Review each prepared transaction and confirm whether it is still required.
        Commit or roll back old prepared transactions after validating with the
        owning application or transaction coordinator.
        If two-phase commit is not required, consider setting max_prepared_transactions
        to 0 after confirming application requirements.

    More info:
        https://www.postgresql.org/docs/current/sql-prepare-transaction.html
        https://www.postgresql.org/docs/current/view-pg-prepared-xacts.html
        https://www.postgresql.org/docs/current/runtime-config-resource.html
*/

/* ============================================================
   CHECK: Prepared Transactions Exist
   ============================================================ */

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'FindingReason', 'One or more prepared transactions exist in the PostgreSQL cluster.',
                'PreparedTransactionCount', COUNT(*),
                'MaxPreparedTransactions', current_setting('max_prepared_transactions', true),
                'PreparedTransactions',
                jsonb_agg
                (
                    jsonb_build_object
                    (
                        'TransactionId', transaction,
                        'GlobalTransactionId', gid,
                        'PreparedAt', prepared,
                        'PreparedAge', now() - prepared,
                        'Owner', owner,
                        'DatabaseName', database
                    )
                    ORDER BY prepared ASC
                )
            )
        END
    FROM pg_prepared_xacts
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
    'Transactions',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No prepared transactions were found.'
        ELSE
            'Review prepared transactions and commit or roll them back if they are no longer required. Validate with the application or transaction coordinator before taking action.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';