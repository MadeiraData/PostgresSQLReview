/*
    DESCRIPTION:

    What This Means: Data checksums (data_checksums) are a cluster-wide setting, fixed
    when the data directory is initialized, that make PostgreSQL compute and verify a
    checksum on every 8 KB data page it reads and writes. When checksums are enabled, a
    page corrupted by a failing disk, a faulty storage controller, bad RAM, or a
    filesystem bug is caught the moment PostgreSQL reads that page: the read fails
    loudly with a checksum-failure error instead of silently returning garbage. When
    checksums are disabled, PostgreSQL has no way to detect this class of storage-level
    corruption at all. A corrupted page can be read, queried, replicated to standbys,
    and included in backups for months before anyone notices, and it is often first
    discovered only when the corruption is severe enough to crash a backend or return
    obviously wrong results -- by which point clean backups of the healthy data may no
    longer exist.

    Recommendations:
        Enable data checksums. On an existing cluster this requires an offline step:
        stop PostgreSQL and run "pg_checksums --enable -D <data_directory>"
        (PostgreSQL 12+), or enable checksums as part of the next major-version upgrade
        with "pg_upgrade --data-checksums" (PostgreSQL 18+), then restart. Schedule this
        during a maintenance window; the typical throughput overhead is a few percent on
        modern hardware, a low cost relative to the risk of undetected corruption. New
        clusters initialized on PostgreSQL 18+ have checksums enabled by default via
        initdb; confirm this was not explicitly disabled with "initdb --no-data-checksums".

    Scope : Cluster-level
    Category : Data Integrity

    More info:
        https://www.postgresql.org/docs/current/checksums.html
        https://www.postgresql.org/docs/current/app-pgchecksums.html
        https://www.postgresql.org/docs/current/app-initdb.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('data_checksums', true) = 'on'
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason', 'Data checksums are disabled for this data directory. PostgreSQL cannot detect storage-level page corruption (failing disk, controller, filesystem, or memory faults); such corruption can go unnoticed until it causes a crash or returns incorrect query results.',
            'Thresholds', jsonb_build_object('RequiredSetting', 'data_checksums = on'),
            'CurrentSetting', jsonb_build_object('data_checksums', current_setting('data_checksums', true))
        )
    END
);

INSERT INTO pg_review_results (
    CheckId, Title, Category, Scope, RequiresAttention,
    WorstCaseImpact, CurrentStateImpact, RecommendationEffort, RecommendationRisk,
    Recommendation, AdditionalInfo, ResponsibleDbaTeam
)
SELECT
    v_CheckId,
    v_CheckTitle,
    'Data Integrity',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3, -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END, -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END, -- High (offline pg_checksums or pg_upgrade + maintenance window)
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END, -- Medium
    CASE WHEN v_AdditionalInfo IS NULL
        THEN 'Data checksums are enabled.'
        ELSE 'Enable data checksums (pg_checksums --enable during an offline maintenance window, or via pg_upgrade --data-checksums on PostgreSQL 18+) so PostgreSQL can detect storage-level page corruption.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';