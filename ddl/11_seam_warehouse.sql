--
-- ddl/11_seam_warehouse.sql -- CAPV_* seam over the awr-fleet-warehouse AWRV_* views.
-- =====================================================================
-- WAREHOUSE mode. Re-points the six CAPV_* seam views at the fleet warehouse's
-- AWRV_* seam (its DBA_HIST-shaped views over the collected facts) instead of
-- local DBA_HIST_*. Everything downstream (CAPD_/CAPF_/CAPA_/report) is
-- byte-identical to local mode -- the whole point of the seam.
--
-- As of Milestone W the awr-fleet-warehouse collector gathers the three sources
-- this toolkit needs (tablespace space usage, OSSTAT, SYS_TIME_MODEL) into
-- awrw_tbspc_stat / awrw_osstat / awrw_time_model, with awrw_tablespace /
-- awrw_datafile dimensions, and exposes them through:
--   awrv_snapshot, awrv_tbspc_space_usage, awrv_tablespace, awrv_datafile,
--   awrv_osstat, awrv_sys_time_model
-- (see awr-fleet-warehouse/ddl/50_awrv_views.sql). Install this suite where
-- those views are visible -- i.e. as the warehouse owner (AWRWH), or in a
-- schema with direct SELECT grants on them (grant + schema-qualify below).
--
-- Contract note: the warehouse presents EVERY collected database. These views
-- pass them all through keyed on (dbid, con_dbid); the report shows con_dbid per
-- row, so a single-target warehouse reads as one database and a multi-target
-- warehouse reads as a fleet-wide capacity report. How many CONTAINERS appear
-- per target depends on the collector's reader privileges: a least-privilege
-- reader at CDB$ROOT yields the root container only (one con_dbid), which is the
-- common case (verified on 19c: SYSTEM/SYSAUX/USERS of the root). Cross-DBID
-- series stitching (the warehouse's stable target_id spanning DBID migrations)
-- is a documented v2 item -- v1 analytics key on (dbid, con_dbid), like local.
--
-- Column contract identical to ddl/10_seam_local.sql: every view carries
-- (dbid, con_dbid). AWRV_SNAPSHOT has no CON_DBID (the warehouse keys snapshots
-- on DBID only, like DBA_HIST_SNAPSHOT), so CAPV_SNAPSHOT sets con_dbid := dbid.
-- The tablespace/OS/time views expose the real CON_DBID the warehouse stores.
--
-- Unit facts unchanged (the warehouse stores raw): TBSPC sizes in BLOCKS,
-- TABLESPACE_MAXSIZE=0 = no autoextend, OSSTAT *_TIME in centiseconds,
-- SYS_TIME_MODEL in microseconds. See ddl/10_seam_local.sql for the full notes.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPV_SNAPSHOT -- snapshot spine. con_dbid := dbid (AWRV_SNAPSHOT, like
-- DBA_HIST_SNAPSHOT, carries no CON_DBID).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_snapshot AS
SELECT dbid                     AS dbid,
       dbid                     AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       begin_interval_time      AS begin_interval_time,
       end_interval_time        AS end_interval_time,
       startup_time             AS startup_time
FROM   awrv_snapshot;

-- --------------------------------------------------------------------
-- CAPV_TBSPC_USAGE -- tablespace space usage, sizes in BLOCKS (as-is).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_tbspc_usage AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       snap_id                  AS snap_id,
       tablespace_id            AS tablespace_id,
       tablespace_size          AS tablespace_size,      -- blocks
       tablespace_maxsize       AS tablespace_maxsize,   -- blocks; 0 = no autoextend
       tablespace_usedsize      AS tablespace_usedsize   -- blocks
FROM   awrv_tbspc_space_usage;

-- --------------------------------------------------------------------
-- CAPV_TABLESPACE -- tablespace dimension (name + contents + block size).
-- block_size is the PRIMARY blocks->bytes factor (populated for every
-- tablespace); CAPV_DATAFILE is the fallback.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_tablespace AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       ts#                      AS tablespace_id,
       tsname                   AS tablespace_name,
       contents                 AS contents,             -- PERMANENT / UNDO / TEMPORARY
       block_size               AS block_size            -- bytes/block
FROM   awrv_tablespace;

-- --------------------------------------------------------------------
-- CAPV_DATAFILE -- block size per tablespace (MAX across its datafiles).
-- AWRV_DATAFILE is one row per file; aggregate to per-tablespace here, exactly
-- as ddl/10_seam_local.sql does over DBA_HIST_DATAFILE.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_datafile AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       ts#                      AS tablespace_id,
       MAX(block_size)          AS block_size            -- bytes/block
FROM   awrv_datafile
GROUP BY dbid, con_dbid, ts#;

-- --------------------------------------------------------------------
-- CAPV_OSSTAT -- host OS stats. The warehouse already filters to these names at
-- collection; the WHERE is kept for parity with the local seam and robustness.
-- *_TIME values are cumulative counters in centiseconds.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_osstat AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       stat_name                AS stat_name,
       value                    AS value
FROM   awrv_osstat
WHERE  stat_name IN ('BUSY_TIME','IDLE_TIME','IOWAIT_TIME',
                     'NUM_CPUS','NUM_CPU_CORES','PHYSICAL_MEMORY_BYTES');

-- --------------------------------------------------------------------
-- CAPV_TIME_MODEL -- DB time model. Values are cumulative counters in
-- microseconds. (Warehouse filters at collection; WHERE kept for parity.)
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capv_time_model AS
SELECT dbid                     AS dbid,
       con_dbid                 AS con_dbid,
       instance_number          AS instance_number,
       snap_id                  AS snap_id,
       stat_name                AS stat_name,
       value                    AS value
FROM   awrv_sys_time_model
WHERE  stat_name IN ('DB CPU','DB time','background cpu time');
