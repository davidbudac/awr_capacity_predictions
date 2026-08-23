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
