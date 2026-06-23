
/*
    ====================================================================================
    Check #{CheckId}: {CheckTitle}
    ====================================================================================
*/

DO $pg_review_check$
DECLARE
    v_CheckId             integer := {CheckId};
    v_CheckTitle          text    := $check_title${CheckTitle}$check_title$;
    v_DeadlockRetry       boolean := false;

    v_ErrorSqlState       text;
    v_ErrorMessage        text;
    v_ErrorDetail         text;
    v_ErrorHint           text;
    v_ErrorContext        text;

    v_AdditionalInfo      jsonb;
BEGIN
    LOOP
        BEGIN
