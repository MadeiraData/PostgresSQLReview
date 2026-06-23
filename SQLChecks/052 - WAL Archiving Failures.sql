/* DESCRIPTION:
   Backup and recovery: WAL archiving failures were detected. PostgreSQL has
   attempted to archive completed WAL segments, but one or more archive attempts
   have failed.

   WHY THIS MATTERS:
   WAL archiving failures can break point-in-time recovery continuity. If WAL
   segments are not archived successfully, backups may be unable to restore to
   the desired recovery point, and the server may accumulate WAL files until
   disk space is exhausted.

   REMEDIATION:
   Review pg_stat_archiver, PostgreSQL logs, archive_command or archive library
   configuration, archive destination availability, permissions, storage
   capacity, and backup tooling. Resolve archive failures immediately and
   confirm that new WAL segments are archiving successfully.

   REFERENCES:
   https://www.postgresql.org/docs/current/monitoring-stats.html
   https://www.postgresql.org/docs/current/continuous-archiving.html
   https://www.postgresql.org/docs/current/runtime-config-wal.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN COALESCE(failed_count, 0) = 0
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'ArchivedCount',
                archived_count,
            'LastArchivedWal',
                last_archived_wal,
            'LastArchivedTime',
                last_archived_time,
            'FailedCount',
                failed_count,
            'LastFailedWal',
                last_failed_wal,
            'LastFailedTime',
                last_failed_time,
            'StatsReset',
                stats_reset,
            'ArchiveMode',
                current_setting('archive_mode', true),
            'ArchiveCommand',
                current_setting('archive_command', true),
            'FindingReason',
                'pg_stat_archiver reports one or more failed WAL archive attempts since statistics were last reset.'
        )
    END
    FROM pg_stat_archiver
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
            THEN 'No WAL archiving failures were reported by pg_stat_archiver.'
        ELSE
            'Investigate WAL archiving failures and confirm that archive_command or archive library is successfully archiving new WAL segments.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';