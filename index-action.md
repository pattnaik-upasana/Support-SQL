# Index Optimization Action Guide

## 1. 🟠 HIGH MAINTENANCE - More Updates than Reads

### Problem
Index has more `user_updates` than total reads, causing unnecessary overhead during INSERT/UPDATE/DELETE operations.

### Root Causes
- Index covers columns that change frequently but are rarely queried
- Over-indexing on volatile data
- Index was created for a query pattern that no longer exists

### Actions to Take

#### Immediate Analysis
```sql
-- Find which queries use this index
SELECT 
    qt.query_sql_text,
    qs.execution_count,
    qs.total_logical_reads,
    qs.last_execution_time
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
WHERE qt.query_sql_text LIKE '%your_table_name%'
ORDER BY qs.last_execution_time DESC;
```

#### Decision Matrix
- **If no critical queries found**: DROP the index
- **If used by important queries**: Consider redesigning the index with fewer columns
- **If used infrequently**: Evaluate if the performance benefit justifies the maintenance cost

#### Implementation
```sql
-- Option 1: Drop unused high-maintenance index
DROP INDEX IX_YourIndex_Name ON YourTable;

-- Option 2: Recreate with fewer columns (if still needed)
CREATE NONCLUSTERED INDEX IX_YourIndex_Optimized 
ON YourTable (KeyColumn1)  -- Remove frequently updated columns
INCLUDE (Column2);  -- Move updated columns to INCLUDE if needed for covering
```

---

## 2. 🟡 OPTIMIZE - High Scans, No Seeks

### Problem
Index is being scanned entirely instead of used for efficient seeks, indicating poor selectivity or query design issues.

### Root Causes
- Index key columns have low selectivity (few unique values)
- Queries use functions on indexed columns: `WHERE UPPER(column) = 'VALUE'`
- WHERE clauses don't match index key column order
- Missing statistics or outdated statistics

### Actions to Take

#### Investigate Query Patterns
```sql
-- Find queries causing scans
SELECT 
    qt.query_sql_text,
    qs.execution_count,
    qs.total_logical_reads/qs.execution_count as avg_reads,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE qt.query_sql_text LIKE '%your_table_name%'
AND qs.total_logical_reads > 1000;
```

#### Check Index Selectivity
```sql
-- Analyze column selectivity
SELECT 
    'Column Analysis' as analysis,
    COUNT(*) as total_rows,
    COUNT(DISTINCT your_indexed_column) as unique_values,
    CAST(COUNT(DISTINCT your_indexed_column) AS FLOAT) / COUNT(*) * 100 as selectivity_percent
FROM YourTable;
```

#### Solutions
```sql
-- Option 1: Add more selective leading column
DROP INDEX IX_Current_Index ON YourTable;
CREATE NONCLUSTERED INDEX IX_Optimized_Index 
ON YourTable (HighSelectivityColumn, LowSelectivityColumn);

-- Option 2: Create filtered index for common conditions
CREATE NONCLUSTERED INDEX IX_Filtered_Index 
ON YourTable (Column1, Column2)
WHERE Status = 'Active' AND Date >= '2024-01-01';

-- Option 3: Update statistics
UPDATE STATISTICS YourTable IX_YourIndex_Name WITH FULLSCAN;
```

---

## 3. 🟡 OPTIMIZE - Poor Scan/Seek Ratio

### Problem
Index has both seeks and scans, but scans significantly outnumber seeks (ratio > 10:1).

### Root Causes
- Queries sometimes use the index efficiently (seeks) but other queries cause full scans
- Index column order doesn't match all query patterns
- Some queries have non-SARGable predicates

### Actions to Take

#### Analyze Mixed Usage Patterns
```sql
-- Find both efficient and inefficient queries
WITH QueryAnalysis AS (
    SELECT 
        qt.query_sql_text,
        qs.execution_count,
        qs.total_logical_reads,
        CASE 
            WHEN qt.query_sql_text LIKE '%WHERE%=%' THEN 'Likely Seek'
            WHEN qt.query_sql_text LIKE '%WHERE%LIKE%' THEN 'Likely Scan'
            WHEN qt.query_sql_text LIKE '%ORDER BY%' THEN 'Possible Scan'
            ELSE 'Unknown'
        END as predicted_operation
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
    WHERE qt.query_sql_text LIKE '%YourTable%'
)
SELECT * FROM QueryAnalysis
ORDER BY total_logical_reads DESC;
```

#### Solutions
```sql
-- Option 1: Create separate indexes for different query patterns
-- For seek operations
CREATE NONCLUSTERED INDEX IX_Table_Seeks 
ON YourTable (PrimaryFilterColumn, SecondaryFilterColumn);

-- For scan operations (if they can't be avoided)
CREATE NONCLUSTERED INDEX IX_Table_Scans 
ON YourTable (SortColumn)
INCLUDE (SelectColumn1, SelectColumn2);

-- Option 2: Composite index covering both patterns
CREATE NONCLUSTERED INDEX IX_Table_Composite 
ON YourTable (SeekColumn, ScanColumn)
INCLUDE (OutputColumn1, OutputColumn2);
```

---

## 4. 🟠 COVERING INDEX - High Key Lookups

### Problem
High `user_lookups` indicates queries use the non-clustered index for seeks but then perform key lookups to get additional columns from the clustered index.

### Root Causes
- Non-clustered index doesn't include all columns needed by queries
- SELECT * queries requiring columns not in the index
- JOIN operations needing additional columns

### Actions to Take

#### Identify Missing Columns
```sql
-- Find queries with key lookups
SELECT 
    qt.query_sql_text,
    qs.execution_count,
    qs.total_logical_reads,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE qt.query_sql_text LIKE '%YourTable%'
AND CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE '%KeyLookup%';
```

#### Create Covering Index
```sql
-- Analyze what columns are being selected
-- Then create covering index

-- Before: Non-covering index
-- CREATE INDEX IX_Original ON YourTable (FilterColumn);

-- After: Covering index
DROP INDEX IX_Original ON YourTable;
CREATE NONCLUSTERED INDEX IX_Covering 
ON YourTable (FilterColumn)  -- Key columns for seeks
INCLUDE (SelectColumn1, SelectColumn2, SelectColumn3);  -- Covering columns

-- Alternative: Filtered covering index for specific scenarios
CREATE NONCLUSTERED INDEX IX_Covering_Filtered 
ON YourTable (FilterColumn)
INCLUDE (SelectColumn1, SelectColumn2)
WHERE CommonFilterCondition = 'FrequentValue';
```

#### Considerations for Covering Indexes
```sql
-- Monitor index size after adding INCLUDE columns
SELECT 
    i.name,
    s.page_count,
    s.page_count * 8.0 / 1024 as size_mb,
    s.record_count
FROM sys.indexes i
JOIN sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'DETAILED') s
    ON i.object_id = s.object_id AND i.index_id = s.index_id
WHERE i.name = 'IX_Covering';
```

---

## General Best Practices

### Before Making Changes
1. **Backup** affected tables or create scripts to recreate current indexes
2. **Test in non-production** environment first
3. **Monitor performance** before and after changes
4. **Document** the business justification for each change

### After Implementation
1. **Update statistics** on modified indexes
2. **Monitor query performance** for 1-2 weeks
3. **Re-run usage statistics** to verify improvements
4. **Adjust maintenance windows** if index maintenance overhead changes

### Monitoring Query
```sql
-- Re-run this after changes to measure improvement
SELECT 
    'After Optimization' as period,
    i.name,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    CASE 
        WHEN s.user_seeks = 0 THEN 0
        ELSE CAST(s.user_scans AS FLOAT) / s.user_seeks
    END as scan_to_seek_ratio
FROM sys.indexes i
JOIN sys.dm_db_index_usage_stats s 
    ON i.object_id = s.object_id AND i.index_id = s.index_id
WHERE i.name IN ('YourModifiedIndexNames')
ORDER BY scan_to_seek_ratio DESC;
```
