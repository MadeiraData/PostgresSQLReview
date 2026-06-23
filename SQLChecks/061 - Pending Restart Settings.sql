/* DESCRIPTION:
   Configuration: pending restart settings were detected. One or more
   PostgreSQL configuration parameters have been changed but require a server
   restart before the new values take effect.

   WHY THIS MATTERS:
   Pending restart settings can create a mismatch between expected and active
   configuration. Administrators may believe a change is already applied when
   PostgreSQL is still running with the previous value. This can affect memory,
   WAL, replication, logging, and other important server behavior.

   REMEDIATION:
   Review all settings where pending_restart is true. Confirm whether the
   pending values are intentional, schedule a controlled restart if needed, and
   validate the active configuration after restart.

   REFERENCES:
   https://www.postgresql.org/docs/current/view-pg-settings.html
   https://www.postgresql.org/docs/current/config-setting.html
*/

v_AdditionalInfo := (
    WITH pending_restart_settings AS (
        SELECT
            name,
            setting,
            unit,
            boot_val,
            reset_val,
            source,
            sourcefile,
            sourceline,
            pending_restart,
            short_desc
        FROM pg_settings
        WHERE pending_restart = true
    )
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM pending_restart_settings)
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'PendingRestartSettings',
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'Name', name,
                        'CurrentSetting', setting,
                        'Unit', unit,
                        'BootValue', boot_val,
                        'ResetValue', reset_val,
                        'Source', source,
                        'SourceFile', sourcefile,
                        'SourceLine', sourceline,
                        'PendingRestart', pending_restart,
                        'Description', short_desc
                    )
                    ORDER BY name
                )
                FROM pending_restart_settings
            ),
            'FindingReason',
            'One or more PostgreSQL settings have pending_restart = true and require a server restart to take effect.'
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
    'Configuration',
    'Cluster-level',
    CASE WHEN v_AdditionalInfo IS NULL THEN false ELSE true END,
    2,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 1 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'No pending restart settings were found.'
        ELSE
            'Review pending restart settings and schedule a controlled PostgreSQL restart if the pending configuration should take effect.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';