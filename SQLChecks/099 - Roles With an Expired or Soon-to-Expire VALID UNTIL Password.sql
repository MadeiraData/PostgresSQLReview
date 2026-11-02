/*
    DESCRIPTION:

    What This Means: One or more login roles have a password VALID UNTIL
        date (pg_roles.rolvaliduntil / the VALID UNTIL clause of CREATE ROLE
        or ALTER ROLE) that has already passed, or will pass within the next
        7 days. VALID UNTIL sets an expiry on the role's password itself, not
        on the role: PostgreSQL silently stops accepting that role's password
        for authentication the instant the timestamp passes. Nothing else
        happens -- no warning is logged in advance, the role is not locked,
        disabled, or dropped, and every other attribute keeps working exactly
        as before. The role simply becomes unable to log in with a password
        from that moment on, and the only visible symptom is a failed
        connection the next time something tries to use it. Because this
        setting is easy to attach without noticing (a provisioning script,
        an onboarding runbook, or a security policy that sets a "temporary"
        credential with a fixed expiry) and nothing reminds anyone it is
        there before it fires, it is a common cause of an application
        suddenly losing its database connection with no corresponding
        deploy, config change, or credential rotation to explain it. The
        same trap applies to CDC connectors, replication/subscriber roles,
        monitoring agents, and any other automated client that authenticates
        with a password and is not watched as closely as the primary
        application account.

    Recommendations:
        For any role that should keep working, extend or clear its expiry
        with ALTER ROLE <role> VALID UNTIL 'infinity' (or a specific future
        date that matches an intentional credential-rotation policy) well
        before the current deadline. For a role that is genuinely meant to
        expire (a temporary contractor account, a time-boxed migration
        role), confirm the expiry date is still correct and that whoever
        depends on continued access is aware a hard cutoff is coming.
        Remember VALID UNTIL only governs password-based authentication --
        it does nothing for a role authenticating through another method
        (certificate, IAM, GSSAPI) -- so do not rely on it as the only way
        to retire an account.

    Scope : Cluster-level
    Category : Security

    More info:
        https://www.postgresql.org/docs/current/sql-createrole.html
        https://www.postgresql.org/docs/current/sql-alterrole.html
*/

v_AdditionalInfo :=
(
    WITH expiring_roles AS
    (
        SELECT
            rolname         AS RoleName,
            rolvaliduntil   AS ValidUntil,
            CASE WHEN rolvaliduntil < now() THEN 'expired' ELSE 'expiring soon' END AS Status
        FROM pg_roles
        WHERE rolcanlogin
          AND rolvaliduntil < (now() + interval '7 days')
    )
    SELECT
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM expiring_roles) THEN NULL::jsonb
            ELSE jsonb_build_object
            (
                'RoleCount', (SELECT count(*) FROM expiring_roles),
                'Roles',     (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.ValidUntil) FROM expiring_roles r),
                'FindingReason', 'One or more login roles have a password VALID UNTIL date that has already passed, or will pass within 7 days, which silently blocks that role''s password-based login with no advance warning.'
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
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,        -- None / High
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,        -- None / Low
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,        -- None / Low
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No login role has a password VALID UNTIL date that is expired or expiring within 7 days.'
        ELSE
            'Extend or clear VALID UNTIL (ALTER ROLE <role> VALID UNTIL ''infinity'' or a documented future date) for any role that should keep authenticating with a password, before its current deadline passes.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';
