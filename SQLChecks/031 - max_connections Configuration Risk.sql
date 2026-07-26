
/* DESCRIPTION:
   What This Means: max_connections is configured with a potentially risky value.
   A high max_connections setting can increase memory pressure because each
   backend process consumes memory, and query operations may allocate additional
   memory such as work_mem.

   WHY THIS MATTERS:
   PostgreSQL uses one backend process per connection. Setting max_connections
   too high can reduce stability, increase context switching, and amplify memory
   usage during concurrent workloads.

   Recommendations:
   Review max_connections together with active connection usage, application
   concurrency, available RAM, work_mem, maintenance_work_mem, and connection
   pooling strategy. Consider using PgBouncer or another connection pooler
   instead of allowing excessive direct database connections.

   Scope : Cluster-level
   Category : Performance

   REFERENCES:
   https://www.postgresql.org/docs/current/runtime-config-connection.html
   https://www.postgresql.org/docs/current/runtime-config-resource.html
*/

v_AdditionalInfo := (
    SELECT CASE
        WHEN current_setting('max_connections')::int <= 500
            THEN NULL::jsonb
        ELSE jsonb_build_object(
            'MaxConnections', current_setting('max_connections')::int,
            'WorkMem', current_setting('work_mem', true),
            'WorkMemBytes', pg_size_bytes(current_setting('work_mem')),
            'EstimatedWorkMemExposureBytes',
                current_setting('max_connections')::bigint
                * pg_size_bytes(current_setting('work_mem')),
            'SharedBuffers', current_setting('shared_buffers', true),
            'FindingReason',
                'max_connections is configured above 500, which may create memory pressure and connection-management overhead.'
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
    3,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 3 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE WHEN v_AdditionalInfo IS NULL THEN 0 ELSE 2 END,
    CASE
        WHEN v_AdditionalInfo IS NULL
            THEN 'max_connections is within the expected global range.'
        ELSE
            'Review max_connections and consider reducing direct database connections by using connection pooling.'
    END,
    COALESCE(v_AdditionalInfo, '{}'::jsonb),
    'Production';