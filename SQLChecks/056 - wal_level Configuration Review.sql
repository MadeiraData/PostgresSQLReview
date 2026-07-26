
/* DESCRIPTION:
   What This Means: wal_level configuration should be reviewed.
   wal_level controls how much information PostgreSQL writes to WAL for crash
   recovery, replication, logical decoding, and point-in-time recovery support.

   WHY THIS MATTERS:
   If wal_level is set too low for the required architecture, streaming
   replication, logical replication, CDC tooling, or backup and recovery
   workflows may not work as expected. Higher wal_level settings can also
   increase WAL volume, so the setting should match the actual business and
   platform requirements.

   Recommendations:
   Review wal_level together with replication usage, logical decoding or CDC
   requirements, backup tooling, archive_mode, max_wal_senders, and replication
   slots. Use replica for physical replication and PITR requirements, and use
   logical only when logical replication or decoding is required.

   Scope : Cluster-level
   Category : Backup

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-wal.html
   https://www.postgresql.org/docs/current/wal-configuration.html
   https://www.postgresql.org/docs/current/logicaldecoding-explanation.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('wal_level', true) IN ('replica', 'logical')
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'WalLevel',
                current_setting('wal_level', true),
            'ArchiveMode',
                current_setting('archive_mode', true),
            'MaxWalSenders',
                current_setting('max_wal_senders', true),
            'MaxReplicationSlots',
                current_setting('max_replication_slots', true),
            'FindingReason',
                'wal_level is not configured as replica or logical, which may limit replication, PITR, or logical decoding capabilities.'
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
    'Replication',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'wal_level is configured for replication, recovery, or logical decoding use cases.'
        ELSE
            'Review wal_level and configure it according to replication, backup, PITR, and logical decoding requirements.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';