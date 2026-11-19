
            ) q
        )
        INSERT INTO pg_review_insights
        (
            InsightId,
            Title,
            TopicArea,
            Scope,
            Status,
            Message,
            RowCount,
            Columns,
            Rows
        )
        SELECT
            v_InsightId,
            v_InsightTitle,
            v_TopicArea,
            v_Scope,
            'OK',
            NULL,
            count(*)::integer,
            COALESCE
            (
                (
                    SELECT jsonb_agg(k.key ORDER BY k.ord)
                    FROM   (SELECT ir.row_json FROM insight_rows ir LIMIT 1) first_row
                    CROSS JOIN LATERAL json_object_keys(first_row.row_json) WITH ORDINALITY AS k(key, ord)
                ),
                '[]'::jsonb
            ),
            COALESCE(jsonb_agg(r.row_json::jsonb ORDER BY r.row_rank NULLS LAST), '[]'::jsonb)
        FROM insight_rows r;

    EXCEPTION
        WHEN OTHERS THEN

            GET STACKED DIAGNOSTICS
                v_ErrorSqlState = RETURNED_SQLSTATE,
                v_ErrorMessage  = MESSAGE_TEXT;

            INSERT INTO pg_review_insights
            (
                InsightId,
                Title,
                TopicArea,
                Scope,
                Status,
                Message,
                RowCount,
                Columns,
                Rows
            )
            VALUES
            (
                v_InsightId,
                v_InsightTitle,
                v_TopicArea,
                v_Scope,
                'Error',
                v_ErrorSqlState || ': ' || v_ErrorMessage,
                0,
                '[]'::jsonb,
                '[]'::jsonb
            );
    END;
END
$pg_review_insight$;
