/*
    DESCRIPTION:

    What This Means: password_encryption controls the hashing algorithm PostgreSQL
        uses whenever a role's password is set or changed (CREATE ROLE ... PASSWORD
        or ALTER ROLE ... PASSWORD, and the equivalent client tooling). This
        instance has password_encryption set to md5, so every password created or
        rotated from this point on -- new application accounts, routine password
        rotation, incident-response credential resets -- is stored in pg_authid
        using the legacy MD5 hash scheme instead of SCRAM-SHA-256. MD5 password
        verifiers use no per-value salt beyond the role name and are built on a
        broken cryptographic hash function; if pg_authid is ever exposed (a backup
        file, a replica snapshot, a misconfigured export), MD5 verifiers are far
        easier to attack offline than SCRAM-SHA-256 verifiers, which use a random
        salt and an iterated, computationally expensive key-derivation function.
        The exposure compounds over time: SCRAM became PostgreSQL's default in
        version 10 and the sole recommended method since, and PostgreSQL 18 now
        emits a deprecation warning every time a password is set while
        password_encryption = md5, signalling that md5 support is on a path to
        removal. A cluster left on md5 also creates an operational trap:
        tightening pg_hba.conf to require scram-sha-256 authentication (the modern
        best practice) will lock out every role whose password verifier is still
        md5-hashed, because a scram-sha-256 pg_hba entry cannot authenticate an
        md5 verifier.

    Recommendations:
        Set password_encryption = 'scram-sha-256' (ALTER SYSTEM SET
        password_encryption = 'scram-sha-256'; SELECT pg_reload_conf();, or the
        managed-service equivalent) so every new or rotated password is hashed
        with SCRAM-SHA-256. Then identify roles whose password verifier still
        predates the change and re-issue their passwords (ALTER ROLE <role> WITH
        PASSWORD '<new password>') so the stronger hash actually takes effect for
        them -- flipping the GUC alone does not rehash existing passwords. Only
        after existing roles are rotated, tighten pg_hba.conf entries from md5 to
        scram-sha-256 to enforce the stronger method at authentication time, and
        confirm application drivers and connection poolers support SCRAM before
        enforcing it exclusively.

    Scope : Cluster-level
    Category : Security

    More info:
        https://www.postgresql.org/docs/current/auth-password.html
        https://www.postgresql.org/docs/current/runtime-config-connection.html#GUC-PASSWORD-ENCRYPTION
        https://www.cybertec-postgresql.com/en/from-md5-to-scram-the-next-security-shift-in-postgresql/
*/

v_AdditionalInfo :=
(
    SELECT
        CASE
            WHEN current_setting('password_encryption', true) IS DISTINCT FROM 'md5'
                THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'PasswordEncryption', current_setting('password_encryption', true),
                'FindingReason', 'password_encryption is set to md5, so any password created or changed from now on is hashed with the legacy MD5 algorithm instead of SCRAM-SHA-256, and existing md5-hashed roles will be locked out if pg_hba.conf is later tightened to require scram-sha-256.'
            )
        END
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
    'Security',                                                   -- Category
    'Cluster-level',                                              -- Scope
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    3,                                                            -- High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,        -- None / Medium
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,        -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,        -- None / Medium
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'password_encryption is set to scram-sha-256; new and changed passwords use the stronger SCRAM-SHA-256 hash.'
        ELSE
            'Set password_encryption = ''scram-sha-256'' so new and rotated passwords use the stronger hash, then re-issue passwords for roles still hashed with md5 before tightening pg_hba.conf to require scram-sha-256.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
