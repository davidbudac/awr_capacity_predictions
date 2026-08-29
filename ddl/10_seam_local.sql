--
-- ddl/10_seam_local.sql -- CAPV_* portable seam over DBA_HIST_* (LOCAL mode).
-- =====================================================================
-- These nine views are the ONLY place the analytics touch Oracle's AWR
-- dictionary. Everything downstream (CAPD_/CAPF_/CAPA_/report) is written
-- once against CAPV_* and runs byte-identically in local, warehouse, or
-- fixture mode. Swapping this file for ddl/11_seam_warehouse.sql or
-- ddl/12_seam_fixture.sql re-points the same column contract at a different
-- source.
--
-- LOCAL mode requires the Diagnostics Pack and DIRECT SELECT grants (not via
-- a role) on the DBA_HIST_* views for the installing schema, so the views
-- compile. Install where the DBA_HIST rows you want are visible -- for a CDB
-- that is CDB$ROOT (AWR lives at the CDB level).
--
-- Column contract (identical in all three seam files):
--   * every view carries (dbid, con_dbid). DBA_HIST_SNAPSHOT has no CON_DBID
--     column, so CAPV_SNAPSHOT sets con_dbid := dbid. The tablespace/OS/time
--     views expose the real CON_DBID, which is REQUIRED to separate PDBs:
--     TABLESPACE_ID / TS# restart at 0 per container, so SYSTEM in the root
--     and SYSTEM in a PDB collide unless con_dbid disambiguates them.
--
-- Unit facts (do not "fix" these -- downstream converts):
--   * DBA_HIST_TBSPC_SPACE_USAGE sizes are in DB BLOCKS (multiply by the
--     tablespace block size to get bytes). Passed through as-is here.
--   * TABLESPACE_MAXSIZE = 0 means the tablespace has NO autoextend (its
--     current size is its ceiling).
--   * DBA_HIST_OSSTAT *_TIME values are in CENTISECONDS and are cumulative
--     counters since instance startup.
--   * DBA_HIST_SYS_TIME_MODEL values are in MICROSECONDS, cumulative counters.
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
-- CAPV_TIME_MODEL -- DB time model, filtered to the three CPU/DB-time names.
-- Values are cumulative counters in microseconds.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_time_model AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       stat_name                AS stat_name,
       value                    AS value
FROM   dba_hist_sys_time_model
WHERE  stat_name IN ('DB CPU','DB time','background cpu time');

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
--     "no days-to-limit". Verified on 19c: DBA_HIST_RESOURCE_LIMIT DOES carry
--     CON_DBID, so PDBs stay separable exactly like every other CAPV_ view.
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
-- CAPV_SYSSTAT (M11.2) -- system statistics, filtered to the one counter the
-- redo series needs. 'redo size' is a CUMULATIVE BYTE counter since instance
-- startup (like the OSSTAT/time-model counters), so the daily layer
-- differences consecutive snaps and drops restart-spanning intervals.
-- Redo is one stream per DATABASE and AWR records it under the CDB's
-- con_dbid, the same way OSSTAT does.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_sysstat AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       stat_name                AS stat_name,
       value                    AS value
FROM   dba_hist_sysstat
WHERE  stat_name = 'redo size';
