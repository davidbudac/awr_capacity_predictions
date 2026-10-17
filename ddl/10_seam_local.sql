--
-- ddl/10_seam_local.sql -- CAPV_* portable seam over DBA_HIST_* (LOCAL mode).
-- =====================================================================
-- These eleven views (plus the CAPV_CONTRACT diagnostic at the bottom) are the
-- ONLY place the analytics touch Oracle's AWR dictionary. Everything
-- downstream (CAPD_/CAPF_/CAPA_/report) is written once against CAPV_* and
-- runs byte-identically in local, warehouse, or fixture mode. Swapping this
-- file for ddl/11_seam_warehouse.sql or ddl/12_seam_fixture.sql re-points the
-- same column contract at a different source.
--
-- LOCAL mode requires the Diagnostics Pack and DIRECT SELECT grants (not via
-- a role) on the DBA_HIST_* views for the installing schema, so the views
-- compile. That includes DBA_HIST_CON_SYS_TIME_MODEL and DBA_HIST_CON_SYSSTAT
-- as well as their SYS_ counterparts. Install where the DBA_HIST rows you
-- want are visible -- for a CDB that is CDB$ROOT (AWR lives at the CDB
-- level).
--
-- Column contract (identical in all three seam files):
--   * every view carries (dbid, con_dbid). DBA_HIST_SNAPSHOT has no CON_DBID
--     column, so CAPV_SNAPSHOT sets con_dbid := dbid. The tablespace/OS/time
--     views expose the real CON_DBID, which is REQUIRED to separate PDBs:
--     TABLESPACE_ID / TS# restart at 0 per container, so SYSTEM in the root
--     and SYSTEM in a PDB collide unless con_dbid disambiguates them.
--
-- Container facts (verified on 19c in CDB$ROOT, AWR_PDB_AUTOFLUSH_ENABLED =
-- FALSE, the default):
--   * Per container: DBA_HIST_TBSPC_SPACE_USAGE, DBA_HIST_CON_SYS_TIME_MODEL,
--     DBA_HIST_CON_SYSSTAT. CAPV_TBSPC_USAGE / CAPV_TIME_MODEL / CAPV_SYSSTAT
--     read these, minus PDB$SEED.
--   * Root only, CDB-wide: DBA_HIST_SYS_TIME_MODEL and DBA_HIST_SYSSTAT hold
--     one row per snapshot under the CDB's con_dbid, and that row is the
--     CDB total. They are used only as the non-CDB fallback below.
--   * Root only, by nature: DBA_HIST_OSSTAT (host level),
--     DBA_HIST_RESOURCE_LIMIT (instance level) and DBA_HIST_ASM_DISKGROUP_STAT
--     (host level). DBA_HIST_PARAMETER has root rows plus PDB rows for the
--     parameters set at PDB level; CAPV_PARAMETER keeps the root rows.
--   * In the CON_ views the root row covers CDB$ROOT alone. The CDB total is
--     the SUM over containers.
--
-- Unit facts (do not "fix" these -- downstream converts):
--   * DBA_HIST_TBSPC_SPACE_USAGE sizes are in DB BLOCKS (multiply by the
--     tablespace block size to get bytes). Passed through as-is here.
--   * TABLESPACE_MAXSIZE = 0 means the tablespace has NO autoextend (its
--     current size is its ceiling).
--   * DBA_HIST_OSSTAT *_TIME values are in CENTISECONDS and are cumulative
--     counters since instance startup.
--   * DBA_HIST_CON_SYS_TIME_MODEL values are in MICROSECONDS, cumulative
--     counters.
--   * RTIME on TBSPC_SPACE_USAGE is an NLS-fragile VARCHAR2 -- we deliberately
--     ignore it and derive timestamps by joining snap_id -> CAPV_SNAPSHOT.
--   * We never join live DBA_TABLESPACES: it drops history for dropped
--     tablespaces and does not exist in warehouse mode. DBA_HIST_TABLESPACE /
--     DBA_HIST_DATAFILE are the historical dimensions.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPV_SNAPSHOT -- snapshot spine (timestamps + startup_time for restart
-- detection). con_dbid := dbid (no CON_DBID in the source).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_snapshot AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       begin_interval_time      AS begin_interval_time,
       end_interval_time        AS end_interval_time,
       startup_time             AS startup_time
FROM   dba_hist_snapshot;

-- --------------------------------------------------------------------
-- CAPV_TBSPC_USAGE -- tablespace space usage, sizes in BLOCKS (as-is).
-- No instance_number in the source (usage is per-container, not per-inst).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_tbspc_usage AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       snap_id                  AS snap_id,
       tablespace_id            AS tablespace_id,
       tablespace_size          AS tablespace_size,      -- blocks
       tablespace_maxsize       AS tablespace_maxsize,   -- blocks; 0 = no autoextend
       tablespace_usedsize      AS tablespace_usedsize   -- blocks
FROM   dba_hist_tbspc_space_usage;

-- --------------------------------------------------------------------
-- CAPV_TABLESPACE -- tablespace dimension (name + contents + block size).
-- TS# is the join key to CAPV_TBSPC_USAGE.tablespace_id and
-- CAPV_DATAFILE.tablespace_id. block_size is the PRIMARY blocks->bytes factor:
-- DBA_HIST_TABLESPACE carries it for EVERY tablespace, whereas
-- DBA_HIST_DATAFILE can be missing rows (e.g. SYSTEM is absent on stock 19c),
-- which would otherwise drop that tablespace from the daily series entirely.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_tablespace AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       ts#                      AS tablespace_id,
       tsname                   AS tablespace_name,
       contents                 AS contents,            -- PERMANENT / UNDO / TEMPORARY
       block_size               AS block_size           -- bytes/block
FROM   dba_hist_tablespace;

-- --------------------------------------------------------------------
-- CAPV_DATAFILE -- block size per tablespace (MAX across its datafiles).
-- Secondary/fallback source of the blocks->bytes factor (CAPV_TABLESPACE is
-- primary). Kept because it survives dropped tablespaces and mirrors the
-- warehouse contract; the daily layer LEFT JOINs it and COALESCEs.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_datafile AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       ts#                      AS tablespace_id,
       MAX(block_size)          AS block_size           -- bytes/block
FROM   dba_hist_datafile
GROUP BY dbid, con_dbid, ts#;

-- --------------------------------------------------------------------
-- CAPV_OSSTAT -- host OS stats, filtered to the CPU/memory names the CPU
-- layer consumes. *_TIME values are cumulative counters in centiseconds.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_osstat AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       stat_name                AS stat_name,
       value                    AS value
FROM   dba_hist_osstat
WHERE  stat_name IN ('BUSY_TIME','IDLE_TIME','IOWAIT_TIME',
                     'NUM_CPUS','NUM_CPU_CORES','PHYSICAL_MEMORY_BYTES');

-- --------------------------------------------------------------------
-- CAPV_TIME_MODEL -- DB time model PER CONTAINER, filtered to the three
-- CPU/DB-time names. Values are cumulative counters in microseconds.
--   * Source DBA_HIST_CON_SYS_TIME_MODEL. DBA_HIST_SYS_TIME_MODEL is not
--     usable in a CDB: in CDB$ROOT it has one row per snapshot, under the
--     root's con_dbid, holding the CDB-wide total, so a PDB never got a
--     DB CPU series and the root's series was really the whole CDB.
--   * PDB$SEED is dropped by CON_ID <> 2 (CON_ID 2 is always the seed in a
--     CDB). It runs no workload and would only add a zero series.
--   * Fallback: a snapshot with no CON_ row at all (a non-CDB, or AWR data
--     imported from one) reads DBA_HIST_SYS_TIME_MODEL, where con_dbid is
--     the dbid.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_time_model AS
SELECT c.dbid                   AS dbid,
       c.con_dbid               AS con_dbid,
       c.instance_number        AS instance_number,
       c.snap_id                AS snap_id,
       c.stat_name              AS stat_name,
       c.value                  AS value
FROM   dba_hist_con_sys_time_model c
WHERE  c.stat_name IN ('DB CPU','DB time','background cpu time')
  AND  NVL(c.con_id, 0) <> 2
UNION ALL
SELECT s.dbid, s.con_dbid, s.instance_number, s.snap_id, s.stat_name, s.value
FROM   dba_hist_sys_time_model s
WHERE  s.stat_name IN ('DB CPU','DB time','background cpu time')
  AND  NOT EXISTS (SELECT 1
                   FROM   dba_hist_con_sys_time_model c
                   WHERE  c.dbid = s.dbid AND c.snap_id = s.snap_id
                     AND  c.instance_number = s.instance_number);

-- --------------------------------------------------------------------
-- CAPV_CONTAINER -- container/database naming dimension: one row per
-- (dbid, con_dbid) AWR has seen, with the human names the report prints
-- instead of raw con_dbid values.
--   * DBA_HIST_PDB_INSTANCE (19c, CDB only) names every container incl.
--     CDB$ROOT (whose con_dbid equals the CDB dbid; verified on 19c).
--   * On a NON-CDB that view has no rows, so a fallback branch emits the
--     (dbid, dbid) key with con_name NULL; db_name always comes from
--     DBA_HIST_DATABASE_INSTANCE.
-- The UNION dedupes the key set; MAX() collapses per-instance/per-startup
-- duplicate dimension rows to one name per container.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_container AS
SELECT k.dbid,
       k.con_dbid,
       d.db_name,
       p.con_name
FROM  (
        SELECT dbid, con_dbid FROM dba_hist_pdb_instance
        UNION
        SELECT dbid, dbid FROM dba_hist_database_instance
      ) k
LEFT  JOIN (SELECT dbid, MAX(db_name) AS db_name
            FROM   dba_hist_database_instance
            GROUP  BY dbid) d
  ON  d.dbid = k.dbid
LEFT  JOIN (SELECT dbid, con_dbid, MAX(pdb_name) AS con_name
            FROM   dba_hist_pdb_instance
            GROUP  BY dbid, con_dbid) p
  ON  p.dbid = k.dbid AND p.con_dbid = k.con_dbid;

-- --------------------------------------------------------------------
-- CAPV_RESOURCE_LIMIT (M11.1) -- per-instance resource high-water marks vs
-- their configured ceilings, filtered to the two that actually cause outages:
-- `processes` and `sessions`.
--   * CURRENT_UTILIZATION = in use at snapshot time.
--   * MAX_UTILIZATION     = HIGH-WATER MARK since instance startup (so it is
--                           monotone within a startup epoch and resets on
--                           restart -- CAPD_SERIES_DAILY documents that).
--   * LIMIT_VALUE is a VARCHAR2(10) in the source and can read 'UNLIMITED',
--     so it is converted here: numeric strings become NUMBER, anything else
--     becomes NULL (= "no ceiling"), which the daily/forecast layers treat as
--     "no days-to-limit".
--   * DBA_HIST_RESOURCE_LIMIT has a CON_DBID column, but in CDB$ROOT its rows
--     are root-only (verified on 19c): the limits are instance-wide, so
--     PROCESSES / SESSIONS are CDB-wide series under the root's con_dbid.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_resource_limit AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       resource_name            AS resource_name,
       current_utilization      AS current_utilization,
       max_utilization          AS max_utilization,
       CASE WHEN REGEXP_LIKE(TRIM(limit_value), '^[0-9]+$')
            THEN TO_NUMBER(TRIM(limit_value))
       END                      AS limit_value
FROM   dba_hist_resource_limit
WHERE  resource_name IN ('processes','sessions');

-- --------------------------------------------------------------------
-- CAPV_SYSSTAT (M11.2) -- system statistics PER CONTAINER, filtered to the
-- one counter the redo series needs. 'redo size' is a CUMULATIVE BYTE counter
-- since instance startup (like the OSSTAT/time-model counters), so the daily
-- layer differences consecutive snaps and drops restart-spanning intervals.
--   * Source DBA_HIST_CON_SYSSTAT, for the same reason as CAPV_TIME_MODEL:
--     DBA_HIST_SYSSTAT in CDB$ROOT carries the root's con_dbid only. The log
--     stream is shared, so the CDB's redo is the SUM over containers.
--   * Same PDB$SEED filter and non-CDB fallback as CAPV_TIME_MODEL.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_sysstat AS
SELECT c.dbid                   AS dbid,
       c.con_dbid               AS con_dbid,
       c.instance_number        AS instance_number,
       c.snap_id                AS snap_id,
       c.stat_name              AS stat_name,
       c.value                  AS value
FROM   dba_hist_con_sysstat c
WHERE  c.stat_name = 'redo size'
  AND  NVL(c.con_id, 0) <> 2
UNION ALL
SELECT s.dbid, s.con_dbid, s.instance_number, s.snap_id, s.stat_name, s.value
FROM   dba_hist_sysstat s
WHERE  s.stat_name = 'redo size'
  AND  NOT EXISTS (SELECT 1
                   FROM   dba_hist_con_sysstat c
                   WHERE  c.dbid = s.dbid AND c.snap_id = s.snap_id
                     AND  c.instance_number = s.instance_number);

-- --------------------------------------------------------------------
-- CAPV_PARAMETER -- the init parameters the suite reads as ceilings, one
-- row per (snapshot, instance, parameter), the value as a NUMBER.
--   * DBA_HIST_PARAMETER.VALUE is a VARCHAR2(512). A numeric string becomes
--     a NUMBER (the CAPV_RESOURCE_LIMIT guard), anything else NULL. Size
--     parameters are stored in bytes.
--   * Instance level, so con_dbid := dbid. In CDB$ROOT the source also
--     holds rows under a PDB's con_dbid for parameters set at PDB level
--     (verified on 19c: one snapshot carried sga_target for the root, the
--     seed and PDB1). Only the root row (con_dbid = dbid, or a non-CDB) is
--     kept, so a parameter has one value per snapshot and instance.
--   * Filtered to the parameters a downstream view reads or may read:
--     cpu_count (the CPU ceiling in CAPD_DBTIME_DAILY) and
--     db_recovery_file_dest_size (FRA days in CAPF_SERIES_FORECAST), plus
--     the process, session and memory ceilings.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_parameter AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       LOWER(parameter_name)    AS parameter_name,
       CASE WHEN REGEXP_LIKE(TRIM(value), '^[0-9]+$')
            THEN TO_NUMBER(TRIM(value))
       END                      AS value_num
FROM   dba_hist_parameter
WHERE  parameter_name IN ('cpu_count','processes','sessions',
                          'db_recovery_file_dest_size',
                          'sga_target','sga_max_size',
                          'pga_aggregate_target','pga_aggregate_limit',
                          'memory_target')
  AND  NVL(con_dbid, dbid) = dbid;

-- --------------------------------------------------------------------
-- CAPV_ASM_DISKGROUP -- ASM diskgroup size per snapshot, named.
--   * DBA_HIST_ASM_DISKGROUP_STAT carries TOTAL_MB / FREE_MB per snapshot
--     and group number. DBA_HIST_ASM_DISKGROUP is the name dimension, joined
--     on (dbid, group_number, con_dbid). NAME has no leading '+'.
--   * TOTAL_MB / FREE_MB are raw MB, before mirroring. The 19c view has no
--     USABLE_FILE_MB (verified on 19.27), so usable_file_mb is NULL here.
--   * Host level: no instance_number, con_dbid := dbid. A database without
--     ASM has no rows, and the ASM_DG series simply do not appear.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_asm_diskgroup AS
SELECT s.dbid                   AS dbid,
       s.dbid                   AS con_dbid,
       s.snap_id                AS snap_id,
       g.name                   AS group_name,
       s.total_mb               AS total_mb,
       s.free_mb                AS free_mb,
       CAST(NULL AS NUMBER)     AS usable_file_mb
FROM   dba_hist_asm_diskgroup_stat s
JOIN   dba_hist_asm_diskgroup g
  ON   g.dbid = s.dbid AND g.group_number = s.group_number
 AND   g.con_dbid = s.con_dbid;

-- --------------------------------------------------------------------
-- CAPV_CONTRACT -- what this seam actually presents, one row per fact
-- source: row count, distinct con_dbid, snap_id range and the newest
-- snapshot end time. per_container_expected = 'Y' where the contract wants
-- one series per container (TBSPC_USAGE, TIME_MODEL, SYSSTAT) and 'N' where
-- the source is host / instance / spine level (OSSTAT, RESOURCE_LIMIT,
-- PARAMETER, ASM_DISKGROUP, SNAPSHOT), so n_con_dbid = 1 against a 'Y' means
-- the per-PDB series are missing. ASM_DISKGROUP has n_rows = 0 on a database
-- without ASM. A diagnostic for doctor.sql: it full-scans every source, and no
-- analytic view selects from it. The body reads only CAPV_* and is the same
-- in all three seam files.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_contract AS
WITH src AS (
        SELECT 'SNAPSHOT' AS source_name, dbid, con_dbid, snap_id FROM capv_snapshot
        UNION ALL SELECT 'TBSPC_USAGE',    dbid, con_dbid, snap_id FROM capv_tbspc_usage
        UNION ALL SELECT 'OSSTAT',         dbid, con_dbid, snap_id FROM capv_osstat
        UNION ALL SELECT 'TIME_MODEL',     dbid, con_dbid, snap_id FROM capv_time_model
        UNION ALL SELECT 'SYSSTAT',        dbid, con_dbid, snap_id FROM capv_sysstat
        UNION ALL SELECT 'RESOURCE_LIMIT', dbid, con_dbid, snap_id FROM capv_resource_limit
        UNION ALL SELECT 'PARAMETER',      dbid, con_dbid, snap_id FROM capv_parameter
        UNION ALL SELECT 'ASM_DISKGROUP',  dbid, con_dbid, snap_id FROM capv_asm_diskgroup
     ),
     per_con AS (
        SELECT source_name, dbid, con_dbid,
               COUNT(*)     AS n_rows,
               MIN(snap_id) AS min_snap_id,
               MAX(snap_id) AS max_snap_id
        FROM   src
        GROUP  BY source_name, dbid, con_dbid
     ),
     snap_end AS (
        SELECT dbid, snap_id, MAX(end_interval_time) AS end_time
        FROM   capv_snapshot
        GROUP  BY dbid, snap_id
     ),
     -- The source list is fixed so that an empty source still gets its row.
     sources AS (
        SELECT 'SNAPSHOT' AS source_name, 'N' AS per_container_expected FROM dual
        UNION ALL SELECT 'TBSPC_USAGE',    'Y' FROM dual
        UNION ALL SELECT 'OSSTAT',         'N' FROM dual
        UNION ALL SELECT 'TIME_MODEL',     'Y' FROM dual
        UNION ALL SELECT 'SYSSTAT',        'Y' FROM dual
        UNION ALL SELECT 'RESOURCE_LIMIT', 'N' FROM dual
        UNION ALL SELECT 'PARAMETER',      'N' FROM dual
        UNION ALL SELECT 'ASM_DISKGROUP',  'N' FROM dual
     )
SELECT k.source_name,
       NVL(SUM(p.n_rows), 0)        AS n_rows,
       COUNT(DISTINCT p.con_dbid)   AS n_con_dbid,
       MIN(p.min_snap_id)           AS min_snap_id,
       MAX(p.max_snap_id)           AS max_snap_id,
       MAX(e.end_time)              AS max_end_time,
       k.per_container_expected
FROM   sources k
LEFT   JOIN per_con p
  ON   p.source_name = k.source_name
LEFT   JOIN snap_end e
  ON   e.dbid = p.dbid AND e.snap_id = p.max_snap_id
GROUP  BY k.source_name, k.per_container_expected;
