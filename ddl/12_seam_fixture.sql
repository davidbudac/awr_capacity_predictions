--
-- ddl/12_seam_fixture.sql -- CAPV_* seam over CAP_FIXTURE_* tables (TEST mode).
-- =====================================================================
-- FIXTURE mode is the automated-test hook. We cannot INSERT synthetic rows
-- into DBA_HIST_*, so instead the seam points CAPV_* at plain CAP_FIXTURE_*
-- tables whose shapes match the CAPV contract exactly. test/fixture_install.sql
-- creates and populates those tables with deterministic series (exact linear
-- growth, an injected spike, a flat series, CPU counters with a restart) so
-- run_test.sql can assert the analytics reproduce known closed-form answers.
--
-- ORDER MATTERS: the CAP_FIXTURE_* tables must exist before these views
-- compile. Run test/fixture_install.sql (which creates + fills them) BEFORE
-- @install.sql with seam_mode=fixture.
--
-- The fixture tables already store the post-mapping CAPV columns (bytes stay
-- blocks, counters stay cumulative, etc.), so these views are thin
-- pass-throughs -- keeping the fixture data honest to the same contract the
-- local seam presents.
--
SET DEFINE OFF

CREATE OR REPLACE VIEW capv_snapshot AS
SELECT dbid, con_dbid, instance_number, snap_id,
       begin_interval_time, end_interval_time, startup_time
FROM   cap_fixture_snapshot;

CREATE OR REPLACE VIEW capv_tbspc_usage AS
SELECT dbid, con_dbid, snap_id, tablespace_id,
       tablespace_size, tablespace_maxsize, tablespace_usedsize
FROM   cap_fixture_tbspc_usage;

CREATE OR REPLACE VIEW capv_tablespace AS
SELECT dbid, con_dbid, tablespace_id, tablespace_name, contents, block_size
FROM   cap_fixture_tablespace;

CREATE OR REPLACE VIEW capv_datafile AS
SELECT dbid, con_dbid, tablespace_id, block_size
FROM   cap_fixture_datafile;

CREATE OR REPLACE VIEW capv_osstat AS
SELECT dbid, con_dbid, instance_number, snap_id, stat_name, value
FROM   cap_fixture_osstat;

CREATE OR REPLACE VIEW capv_time_model AS
SELECT dbid, con_dbid, instance_number, snap_id, stat_name, value
FROM   cap_fixture_time_model;

CREATE OR REPLACE VIEW capv_container AS
SELECT dbid, con_dbid, db_name, con_name
FROM   cap_fixture_container;

-- M11 sources. CAP_FIXTURE_RESOURCE_LIMIT stores limit_value ALREADY as a
-- NUMBER (the local seam's 'UNLIMITED'-to-NULL conversion is part of the
-- mapping, not of the contract), and CAP_FIXTURE_SYSSTAT deliberately holds a
-- second, irrelevant stat name so the downstream 'redo size' filter is
-- exercised rather than assumed.
CREATE OR REPLACE VIEW capv_resource_limit AS
SELECT dbid, con_dbid, instance_number, snap_id, resource_name,
       current_utilization, max_utilization, limit_value
FROM   cap_fixture_resource_limit;

CREATE OR REPLACE VIEW capv_sysstat AS
SELECT dbid, con_dbid, instance_number, snap_id, stat_name, value
FROM   cap_fixture_sysstat;

-- --------------------------------------------------------------------
-- CAPV_CONTRACT -- what this seam actually presents, one row per fact
-- source: row count, distinct con_dbid, snap_id range and the newest
-- snapshot end time. per_container_expected = 'Y' where the contract wants
-- one series per container (TBSPC_USAGE, TIME_MODEL, SYSSTAT) and 'N' where
-- the source is host / instance / spine level (OSSTAT, RESOURCE_LIMIT,
-- SNAPSHOT), so n_con_dbid = 1 against a 'Y' means the per-PDB series are
-- missing. A diagnostic for doctor.sql: it full-scans every source, and no
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
