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
