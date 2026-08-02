/*
    DESCRIPTION:

    What This Means: The PostgreSQL community supports every major version for exactly 5 years
    after its initial release, with no "LTS" exception. After that window, a final minor release
    ships and the version then receives NO further security patches, NO bug fixes, and NO
    compatibility updates -- ever. Any newly discovered vulnerability (including ones already
    fixed in supported versions) stays permanently unpatched on an end-of-life instance. This
    check flags a cluster that is either already past its major version's end-of-life date, or
    within 180 days of reaching it.

    Recommendations:
        Plan and execute a major-version upgrade before (or as soon as possible after) the
        end-of-life date: test the target version thoroughly in a staging environment first,
        then upgrade via pg_upgrade (in-place, fastest path) or logical replication (for a
        near-zero-downtime cutover). Do not treat continuing to run an unsupported version as a
        long-term option -- no further security or bug fixes will ever be released for it, and
        vendor "extended support" offerings are a stopgap, not a substitute for upgrading.

    Scope : Cluster-level
    Category : Version and Patching

    More info:
        https://www.postgresql.org/support/versioning/
        https://www.postgresql.org/support/security/
*/

v_AdditionalInfo := (
    WITH version_eol(major_key, eol_date) AS (
        VALUES
            (9.2::numeric,  '2017-11-09'::date),
            (9.3::numeric,  '2018-11-08'::date),
            (9.4::numeric,  '2020-02-13'::date),
            (9.5::numeric,  '2021-02-11'::date),
            (9.6::numeric,  '2021-11-11'::date),
            (10::numeric,   '2022-11-10'::date),
            (11::numeric,   '2023-11-09'::date),
            (12::numeric,   '2024-11-21'::date),
            (13::numeric,   '2025-11-13'::date),
            (14::numeric,   '2026-11-12'::date),
            (15::numeric,   '2027-11-11'::date),
            (16::numeric,   '2028-11-09'::date),
            (17::numeric,   '2029-11-08'::date),
            (18::numeric,   '2030-11-14'::date)
    ),
    current_ver AS (
        SELECT
            current_setting('server_version_num')::integer AS version_num,
            version() AS full_version_string
    ),
    normalized AS (
        SELECT
            version_num,
            full_version_string,
            CASE
                WHEN version_num >= 100000 THEN (version_num / 10000)::numeric
                ELSE (9 + ((version_num / 100) % 100) / 10.0)::numeric
            END AS major_key
    FROM current_ver
    ),
    evaluated AS (
        SELECT
            n.full_version_string,
            n.major_key,
            e.eol_date,
            CASE
                WHEN e.eol_date IS NULL THEN 'unknown'
                WHEN CURRENT_DATE >= e.eol_date THEN 'past_eol'
                WHEN CURRENT_DATE >= (e.eol_date - INTERVAL '180 days') THEN 'approaching_eol'
                ELSE 'supported'
            END AS status
        FROM normalized n
        LEFT JOIN version_eol e ON e.major_key = n.major_key
    )
    SELECT CASE
        WHEN status IN ('supported', 'unknown')
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'FindingReason', CASE
                WHEN status = 'past_eol'
                    THEN 'This PostgreSQL major version has reached end-of-life: the community no longer releases security or bug fixes for it.'
                ELSE 'This PostgreSQL major version is within 180 days of end-of-life; no further security or bug fixes will be released after that date.'
            END,
            'Thresholds', jsonb_build_object('ApproachingWindowDays', 180),
            'CurrentVersion', full_version_string,
            'MajorVersion', major_key,
            'EndOfLifeDate', eol_date,
            'DaysUntilEndOfLife', (eol_date - CURRENT_DATE)
        )
    END
    FROM evaluated
);

INSERT INTO pg_review_results (
    CheckId, Title, Category, Scope, RequiresAttention,
    WorstCaseImpact, CurrentStateImpact, RecommendationEffort, RecommendationRisk,
    Recommendation, AdditionalInfo, ResponsibleDbaTeam
)
SELECT
    v_CheckId,
    v_CheckTitle,
    'Version and Patching',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,
    CASE
        WHEN v_AdditionalInfo IS NULL THEN 0
        WHEN v_AdditionalInfo->>'FindingReason' LIKE 'This PostgreSQL major version has reached end-of-life%' THEN 3 -- High
        ELSE 2 -- Medium
    END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END, -- High: major version upgrades are always High effort
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END, -- Medium: well-established upgrade paths (pg_upgrade / logical replication), but real downtime/compatibility risk
    CASE WHEN v_AdditionalInfo IS NULL
        THEN 'PostgreSQL major version is within its supported window. No action required.'
        ELSE 'Plan and execute a major-version upgrade before (or as soon as possible after) the end-of-life date: test the target version in staging, then upgrade via pg_upgrade (in-place, fastest) or logical replication (for near-zero-downtime cutover). Do not treat continuing to run an unsupported version as a long-term option -- no further security or bug fixes will ever be released for it.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';