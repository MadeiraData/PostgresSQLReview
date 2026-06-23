/* DESCRIPTION:
   Backup and recovery: WAL archiving is disabled. This means PostgreSQL is not
   configured to archive completed WAL segments for point-in-time recovery.

   WHY THIS MATTERS:
   Without WAL archiving, backup strategy may be limited to restoring only from
   base backups or platform snapshots. Point-in-time recovery may not be
   available, and recovery options after data corruption, accidental changes, or
   operational mistakes may be reduced.

   REMEDIATION:
   Enable archive_mode and configure a reliable archive_command or archive
   library according to the backup architecture. Validate that archived WAL files
   are being stored safely and that restore testing is performed regularly.

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-wal.html
   https://www.postgresql.org/docs/current/continuous-archiving.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('archive_mode', true) IN ('on', 'always')
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'ArchiveMode',
                current_setting('archive_mode', true),
            'ArchiveCommand',
                current_setting('archive_command', true),
            'WalLevel',
                current_setting('wal_level', true),
            'FindingReason',
                'archive_mode is disabled, so PostgreSQL is not archiving WAL segments for point-in-time recovery.'
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
    'Backup and Recovery',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'WAL archiving is enabled.'
        ELSE
            'Enable WAL archiving if point-in-time recovery is required for this PostgreSQL server.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';