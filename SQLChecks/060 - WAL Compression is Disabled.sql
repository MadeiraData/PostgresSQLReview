/* DESCRIPTION:
   WAL configuration: WAL compression is disabled. PostgreSQL is not configured
   to compress full-page images written to WAL.

   WHY THIS MATTERS:
   When full-page writes occur, especially after checkpoints, PostgreSQL may
   generate a significant amount of WAL. Without WAL compression, write-heavy
   workloads can produce more WAL traffic, increase disk usage, increase
   replication bandwidth, and increase WAL archiving volume.

   REMEDIATION:
   Review wal_compression together with WAL generation rate, CPU capacity,
   replication bandwidth, archive storage usage, and checkpoint behavior.
   Consider enabling WAL compression if WAL volume is high and the server has
   enough CPU capacity to absorb the compression overhead.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-wal.html
   https://www.postgresql.org/docs/current/wal-configuration.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('wal_compression', true) NOT IN ('off', 'false', '0')
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'WalCompression',
                current_setting('wal_compression', true),
            'FullPageWrites',
                current_setting('full_page_writes', true),
            'WalLevel',
                current_setting('wal_level', true),
            'MaxWalSize',
                current_setting('max_wal_size', true),
            'ArchiveMode',
                current_setting('archive_mode', true),
            'FindingReason',
                'wal_compression is disabled, so full-page images written to WAL are not compressed.'
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
    'WAL and Checkpoints',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'WAL compression is enabled.'
        ELSE
            'Review WAL volume and consider enabling wal_compression if full-page-image WAL volume, archive storage, or replication bandwidth is significant.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';