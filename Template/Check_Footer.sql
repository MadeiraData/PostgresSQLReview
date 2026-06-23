
            EXIT;

        EXCEPTION
            WHEN deadlock_detected THEN

                GET STACKED DIAGNOSTICS
                    v_ErrorSqlState = RETURNED_SQLSTATE,
                    v_ErrorMessage  = MESSAGE_TEXT,
                    v_ErrorDetail   = PG_EXCEPTION_DETAIL,
                    v_ErrorHint     = PG_EXCEPTION_HINT,
                    v_ErrorContext  = PG_EXCEPTION_CONTEXT;

                INSERT INTO pg_review_errors
                (
                    CheckId,
                    Title,
                    ErrorSqlState,
                    ErrorMessage,
                    ErrorDetail,
                    ErrorHint,
                    ErrorContext,
                    IsDeadlockRetry
                )
                VALUES
                (
                    v_CheckId,
                    v_CheckTitle,
                    v_ErrorSqlState,
                    v_ErrorMessage,
                    v_ErrorDetail,
                    v_ErrorHint,
                    v_ErrorContext,
                    v_DeadlockRetry
                );

                IF v_DeadlockRetry = false THEN
                    v_DeadlockRetry := true;
                ELSE
                    EXIT;
                END IF;

            WHEN OTHERS THEN

                GET STACKED DIAGNOSTICS
                    v_ErrorSqlState = RETURNED_SQLSTATE,
                    v_ErrorMessage  = MESSAGE_TEXT,
                    v_ErrorDetail   = PG_EXCEPTION_DETAIL,
                    v_ErrorHint     = PG_EXCEPTION_HINT,
                    v_ErrorContext  = PG_EXCEPTION_CONTEXT;

                INSERT INTO pg_review_errors
                (
                    CheckId,
                    Title,
                    ErrorSqlState,
                    ErrorMessage,
                    ErrorDetail,
                    ErrorHint,
                    ErrorContext,
                    IsDeadlockRetry
                )
                VALUES
                (
                    v_CheckId,
                    v_CheckTitle,
                    v_ErrorSqlState,
                    v_ErrorMessage,
                    v_ErrorDetail,
                    v_ErrorHint,
                    v_ErrorContext,
                    false
                );

                EXIT;

        END;
    END LOOP;
END
$pg_review_check$;