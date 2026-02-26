/*
============================================================================
SQL Server TempDB – Production Scripts
Category:   SQL Server Internal Architecture
Target Role: Database Engineer / Senior DBA
GitHub:     SQL-Server-DBA/01-TempDB/TempDB_Scripts.sql
============================================================================

SCRIPT INDEX:
  1. Check TempDB Space Distribution (Run FIRST during any TempDB issue)
  2. Identify Session-Level TempDB Usage
  3. Identify Version Store Hog (Long-running Snapshot Transactions)
  4. Identify PAGELATCH Contention (PFS / GAM / SGAM)
  5. Check TempDB Disk I/O Latency
  6. Find Queries Spilling to TempDB (Query Store – SQL 2016+)
  7. Baseline TempDB Peak Usage (Right-Sizing)
  8. Proactive TempDB Usage Alert (SQL Agent Job Script)
  9. TempDB File Configuration Check
 10. DBCC OPENTRAN – Find Oldest Open Transaction

============================================================================
*/


-- ============================================================================
-- SCRIPT 1: Check TempDB Space Distribution
-- PURPOSE:  High-level summary of what is filling TempDB.
--           Run this FIRST to identify which "bucket" is the problem.
-- BENCHMARK: If Version_Store_MB is high → long-running snapshot transaction
--            If Internal_Objects_MB is high → query spilling (sort/hash)
--            If User_Objects_MB is high → rogue #temp table
-- ============================================================================

SELECT
    SUM(user_object_reserved_page_count)     * 8 / 1024 AS User_Objects_MB,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS Internal_Objects_MB,
    SUM(version_store_reserved_page_count)   * 8 / 1024 AS Version_Store_MB,
    SUM(unallocated_extent_page_count)       * 8 / 1024 AS Free_Space_MB,
    SUM(total_page_count)                    * 8 / 1024 AS Total_Size_MB
FROM sys.dm_db_file_space_usage;


-- ============================================================================
-- SCRIPT 2: Identify Session-Level TempDB Usage
-- PURPOSE:  Find which specific SPID is consuming the most TempDB space.
--           Use this after Script 1 to pinpoint the rogue session.
-- ACTION:   KILL <session_id> if the session is causing a TempDB crisis.
-- ============================================================================

SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    (su.user_objects_alloc_page_count     * 8) / 1024 AS user_objects_alloc_MB,
    (su.internal_objects_alloc_page_count * 8) / 1024 AS internal_objects_alloc_MB,
    st.text AS active_sql_text
FROM sys.dm_db_session_space_usage AS su
INNER JOIN sys.dm_exec_sessions AS s 
    ON su.session_id = s.session_id
LEFT OUTER JOIN sys.dm_exec_connections AS c 
    ON s.session_id = c.session_id
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS st
WHERE (su.user_objects_alloc_page_count + su.internal_objects_alloc_page_count) > 0
ORDER BY (su.user_objects_alloc_page_count + su.internal_objects_alloc_page_count) DESC;


-- ============================================================================
-- SCRIPT 3: Identify Version Store Hog
-- PURPOSE:  Find long-running snapshot transactions that are preventing
--           version store cleanup and causing TempDB to grow.
-- WHEN:     Use when Script 1 shows Version_Store_MB is high.
-- ACTION:   KILL the session with the highest elapsed_time_seconds.
-- ============================================================================

SELECT 
    atst.session_id,
    atst.elapsed_time_seconds,
    atst.elapsed_time_seconds / 60  AS elapsed_minutes,
    atst.is_snapshot,
    des.login_name,
    des.host_name,
    des.status          AS session_status,
    dest.text           AS last_sql_text
FROM sys.dm_tran_active_snapshot_database_transactions AS atst
INNER JOIN sys.dm_exec_sessions AS des 
    ON atst.session_id = des.session_id
LEFT OUTER JOIN sys.dm_exec_connections AS dec 
    ON atst.session_id = dec.session_id
OUTER APPLY sys.dm_exec_sql_text(dec.most_recent_sql_handle) AS dest
ORDER BY atst.elapsed_time_seconds DESC;


-- ============================================================================
-- SCRIPT 4: Identify PAGELATCH Contention (PFS / GAM / SGAM)
-- PURPOSE:  Detect allocation contention on TempDB pages.
--           PAGELATCH_EX or PAGELATCH_UP waits on TempDB = file contention.
-- FIX:      Add more TempDB data files (follow CPU core count rule).
-- ============================================================================

SELECT 
    session_id, 
    wait_type, 
    wait_duration_ms, 
    resource_description,
    CASE 
        WHEN resource_description LIKE '2:%' THEN 'TempDB'
        ELSE 'Other DB'
    END AS Database_Target,
    CASE 
        WHEN resource_description LIKE '%:1:1'    OR 
             resource_description LIKE '%:1:8088' THEN 'PFS  (Page Free Space)'
        WHEN resource_description LIKE '%:1:2'    OR 
             resource_description LIKE '%:1:8089' THEN 'GAM  (Global Allocation Map)'
        WHEN resource_description LIKE '%:1:3'               THEN 'SGAM (Shared Global Allocation Map)'
        ELSE 'Data / Index Page'
    END AS Contention_Type
FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE 'PAGELATCH_%'
  AND resource_description LIKE '2:%'; -- DB_ID 2 = TempDB


-- ============================================================================
-- SCRIPT 5: Check TempDB Disk I/O Latency
-- PURPOSE:  Measure read and write latency for TempDB data and log files.
-- BENCHMARK: < 5ms = Excellent | 5–20ms = Acceptable | > 20ms = Problem
-- NOTE:     NULLIF prevents divide-by-zero if reads/writes = 0.
-- ============================================================================

SELECT 
    DB_NAME(database_id)                                            AS DB_Name,
    file_id,
    io_stall_read_ms  / NULLIF(num_of_reads,  0)                   AS Avg_Read_Latency_ms,
    io_stall_write_ms / NULLIF(num_of_writes, 0)                   AS Avg_Write_Latency_ms,
    num_of_bytes_read    / 1024 / 1024                             AS Total_Read_MB,
    num_of_bytes_written / 1024 / 1024                             AS Total_Written_MB
FROM sys.dm_io_virtual_file_stats(2, NULL); -- 2 = TempDB


-- ============================================================================
-- SCRIPT 6: Find Queries Spilling to TempDB via Query Store
-- PURPOSE:  Identify queries that are spilling sort or hash operations
--           to TempDB due to insufficient memory grants.
-- REQUIRES: Query Store enabled (SQL Server 2016+)
-- FIX:      Update statistics, add covering index, or rewrite the query.
-- ============================================================================

SELECT TOP 20
    qsq.query_id,
    qsp.plan_id,
    qsrs.count_executions,
    qsrs.avg_tempdb_space_used_kb / 1024  AS avg_tempdb_spill_MB,
    qsrs.max_tempdb_space_used_kb / 1024  AS max_tempdb_spill_MB,
    TRY_CAST(qsp.query_plan AS XML)        AS query_plan
FROM sys.query_store_runtime_stats  AS qsrs
JOIN sys.query_store_plan           AS qsp  ON qsrs.plan_id  = qsp.plan_id
JOIN sys.query_store_query          AS qsq  ON qsp.query_id  = qsq.query_id
WHERE qsrs.avg_tempdb_space_used_kb > 0
ORDER BY qsrs.avg_tempdb_space_used_kb DESC;


-- ============================================================================
-- SCRIPT 7: Baseline TempDB Peak Usage (For Right-Sizing Initial File Size)
-- PURPOSE:  Capture peak TempDB consumption to correctly set initial file size.
-- USAGE:    Run this during peak business hours for several days.
--           Set Initial Size per file = Peak Used MB / Number of Data Files + 20% buffer.
-- ============================================================================

SELECT 
    GETDATE()                                                              AS Capture_Time,
    SUM(total_page_count)                * 8 / 1024                       AS Total_Configured_MB,
    SUM(unallocated_extent_page_count)   * 8 / 1024                       AS Free_MB,
    (SUM(total_page_count) 
     - SUM(unallocated_extent_page_count)) * 8 / 1024                     AS Used_MB,
    CAST(100.0 * (SUM(total_page_count) - SUM(unallocated_extent_page_count)) 
         / SUM(total_page_count) AS DECIMAL(5,2))                         AS Used_Pct
FROM sys.dm_db_file_space_usage;


-- ============================================================================
-- SCRIPT 8: Proactive TempDB Usage Alert
-- PURPOSE:  Alert the DBA team when TempDB exceeds 80% full.
-- USAGE:    Schedule this as a SQL Agent Job running every 5 minutes.
-- REQUIRES: Database Mail configured with a profile named 'DBA Alerts'.
-- ============================================================================

DECLARE @UsedPct  FLOAT;
DECLARE @UsedMB   FLOAT;
DECLARE @TotalMB  FLOAT;
DECLARE @EmailBody NVARCHAR(1000);

SELECT 
    @UsedMB  = (SUM(total_page_count) - SUM(unallocated_extent_page_count)) * 8.0 / 1024,
    @TotalMB =  SUM(total_page_count) * 8.0 / 1024,
    @UsedPct =  100.0 * (SUM(total_page_count) - SUM(unallocated_extent_page_count)) 
                / NULLIF(SUM(total_page_count), 0)
FROM sys.dm_db_file_space_usage;

IF @UsedPct > 80
BEGIN
    SET @EmailBody = 
        'WARNING: TempDB on ' + @@SERVERNAME + ' is ' + 
        CAST(CAST(@UsedPct AS DECIMAL(5,1)) AS VARCHAR) + '% full.' + CHAR(13) +
        'Used: ' + CAST(CAST(@UsedMB AS INT) AS VARCHAR) + ' MB / ' +
        CAST(CAST(@TotalMB AS INT) AS VARCHAR) + ' MB total.' + CHAR(13) +
        'Please investigate immediately using TempDB_Scripts.sql.';

    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'DBA Alerts',
        @recipients   = 'dba-team@company.com',
        @subject      = 'ACTION REQUIRED: TempDB Usage Above 80% on ' + @@SERVERNAME,
        @body         = @EmailBody;
END


-- ============================================================================
-- SCRIPT 9: TempDB File Configuration Check
-- PURPOSE:  Verify TempDB data file count, sizes, and autogrowth settings.
--           All data files should have IDENTICAL size and autogrowth.
-- RED FLAGS: Different sizes across files (breaks proportional fill algorithm)
--            Percentage-based autogrowth (unpredictable growth)
--            Files not on a dedicated/fast drive
-- ============================================================================

SELECT 
    name                                        AS logical_file_name,
    physical_name,
    type_desc                                   AS file_type,
    size * 8 / 1024                            AS current_size_MB,
    CASE max_size 
        WHEN -1 THEN 'Unlimited' 
        ELSE CAST(max_size * 8 / 1024 AS VARCHAR) + ' MB'
    END                                         AS max_size,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS VARCHAR) + '% (⚠ Use fixed MB instead!)'
        ELSE CAST(growth * 8 / 1024 AS VARCHAR) + ' MB'
    END                                         AS autogrowth_setting,
    state_desc                                  AS file_state
FROM sys.master_files
WHERE database_id = DB_ID('TempDB')
ORDER BY type, file_id;


-- ============================================================================
-- SCRIPT 10: DBCC OPENTRAN – Find Oldest Open Transaction in TempDB
-- PURPOSE:  Identify old open transactions that may be blocking
--           version store cleanup in TempDB.
-- USAGE:    Switch to TempDB context before running.
-- ============================================================================

USE TempDB;
GO
DBCC OPENTRAN();
GO
USE master;
GO

/*
============================================================================
QUICK REFERENCE – Emergency TempDB Response Order
============================================================================

STEP 1 → Run Script 1  (Which bucket is full?)
STEP 2 → Run Script 2  (Which session is consuming space?)
STEP 3 → Run Script 3  (Is version store the issue? Find ghost transaction)
STEP 4 → Run Script 10 (Any old open transactions?)
STEP 5 → KILL <session_id>  (Surgical fix – do NOT restart the server)
STEP 6 → Run Script 4  (Is there ongoing PAGELATCH contention?)
STEP 7 → Run Script 5  (Check disk latency – is storage the bottleneck?)
STEP 8 → Post-mortem   (Root cause: missing index, stale stats, bad query?)

SHRINK (DBCC SHRINKFILE) = LAST RESORT ONLY
Causes heavy index fragmentation. Only use during maintenance window.

============================================================================
*/
