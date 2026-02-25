# SQL Server TempDB – Complete Theory Guide

**Category:** SQL Server Internal Architecture  
**Target Role:** Database Engineer / Senior DBA (Product-Based Company)  
**Experience Level:** 7+ Years  
**Last Updated:** 2026

---

## Table of Contents

1. [What is TempDB?](#1-what-is-tempdb)
2. [Core Architecture & Components](#2-core-architecture--components)
3. [How TempDB Works Internally](#3-how-tempdb-works-internally)
4. [Configuration Best Practices](#4-configuration-best-practices)
5. [Cloud Strategy – AWS Instance Store](#5-cloud-strategy--aws-instance-store)
6. [TempDB Contention – PAGELATCH Explained](#6-tempdb-contention--pagelatch-explained)
7. [TempDB Full – Troubleshooting Strategy](#7-tempdb-full--troubleshooting-strategy)
8. [Spills – Sort & Hash Join Explained](#8-spills--sort--hash-join-explained)
9. [Version Store Deep Dive](#9-version-store-deep-dive)
10. [Proactive Monitoring Strategy](#10-proactive-monitoring-strategy)
11. [Common Interview Questions](#11-common-interview-questions)

---

## 1. What is TempDB?

TempDB is a **system database** in SQL Server that acts as a **global scratch pad** shared by ALL users and ALL databases on the same SQL Server instance.

### Key Characteristics

| Property | Detail |
|----------|--------|
| Scope | Instance-wide (shared by all databases and users) |
| Persistence | **Non-persistent** – recreated fresh on every SQL Server restart |
| Backup | **Cannot be backed up** – no recovery model needed |
| Recovery Model | Always SIMPLE – no log backups |
| Count | Only ONE TempDB per SQL Server instance |

### Why It Matters

TempDB is one of the **most frequently accessed** databases in any SQL Server instance. Almost every query that performs sorting, joining, or uses temporary storage will touch TempDB. A poorly configured or overwhelmed TempDB can **bottleneck the entire server**.

---

## 2. Core Architecture & Components

TempDB stores three categories of objects:

### 2.1 User Objects

Objects explicitly created by users or applications:

- **Local Temp Tables** (`#TempTable`) – visible only to the creating session
- **Global Temp Tables** (`##GlobalTemp`) – visible to all sessions
- **Table Variables** (`DECLARE @tv TABLE (...)`) – stored in TempDB, not in memory
- **Temp Indexes** – indexes created on temp tables
- **Temp Stored Procedures** – temporary procedures

> **Interview Tip:** Many developers believe table variables are purely in-memory. They are **not** – they still live in TempDB, but they get fewer statistics and no parallel execution plans.

---

### 2.2 Internal Objects

Objects created automatically by the SQL Server engine to process queries:

| Internal Object | Trigger |
|----------------|---------|
| **Work Tables** | Cursors, DISTINCT, GROUP BY, UNION, EXCEPT |
| **Sort Spills** | ORDER BY, GROUP BY when memory grant is insufficient |
| **Hash Spills** | Hash Join, Hash Aggregation when memory grant is insufficient |
| **LOB Storage** | Temporary storage for large object types (VARCHAR(MAX), XML, etc.) |
| **Index Build Temp** | Online index rebuild intermediate results |

> **Key Point:** Internal objects are completely invisible to the user. You cannot directly drop them – they disappear when the query finishes.

---

### 2.3 Version Store

The Version Store holds **old row versions** needed for multi-version concurrency control (MVCC). It is populated when these features are active:

| Feature | Why Version Store is Used |
|---------|--------------------------|
| **Read Committed Snapshot Isolation (RCSI)** | Readers get a snapshot of committed data instead of being blocked by writers |
| **Snapshot Isolation (SI)** | Full transaction-level consistent snapshot |
| **Online Index Rebuild** | Old row versions kept for concurrent readers during the build |
| **Multiple Active Result Sets (MARS)** | Maintains row versions across batches |
| **After Triggers** | Stores the "deleted" pseudo-table version |

> **Critical Production Fact:** If RCSI is enabled on a busy database and a long-running transaction holds open a snapshot, the Version Store **cannot be cleaned up** and will keep growing until TempDB fills up.

---

## 3. How TempDB Works Internally

### 3.1 The Restart Behaviour

Every time SQL Server restarts:
1. TempDB is **dropped and recreated from scratch**
2. It starts at the **configured initial size** (not the size it was at shutdown)
3. All data, temp tables, and version store are **permanently lost**
4. This is by design – TempDB is meant to be ephemeral

> **Production Implication:** If TempDB autogrows during business hours every day after a nightly restart, your **initial size is too small**. Fix it by right-sizing the initial file size to match peak usage.

### 3.2 The Proportional Fill Algorithm

SQL Server uses the **Proportional Fill Algorithm** to write data across multiple TempDB data files:

- SQL Server writes to files in proportion to their **free space**
- A larger file receives more writes than a smaller one
- **This is why ALL TempDB data files MUST be the same size**
- If files are different sizes, the algorithm creates uneven I/O and negates the benefit of multiple files

### 3.3 Allocation Pages – PFS, GAM, SGAM

SQL Server manages free space using special allocation pages:

| Page Type | Full Name | Purpose |
|-----------|-----------|---------|
| **PFS** | Page Free Space | Tracks how full each data page is |
| **GAM** | Global Allocation Map | Tracks which extents are allocated |
| **SGAM** | Shared Global Allocation Map | Tracks which shared extents are in use |

In a **single TempDB data file**, all concurrent sessions compete to update the same PFS/GAM/SGAM pages → **PAGELATCH contention**. Multiple data files distribute this contention across separate sets of allocation pages.

---

## 4. Configuration Best Practices

### 4.1 Number of Data Files

| Logical CPU Cores | Recommended TempDB Data Files |
|-------------------|-------------------------------|
| ≤ 8 cores | Number of files = Number of cores |
| > 8 cores | Start with **8 files** |
| Contention still present | Increase by increments of **4** |

**Why this works:** More data files = more sets of PFS/GAM/SGAM pages = less latch contention.

### 4.2 File Sizing Rules (Critical)

```
✅ ALL data files must have:
   - IDENTICAL initial size
   - IDENTICAL autogrowth settings
   - FIXED MB autogrowth (NOT percentage %)

❌ NEVER use:
   - Different sizes across data files
   - Percentage-based autogrowth (unpredictable growth amounts)
```

**Why fixed MB?** Percentage growth on a large file causes massive unpredictable growth events. Fixed MB growth is controlled and predictable.

### 4.3 Storage Placement

```
Priority 1: NVMe SSD (fastest)
Priority 2: SSD
Priority 3: Dedicated HDD spindle (isolated from user data)

Rules:
✅ Dedicated drive/mount point for TempDB
✅ Separate from user database files
✅ Separate from OS and system files
❌ Never share a drive with user databases
❌ Never place on a slow, shared SAN volume
```

**Benchmark Targets:**

| Metric | Excellent | Acceptable | Problem |
|--------|-----------|------------|---------|
| Read Latency | < 1ms | < 5ms | > 20ms |
| Write Latency | < 1ms | < 5ms | > 20ms |

### 4.4 TempDB Log File

- Only **one log file** is needed for TempDB (multiple log files provide no benefit)
- The log file should also have a **fixed MB autogrowth**
- Pre-size the log file appropriately to avoid frequent autogrowth

---

## 5. Cloud Strategy – AWS Instance Store

When running SQL Server on AWS EC2 instances, use the **Instance Store (Ephemeral NVMe)** for TempDB.

### Why Instance Store for TempDB?

| Factor | EBS (gp3/io2) | Instance Store (NVMe) |
|--------|--------------|----------------------|
| Latency | 1–2ms | Sub-millisecond |
| Cost | Additional monthly charge | Included in instance price |
| Persistence | Survives stop/start | **Lost on stop/termination** |
| Risk for TempDB | N/A | **Zero risk** – TempDB recreates anyway |

### Best EC2 Instance Families for This Pattern

- `m5d`, `m6id` – General purpose with NVMe
- `r5d`, `r6id` – Memory-optimised with NVMe (ideal for SQL Server)
- `i3en` – Storage-optimised

### Setup Pattern

```bash
# On instance startup, format and mount the instance store NVMe
# Then configure SQL Server TempDB to use that mount point
# Use a startup script (User Data) to handle re-mounting after restarts
```

> **Interview Point:** This is a cost-optimisation AND performance win. You reduce the need for expensive Provisioned IOPS EBS volumes while getting better latency.

---

## 6. TempDB Contention – PAGELATCH Explained

### What is PAGELATCH Contention?

When many concurrent sessions all try to allocate space in TempDB simultaneously, they compete to update the same PFS/GAM/SGAM allocation pages. This causes sessions to **wait** – showing up as `PAGELATCH_EX` or `PAGELATCH_UP` wait types.

### How to Identify It

```sql
-- Identify active PAGELATCH waits on TempDB
SELECT 
    session_id, 
    wait_type, 
    wait_duration_ms, 
    resource_description,
    CASE 
        WHEN resource_description LIKE '%:1:1' OR resource_description LIKE '%:1:8088' 
            THEN 'PFS (Page Free Space)'
        WHEN resource_description LIKE '%:1:2' OR resource_description LIKE '%:1:8089' 
            THEN 'GAM (Global Allocation Map)'
        WHEN resource_description LIKE '%:1:3' 
            THEN 'SGAM (Shared Global Allocation Map)'
        ELSE 'Data/Index Page'
    END AS Contention_Type
FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE 'PAGELATCH_%'
  AND resource_description LIKE '2:%'; -- TempDB is always DB ID 2
```

### The Fix

1. Add more TempDB data files (follow the core count rule above)
2. Enable Trace Flag **1118** (SQL 2014 and earlier) – forces uniform extents
3. In SQL 2016+, Trace Flag 1118 behaviour is **automatic** (no action needed)

---

## 7. TempDB Full – Troubleshooting Strategy

### The 5-Step Emergency Response

When TempDB hits 99% capacity in production, follow this sequence:

#### Step 1 – Check Which Bucket is Full

```sql
-- Run this FIRST to identify the problem category
SELECT
    SUM(user_object_reserved_page_count)    * 8 / 1024 AS User_Objects_MB,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS Internal_Objects_MB,
    SUM(version_store_reserved_page_count)   * 8 / 1024 AS Version_Store_MB,
    SUM(unallocated_extent_page_count)       * 8 / 1024 AS Free_Space_MB,
    SUM(total_page_count)                    * 8 / 1024 AS Total_Size_MB
FROM sys.dm_db_file_space_usage;
```

**Interpret the results:**

| High Bucket | Most Likely Cause |
|-------------|-------------------|
| User Objects | Rogue query creating massive #temp table |
| Internal Objects | Query spilling to TempDB (sort/hash) |
| Version Store | Long-running transaction or ghost transaction under RCSI |

#### Step 2 – Find the Rogue Session

```sql
-- Find which SPID is eating TempDB space
SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    (su.user_objects_alloc_page_count    * 8) / 1024 AS user_objects_alloc_MB,
    (su.internal_objects_alloc_page_count * 8) / 1024 AS internal_objects_alloc_MB,
    st.text AS active_sql_text
FROM sys.dm_db_session_space_usage AS su
INNER JOIN sys.dm_exec_sessions AS s ON su.session_id = s.session_id
LEFT OUTER JOIN sys.dm_exec_connections AS c ON s.session_id = c.session_id
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS st
WHERE (su.user_objects_alloc_page_count + su.internal_objects_alloc_page_count) > 0
ORDER BY (su.user_objects_alloc_page_count + su.internal_objects_alloc_page_count) DESC;
```

#### Step 3 – If Version Store is Full, Find the Ghost Transaction

```sql
-- Find long-running snapshot transactions blocking version store cleanup
SELECT 
    atst.session_id,
    atst.elapsed_time_seconds,
    atst.is_snapshot,
    des.login_name,
    des.host_name,
    des.status AS session_status,
    dest.text AS last_sql_text
FROM sys.dm_tran_active_snapshot_database_transactions AS atst
INNER JOIN sys.dm_exec_sessions AS des ON atst.session_id = des.session_id
LEFT OUTER JOIN sys.dm_exec_connections AS dec ON atst.session_id = dec.session_id
OUTER APPLY sys.dm_exec_sql_text(dec.most_recent_sql_handle) AS dest
ORDER BY atst.elapsed_time_seconds DESC;

-- Also check for open transactions
DBCC OPENTRAN(); -- Finds oldest active transaction that may be blocking cleanup
```

#### Step 4 – Immediate Relief Options

```sql
-- Option A: Kill the specific SPID (preferred – surgical, saves rest of workload)
KILL <session_id>;

-- Option B: Temporary space expansion (buy time while investigating)
-- Add a new TempDB file or expand existing one via SSMS or ALTER DATABASE

-- Option C: Shrink (LAST RESORT ONLY – causes heavy fragmentation)
USE TempDB;
DBCC SHRINKFILE (tempdev, <target_size_MB>); -- tempdev = logical file name
```

> **Golden Rule:** Always `KILL` the specific session rather than restarting the entire SQL Server instance. A server restart impacts ALL users. A targeted KILL impacts only the rogue session.

#### Step 5 – Post-Mortem (Root Cause Analysis)

After the crisis is resolved, investigate **why** it happened:

| Root Cause | Investigation |
|-----------|---------------|
| Missing WHERE clause | Dev pulling millions of rows into a #temp table |
| Bad cardinality estimate | Stats were stale → SQL allocated insufficient memory → spill |
| Long-running report | PowerBI / SSRS report running during peak hours |
| Forgotten transaction | Application opened a transaction and never committed |

---

## 8. Spills – Sort & Hash Join Explained

### What is a Spill?

SQL Server tries to perform sorting and hashing **in memory**. When the **memory grant is insufficient** for the operation, SQL Server "spills" the intermediate data to TempDB. This is called a **spill**.

### Types of Spills

| Spill Type | Operator | TempDB Bucket |
|-----------|----------|---------------|
| Sort Spill | ORDER BY, GROUP BY | Internal Objects |
| Hash Spill | Hash Join, Hash Aggregation | Internal Objects |

### Why Spills Happen

1. **Stale Statistics** – SQL estimated 1,000 rows, actual was 1,000,000 → too small a memory grant
2. **Parameter Sniffing** – Plan cached for a small parameter value is reused for a large one
3. **No Index** – Full table scan forces a larger sort/hash operation
4. **Insufficient Server Memory** – SQL Server can't allocate enough memory for the operation

### How to Detect Spills

In SQL Server 2016+, spill warnings appear in **Execution Plans** as warnings on Sort or Hash operators.

```sql
-- Find queries that have spilled using Query Store (SQL 2016+)
SELECT TOP 20
    qsq.query_id,
    qsq.query_hash,
    qsp.plan_id,
    qsrs.count_executions,
    qsrs.avg_tempdb_space_used_kb / 1024 AS avg_tempdb_spill_MB,
    qsrs.max_tempdb_space_used_kb / 1024 AS max_tempdb_spill_MB,
    TRY_CAST(qsp.query_plan AS XML) AS query_plan
FROM sys.query_store_runtime_stats qsrs
JOIN sys.query_store_plan qsp ON qsrs.plan_id = qsp.plan_id
JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
WHERE qsrs.avg_tempdb_space_used_kb > 0
ORDER BY qsrs.avg_tempdb_space_used_kb DESC;
```

### Fixing Spills

| Fix | When to Apply |
|-----|--------------|
| Update Statistics | When stats are stale |
| Add a covering index | Eliminate the sort by providing pre-sorted data |
| Rewrite the query | Reduce the dataset earlier using better WHERE/JOIN filters |
| Increase memory grant hint | `OPTION (MIN_GRANT_PERCENT = 25)` – use cautiously |
| Fix parameter sniffing | Use `OPTION (OPTIMIZE FOR UNKNOWN)` or plan guides |

---

## 9. Version Store Deep Dive

### How Version Store Works

When RCSI or Snapshot Isolation is active:
1. Every time a row is **modified**, SQL Server writes the **old version** of the row to TempDB
2. Readers get the old version instead of being blocked by the writer
3. Each old version has a **transaction sequence number (XSN)**
4. Once no active transaction needs a version, it is **cleaned up** by a background thread

### Version Store Cleanup Process

SQL Server's **ghost cleanup task** runs regularly to remove old row versions. However, cleanup is **blocked** if any transaction holds an old snapshot open.

**The dangerous pattern:**
```
1. RCSI enabled on database
2. Long-running report starts a read transaction (takes snapshot at XSN 1000)
3. OLTP workload runs 50,000 updates (generates 50,000 row versions in TempDB)
4. Cleanup cannot remove versions newer than XSN 1000
5. Version store keeps growing → TempDB fills up
```

### Monitoring Version Store Age

```sql
-- Check version store size and oldest active version
SELECT 
    SUM(version_store_reserved_page_count) * 8 / 1024 AS Version_Store_MB,
    MIN(atst.elapsed_time_seconds) / 60 AS Oldest_Snapshot_Minutes
FROM sys.dm_db_file_space_usage
CROSS JOIN sys.dm_tran_active_snapshot_database_transactions atst;
```

---

## 10. Proactive Monitoring Strategy

### Setting Up a TempDB Alert (SQL Agent Job)

Create a SQL Agent job that runs every 5 minutes and alerts when TempDB exceeds 80% full:

```sql
-- Check TempDB usage percentage
DECLARE @UsedPct FLOAT;

SELECT @UsedPct = 
    100.0 * (1 - (SUM(CAST(unallocated_extent_page_count AS FLOAT)) 
                  / SUM(CAST(total_page_count AS FLOAT))))
FROM sys.dm_db_file_space_usage;

IF @UsedPct > 80
BEGIN
    -- Send alert via Database Mail
    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'DBA Alerts',
        @recipients   = 'dba-team@company.com',
        @subject      = 'WARNING: TempDB Usage Above 80%',
        @body         = 'TempDB is critically full. Investigate immediately.';
END
```

### Disk I/O Latency Check

```sql
-- Measure TempDB disk latency (run during peak hours to baseline)
SELECT 
    DB_NAME(database_id) AS DB_Name,
    file_id,
    CASE WHEN num_of_reads = 0 THEN 0 
         ELSE io_stall_read_ms / NULLIF(num_of_reads, 0) END  AS Avg_Read_Latency_ms,
    CASE WHEN num_of_writes = 0 THEN 0 
         ELSE io_stall_write_ms / NULLIF(num_of_writes, 0) END AS Avg_Write_Latency_ms,
    num_of_bytes_read    / 1024 / 1024 AS Total_Read_MB,
    num_of_bytes_written / 1024 / 1024 AS Total_Written_MB
FROM sys.dm_io_virtual_file_stats(2, NULL); -- 2 = TempDB DB_ID
```

> **Note:** `NULLIF` is used to prevent divide-by-zero errors if reads or writes are 0.

### Baseline Sizing (Right-Size Initial File Size)

Run this query during peak hours for one week to capture the maximum TempDB usage:

```sql
-- Capture peak TempDB usage for right-sizing
SELECT 
    GETDATE() AS capture_time,
    SUM(total_page_count)       * 8 / 1024 AS Total_Configured_MB,
    SUM(unallocated_extent_page_count) * 8 / 1024 AS Free_MB,
    (SUM(total_page_count) - SUM(unallocated_extent_page_count)) * 8 / 1024 AS Used_MB
FROM sys.dm_db_file_space_usage;
```

Set the **initial size per file** = `Peak Used MB / Number of TempDB Data Files` + 20% buffer.

---

## 11. Common Interview Questions

**Q: Why can't you back up TempDB?**  
A: TempDB is ephemeral by design – it's recreated on every restart. There's nothing to recover to, so SQL Server doesn't allow backups.

**Q: Why do we need multiple TempDB data files?**  
A: To reduce PAGELATCH contention on PFS/GAM/SGAM allocation pages. Multiple files create multiple sets of these pages, spreading concurrent allocation requests across them.

**Q: Table variable vs Temp Table – which is in TempDB?**  
A: Both are stored in TempDB. Table variables don't support statistics, can't be used with parallel plans, and have different transaction scope behaviour. Temp tables are better for large datasets.

**Q: What happens to the Version Store when you restart SQL Server?**  
A: It is completely wiped. TempDB is recreated fresh on every restart, so all version store data is lost.

**Q: How would you fix a TempDB that fills up every day?**  
A: Identify the cause using `sys.dm_db_file_space_usage`, target the rogue session using `sys.dm_db_session_space_usage`, kill the SPID if necessary, then perform a post-mortem to address the root cause (missing index, stale stats, long-running report, etc.).

**Q: What is trace flag 1118 and is it still relevant?**  
A: TF 1118 forces SQL Server to use uniform extents instead of mixed extents, reducing GAM/SGAM contention. From SQL Server 2016 onwards, this behaviour is **automatic** and the trace flag is no longer needed.

---

*Document maintained by: Madhumohan  
