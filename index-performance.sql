-- Index Usage Statistics with Ratio Analysis
SELECT 
    i.name AS index_name,
    OBJECT_NAME(i.object_id) AS table_name,
    i.type_desc,
    
    -- Usage Statistics
    ISNULL(s.user_seeks, 0) AS user_seeks,
    ISNULL(s.user_scans, 0) AS user_scans,
    ISNULL(s.user_lookups, 0) AS user_lookups,
    ISNULL(s.user_updates, 0) AS user_updates,
    
    -- Calculated Ratios and Metrics
    (ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) + ISNULL(s.user_lookups, 0)) AS total_reads,
    
    -- Scan to Seek Ratio (Higher = Less Efficient)
    CASE 
        WHEN ISNULL(s.user_seeks, 0) = 0 THEN 
            CASE WHEN ISNULL(s.user_scans, 0) > 0 THEN 999999 ELSE 0 END
        ELSE CAST(ISNULL(s.user_scans, 0) AS FLOAT) / NULLIF(s.user_seeks, 0)
    END AS scan_to_seek_ratio,
    
    -- Read to Write Ratio (Lower = High Maintenance Cost)
    CASE 
        WHEN ISNULL(s.user_updates, 0) = 0 THEN 999999
        ELSE CAST((ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) + ISNULL(s.user_lookups, 0)) AS FLOAT) 
             / NULLIF(s.user_updates, 0)
    END AS read_to_write_ratio,
    
    -- Lookup Percentage (High = May need covering index)
    CASE 
        WHEN (ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) + ISNULL(s.user_lookups, 0)) = 0 THEN 0
        ELSE CAST(ISNULL(s.user_lookups, 0) AS FLOAT) * 100.0 / 
             NULLIF((ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) + ISNULL(s.user_lookups, 0)), 0)
    END AS lookup_percentage,
    
    -- Index Recommendation Flags
    CASE 
        WHEN (ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) + ISNULL(s.user_lookups, 0)) = 0 
             AND ISNULL(s.user_updates, 0) < 100 
             AND i.type_desc != 'CLUSTERED'
        THEN 'CONSIDER DROPPING - Unused'
        
        WHEN ISNULL(s.user_scans, 0) > 0 
             AND ISNULL(s.user_seeks, 0) = 0 
             AND ISNULL(s.user_scans, 0) > 1000
        THEN 'OPTIMIZE - High Scans, No Seeks'
        
        WHEN ISNULL(s.user_seeks, 0) > 0 
             AND CAST(ISNULL(s.user_scans, 0) AS FLOAT) / NULLIF(s.user_seeks, 0) > 10
        THEN 'OPTIMIZE - Poor Scan/Seek Ratio'
        
        WHEN ISNULL(s.user_lookups, 0) > 0 
             AND CAST(ISNULL(s.user_lookups, 0) AS FLOAT) * 100.0 / 
                 NULLIF((ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) + ISNULL(s.user_lookups, 0)), 0) > 50
        THEN 'COVERING INDEX - High Key Lookups'
        
        WHEN ISNULL(s.user_updates, 0) > 0 
             AND CAST((ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) + ISNULL(s.user_lookups, 0)) AS FLOAT) 
                 / NULLIF(s.user_updates, 0) < 0.1
        THEN 'HIGH MAINTENANCE - More Updates than Reads'
        
        WHEN (ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0)) > 10000 
             AND ISNULL(s.user_lookups, 0) = 0
        THEN ' PERFORMING WELL'
        
        ELSE 'NORMAL USAGE'
    END AS recommendation,
    
    -- Priority Score (Higher = More Urgent)
    CASE 
        WHEN (ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) + ISNULL(s.user_lookups, 0)) = 0 
             AND i.type_desc != 'CLUSTERED' THEN 90
        WHEN ISNULL(s.user_scans, 0) > 100000 AND ISNULL(s.user_seeks, 0) = 0 THEN 80
        WHEN CAST(ISNULL(s.user_scans, 0) AS FLOAT) / NULLIF(s.user_seeks, 0) > 50 THEN 70
        WHEN ISNULL(s.user_lookups, 0) > 10000 THEN 60
        ELSE 0
    END AS priority_score,
    
    i.object_id,
    s.last_user_seek,
    s.last_user_scan,
    s.last_user_lookup,
    s.last_user_update

FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats s 
    ON i.object_id = s.object_id 
    AND i.index_id = s.index_id 
    AND s.database_id = DB_ID()
WHERE i.object_id > 100  -- Exclude system objects
    AND i.name IS NOT NULL  -- Exclude heaps
    
ORDER BY 
    priority_score DESC,
    total_reads DESC,
    scan_to_seek_ratio DESC;

-- Additional query for tables that might need new indexes
-- (High table scans without corresponding index usage)
SELECT 
    'TABLE SCAN ANALYSIS' AS analysis_type,
    OBJECT_NAME(s.object_id) AS table_name,
    s.user_scans AS table_scans,
    s.user_seeks AS table_seeks,
    s.user_lookups AS table_lookups,
    CASE 
        WHEN s.user_scans > 1000 AND s.user_seeks < (s.user_scans * 0.1)
        THEN 'HIGH PRIORITY - Consider adding selective indexes'
        WHEN s.user_scans > 500 AND s.user_seeks < (s.user_scans * 0.2)
        THEN 'MEDIUM - Monitor query patterns'
        ELSE 'Normal'
    END AS table_recommendation
FROM sys.dm_db_index_usage_stats s
WHERE s.database_id = DB_ID()
    AND s.index_id = 0  -- Heap scans only
    AND s.user_scans > 100
ORDER BY s.user_scans DESC;

-- Method 1: Extract individual statements using offset positions
SELECT 
    OBJECT_NAME(qt.objectid) AS procedure_name,
    qs.sql_handle,
    qs.statement_start_offset,
    qs.statement_end_offset,
    -- Extract the individual statement
    CASE 
        WHEN qs.statement_start_offset = 0 AND qs.statement_end_offset = -1 
        THEN qt.text  -- Full procedure if no specific statement
        ELSE 
            SUBSTRING(qt.text, 
                     (qs.statement_start_offset/2) + 1,
                     ((CASE qs.statement_end_offset
                         WHEN -1 THEN DATALENGTH(qt.text)
                         ELSE qs.statement_end_offset
                       END - qs.statement_start_offset)/2) + 1)
    END AS individual_statement,
    qs.execution_count,
    qs.total_logical_reads,
    qs.total_logical_writes,
    qs.last_execution_time
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
WHERE qt.text LIKE '%your_table_name%'
    AND qs.statement_start_offset > 0  -- Filter out full procedure entries
ORDER BY qs.total_logical_writes DESC;

-- Method 2: Query Store approach (SQL Server 2016+) - Much cleaner!
SELECT 
    qst.query_sql_text AS individual_query,
    qsq.object_name AS procedure_name,
    qsrs.count_executions,
    qsrs.avg_logical_io_reads,
    qsrs.avg_logical_io_writes,
    qsrs.last_execution_time,
    qsrs.avg_duration / 1000.0 AS avg_duration_ms
FROM sys.query_store_query_text qst
INNER JOIN sys.query_store_query qsq ON qst.query_text_id = qsq.query_text_id
INNER JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
INNER JOIN sys.query_store_runtime_stats qsrs ON qsp.plan_id = qsrs.plan_id
WHERE qst.query_sql_text LIKE '%your_table_name%'
    AND qsq.object_name IS NOT NULL  -- Only stored procedure statements
    AND LEN(qst.query_sql_text) < 2000  -- Filter out very long statements
ORDER BY qsrs.avg_logical_io_writes DESC;

-- Method 3: Plan Cache with better filtering
WITH StatementDetails AS (
    SELECT 
        qt.text AS full_text,
        qs.statement_start_offset,
        qs.statement_end_offset,
        qs.execution_count,
        qs.total_logical_writes,
        qs.total_logical_reads,
        OBJECT_NAME(qt.objectid) AS procedure_name,
        -- Clean statement extraction
        LTRIM(RTRIM(
            CASE 
                WHEN qs.statement_start_offset = 0 AND qs.statement_end_offset = -1 
                THEN 'Full Procedure'
                ELSE 
                    SUBSTRING(qt.text, 
                             (qs.statement_start_offset/2) + 1,
                             ((CASE qs.statement_end_offset
                                 WHEN -1 THEN DATALENGTH(qt.text)
                                 ELSE qs.statement_end_offset
                               END - qs.statement_start_offset)/2) + 1)
            END
        )) AS clean_statement
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
    WHERE qt.text LIKE '%your_table_name%'
)
SELECT 
    procedure_name,
    clean_statement,
    execution_count,
    total_logical_writes,
    total_logical_reads,
    CASE 
        WHEN total_logical_reads = 0 THEN 999999
        ELSE CAST(total_logical_writes AS FLOAT) / NULLIF(total_logical_reads, 0)
    END AS write_to_read_ratio
FROM StatementDetails
WHERE clean_statement != 'Full Procedure'
    AND clean_statement NOT LIKE 'DECLARE%'  -- Filter out variable declarations
    AND clean_statement NOT LIKE 'SET%'      -- Filter out SET statements
    AND LEN(clean_statement) > 20            -- Filter out very short statements
ORDER BY write_to_read_ratio DESC;

-- Method 4: Live Extended Events capture (create session first, then query)
-- First, create the session:
/*
CREATE EVENT SESSION [CaptureIndividualStatements] ON SERVER 
ADD EVENT sqlserver.sql_statement_completed(
    ACTION(sqlserver.sql_text, sqlserver.tsql_stack)
    WHERE (sqlserver.like_i_sql_unicode_string(sqlserver.sql_text, N'%your_table_name%'))
),
ADD EVENT sqlserver.sql_statement_starting(
    ACTION(sqlserver.sql_text, sqlserver.tsql_stack)
    WHERE (sqlserver.like_i_sql_unicode_string(sqlserver.sql_text, N'%your_table_name%'))
)
ADD TARGET package0.ring_buffer(SET max_memory=(102400));

ALTER EVENT SESSION [CaptureIndividualStatements] ON SERVER STATE = START;
*/

-- Then query the live data:
SELECT 
    event_data.value('(event/@name)[1]', 'varchar(50)') AS event_name,
    event_data.value('(event/data[@name="statement"]/value)[1]', 'varchar(max)') AS sql_statement,
    event_data.value('(event/@timestamp)[1]', 'datetime2') AS event_time,
    event_data.value('(event/action[@name="sql_text"]/value)[1]', 'varchar(max)') AS full_sql_text
FROM (
    SELECT CAST(target_data AS XML) AS target_data
    FROM sys.dm_xe_sessions AS s
    INNER JOIN sys.dm_xe_session_targets AS st ON s.address = st.event_session_address
    WHERE s.name = 'CaptureIndividualStatements'
        AND st.target_name = 'ring_buffer'
) AS tab
CROSS APPLY target_data.nodes('RingBufferTarget/event') AS q(event_data)
ORDER BY event_time DESC;

-- Method 5: Simple approach for immediate results - Focus on statement patterns
SELECT DISTINCT
    OBJECT_NAME(qt.objectid) AS procedure_name,
    CASE 
        WHEN CHARINDEX('UPDATE', UPPER(qt.text)) > 0 
        THEN 'Contains UPDATE statements'
        WHEN CHARINDEX('INSERT', UPPER(qt.text)) > 0 
        THEN 'Contains INSERT statements'
        WHEN CHARINDEX('DELETE', UPPER(qt.text)) > 0 
        THEN 'Contains DELETE statements'
        WHEN CHARINDEX('MERGE', UPPER(qt.text)) > 0 
        THEN 'Contains MERGE statements'
        ELSE 'Other operations'
    END AS operation_type,
    COUNT(*) AS occurrence_count,
    SUM(qs.execution_count) AS total_executions,
    SUM(qs.total_logical_writes) AS total_writes
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
WHERE qt.text LIKE '%your_table_name%'
    AND OBJECT_NAME(qt.objectid) IS NOT NULL
GROUP BY 
    OBJECT_NAME(qt.objectid),
    CASE 
        WHEN CHARINDEX('UPDATE', UPPER(qt.text)) > 0 THEN 'Contains UPDATE statements'
        WHEN CHARINDEX('INSERT', UPPER(qt.text)) > 0 THEN 'Contains INSERT statements'
        WHEN CHARINDEX('DELETE', UPPER(qt.text)) > 0 THEN 'Contains DELETE statements'
        WHEN CHARINDEX('MERGE', UPPER(qt.text)) > 0 THEN 'Contains MERGE statements'
        ELSE 'Other operations'
    END
ORDER BY total_writes DESC;
