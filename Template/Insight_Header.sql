/*
    ====================================================================================
    Insight #{InsightId}: {InsightTitle}
    ====================================================================================
*/

DO $pg_review_insight$
DECLARE
    v_InsightId             integer := {InsightId};
    v_InsightTitle          text    := $insight_title${InsightTitle}$insight_title$;
    v_TopicArea             text    := $insight_topic${TopicArea}$insight_topic$;
    v_Scope                 text    := $insight_scope${Scope}$insight_scope$;
    v_RequiredExtensions    text[]  := {RequiresExtensions};
    v_MissingExtensions     text[];

    v_ErrorSqlState         text;
    v_ErrorMessage          text;
BEGIN
    -- A plain SELECT cannot reference a relation that does not exist, so an insight
    -- that needs an extension (for example pg_stat_statements) is skipped, not failed.
    SELECT array_agg(req.extname ORDER BY req.extname)
    INTO   v_MissingExtensions
    FROM   unnest(v_RequiredExtensions) AS req(extname)
    WHERE  NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension e WHERE e.extname = req.extname);

    IF v_MissingExtensions IS NOT NULL THEN
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
            'RequirementsNotMet',
            'Missing extension: ' || array_to_string(v_MissingExtensions, ', '),
            0,
            '[]'::jsonb,
            '[]'::jsonb
        );
        RETURN;
    END IF;

    BEGIN
        -- row_to_json (json, not jsonb) keeps the query's column order; it is used
        -- to derive Columns. Rows are stored as jsonb ordered by the rank column.
        WITH insight_rows AS MATERIALIZED
        (
            SELECT
                row_to_json(q)  AS row_json,
                q.rank          AS row_rank
            FROM
            (
