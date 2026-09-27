
/*
    DESCRIPTION:

    What This Means: This PostgreSQL server is running a minor version older than the latest
        security-patched minor release for its major branch. Unlike a major-version upgrade,
        a minor release never changes on-disk format or breaks compatibility -- every minor
        release contains only bug and security fixes, so staying behind buys no stability and
        only accumulates known, publicly disclosed vulnerabilities. The August 2026 cumulative
        release (18.6 / 17.11 / 16.15 / 15.19 / 14.24) fixed 28 CVEs in a single release, the
        most PostgreSQL has ever shipped at once, including multiple CVSS 8.8 vulnerabilities
        that let an authenticated user execute arbitrary code (a to_char buffer overflow, a
        plperl tied-object overflow, a pg_stat_statements overflow, and a refint plan-cache
        type-confusion bug) and CVE-2026-6471 ("PostGREShell"), which lets any role holding
        only the REPLICATION privilege escalate to permanent superuser and a persistent
        server-side backdoor via logical decoding. None of this is caught by a check on the
        major version's end-of-life date: a fully supported, non-EOL major branch can still be
        running a minor release with these exact vulnerabilities unpatched.

    Recommendations:
        Apply the latest minor release for the running major branch as soon as possible.
        Minor updates require only a binary swap and a restart (a few seconds of downtime on a
        single instance, effectively zero downtime with a rolling restart across a replica
        set) -- the PostgreSQL project explicitly designs every minor release to be safe to
        apply without testing beyond a normal restart. Do not defer minor updates the way a
        major-version upgrade might be deferred: there is no compatibility trade-off, only
        accumulating exposure to already-public vulnerabilities and their exploit code.

    Scope : Cluster-level
    Category : Version and Patching

    More info:
        https://www.postgresql.org/support/versioning/
        https://www.postgresql.org/support/security/
        https://www.postgresql.org/about/news/postgresql-186-1711-1615-1519-1424-and-19-beta-3-released-3365/
*/

v_AdditionalInfo :=
(
    WITH minimum_patched_minor(major_version, min_minor, latest_security_release_date) AS
    (
        VALUES
            (14::numeric, 24, '2026-08-13'::date),
            (15::numeric, 19, '2026-08-13'::date),
            (16::numeric, 15, '2026-08-13'::date),
            (17::numeric, 11, '2026-08-13'::date),
            (18::numeric, 6,  '2026-08-13'::date)
    ),
    current_ver AS
    (
        SELECT
            current_setting('server_version_num')::integer AS version_num,
            version()                                       AS full_version_string
    ),
    normalized AS
    (
        SELECT
            full_version_string,
            (version_num / 10000)::numeric AS major_version,
            (version_num % 10000)          AS current_minor
        FROM current_ver
        WHERE version_num >= 100000
    )
    SELECT
        CASE
            WHEN m.min_minor IS NULL OR n.current_minor >= m.min_minor THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'CurrentVersion', n.full_version_string,
                'MajorVersion', n.major_version,
                'CurrentMinor', n.current_minor,
                'MinimumPatchedMinor', m.min_minor,
                'MinorReleasesBehind', m.min_minor - n.current_minor,
                'LatestSecurityReleaseDate', m.latest_security_release_date,
                'FindingReason', 'This PostgreSQL minor version is missing security fixes released in a later minor release on the same major branch; the most recent PostgreSQL security release fixed multiple actively-exploitable vulnerabilities, some allowing arbitrary code execution or escalation to superuser.'
            )
        END
    FROM normalized n
    LEFT JOIN minimum_patched_minor m ON m.major_version = n.major_version
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
    'Version and Patching',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,      -- High: unpatched CVEs in this class include unauthenticated-adjacent RCE and privilege escalation to superuser
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,       -- None / High: publicly known, exploitable vulnerabilities are present right now
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low: a minor update is a binary swap plus restart, no schema or compatibility work
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,       -- None / Low: minor releases are designed and tested to never break compatibility
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'This PostgreSQL server is already on the latest security-patched minor release for its major branch.'
        ELSE
            'Apply the latest minor release for the running major branch as soon as possible -- schedule a restart, no compatibility testing is required beyond that.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
