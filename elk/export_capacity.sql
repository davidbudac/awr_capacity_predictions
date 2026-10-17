--
-- elk/export_capacity.sql -- the suite's analytics as NDJSON, one document
-- per line, for elk/ship.sh to bulk-load into the awrcap-capacity index.
-- The document shape is elk/elasticsearch/index-template.json (dynamic:
-- strict), so every key emitted here must exist there.
--
-- Run where the CAP* views resolve unqualified (CURRENT_SCHEMA), e.g.
--   SQL> DEFINE cap_source = 'cdb1/PDB1:CAPDEMO'
--   SQL> @elk/export_capacity.sql
-- cap_source defaults to <db_name>/<con_name>:<current_schema>.
--
-- Read-only: SELECTs only. Every document carries "id" (MD5 of its natural
-- key), which ship.sh moves into _id so re-exports overwrite in place.
--
SET DEFINE ON
SET VERIFY OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET LINESIZE 32767
SET LONG 2000000
SET LONGCHUNKSIZE 2000000
SET TRIMSPOOL ON
SET TRIMOUT ON
SET TAB OFF
SET SERVEROUTPUT OFF
WHENEVER SQLERROR EXIT FAILURE

COLUMN cap_source NEW_VALUE cap_source NOPRINT
SELECT NULL AS cap_source FROM dual WHERE 1 = 0;

VARIABLE cap_source  VARCHAR2(400)
VARIABLE exported_at VARCHAR2(20)
VARIABLE export_day  VARCHAR2(10)
BEGIN
    :cap_source  := NVL('&cap_source',
                        LOWER(NVL(SYS_CONTEXT('USERENV', 'CDB_NAME'), SYS_CONTEXT('USERENV', 'DB_NAME'))) || '/'
                        || SYS_CONTEXT('USERENV', 'CON_NAME') || ':'
                        || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
    :exported_at := TO_CHAR(SYS_EXTRACT_UTC(SYSTIMESTAMP), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    :export_day  := SUBSTR(:exported_at, 1, 10);
END;
/

-- Every SELECT drives from alias t, a CAPR_* view carrying the container
-- labels (db, db_name, con_name) next to dbid/con_dbid.
-- Timestamps: every day and hour below is the DB wall clock labelled Z (a
-- label, not a UTC conversion; Kibana runs with dateFormat:tz = UTC, set by
-- elk/setup.sh). Only exported_at is a true UTC instant.
DEFINE ident = "'db' VALUE t.db, 'db_name' VALUE t.db_name, 'con_name' VALUE t.con_name, 'dbid' VALUE t.dbid, 'con_dbid' VALUE t.con_dbid, 'source' VALUE :cap_source, 'exported_at' VALUE :exported_at"

-- The four record types below are straight projections of the CAPR_* point
-- views (ddl/45, ddl/55), which grafana/ords serves too; the logic lives
-- there, once.

-- observation: CAPR_SERIES_POINTS, daily only (CAPR_HOURLY_POINTS is not
-- exported). doc_key = 'obs|dbid|con_dbid|kind|series|YYYY-MM-DD', the
-- exact string this id hashed before the view carried it, so existing
-- observation documents are overwritten in place.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH(t.doc_key, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.ts, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'observation', 'kind' VALUE t.kind, 'series' VALUE t.series,
             &ident,
             'unit'         VALUE t.unit,
             'value'        VALUE t.value,
             'limit'        VALUE t.limit_value,
             'pct'          VALUE t.pct,
             'gap'          VALUE CASE t.gap WHEN 1 THEN 'true' WHEN 0 THEN 'false' END FORMAT JSON,
             'anomaly'      VALUE CASE t.anomaly WHEN 1 THEN 'true' WHEN 0 THEN 'false' END FORMAT JSON,
             'anomaly_flag' VALUE t.anomaly_flag,
             'anomaly_modes' VALUE CASE WHEN t.anomaly_modes IS NOT NULL
                                        THEN '["' || REPLACE(t.anomaly_modes, ',', '","') || '"]' END FORMAT JSON,
             'hours_flagged' VALUE t.how_hours_flagged,
             'z'            VALUE t.z,
             'expected'     VALUE t.expected,
             'threshold'    VALUE t.threshold,
             'tbspc' VALUE CASE WHEN t.kind = 'TBSPC' THEN JSON_OBJECT(
                 'used_bytes'   VALUE t.used_bytes,
                 'size_bytes'   VALUE t.size_bytes,
                 'limit_bytes'  VALUE t.limit_bytes,
                 'limit_source' VALUE t.limit_source,
                 'contents'     VALUE t.contents,
                 'delta_bytes'  VALUE t.delta_bytes,
                 'rate_bpd'     VALUE t.rate_bpd
                 ABSENT ON NULL) END FORMAT JSON,
             'cpu' VALUE CASE WHEN t.series IN ('BUSY_PCT', 'DB_CPU_PCT') THEN JSON_OBJECT(
                 'busy_pct'        VALUE t.busy_pct,
                 'busy_p95'        VALUE t.busy_p95,
                 'busy_max'        VALUE t.busy_max,
                 'busy_peak_pct'   VALUE t.busy_peak_pct,
                 'host_busy_sec'   VALUE t.host_busy_sec,
                 'num_cpus'        VALUE t.num_cpus,
                 'num_cpu_cores'   VALUE t.num_cpu_cores,
                 'db_cpu_sec'      VALUE t.db_cpu_sec,
                 'db_time_sec'     VALUE t.db_time_sec,
                 'db_cpu_pct'      VALUE t.db_cpu_pct,
                 'db_cpu_p95_pct'  VALUE t.db_cpu_p95_pct,
                 'db_cpu_per_core' VALUE t.db_cpu_per_core
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_series_points t;

-- forecast: CAPR_FORECAST_POINTS (REGR anchors + the ESM point). The ESM
-- point's horizon_days shrinks as its model ages, so its id hashes the 30-day
-- comparison bucket instead: an aging model replaces its document.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fc|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.kind || '|' || t.series || '|' || t.method || '|'
                    || CASE WHEN t.method = 'ESM' THEN 30 ELSE t.horizon_days END, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.ts, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'forecast', 'kind' VALUE t.kind, 'series' VALUE t.series,
             &ident,
             'unit'         VALUE t.unit,
             'method'       VALUE t.method,
             'horizon_days' VALUE t.horizon_days,
             'value'        VALUE t.value,
             'lo'           VALUE t.lo,
             'hi'           VALUE t.hi,
             'limit'        VALUE t.limit_value,
             'pct'          VALUE t.pct,
             'quality'      VALUE t.quality
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_forecast_points t;

-- fit: CAPR_FIT, one per series per export day, so days-to-full charts
-- over time
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fit|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.kind || '|' || t.series || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'fit', 'kind' VALUE t.kind, 'series' VALUE t.series,
             &ident,
             'unit'            VALUE t.unit,
             'method'          VALUE t.method,
             'value'           VALUE t.value,
             'limit'           VALUE t.limit_value,
             'pct'             VALUE t.pct,
             'slope_per_day'   VALUE t.slope_per_day,
             'r2'              VALUE t.r2,
             'quality'         VALUE t.quality,
             'days_to_full'    VALUE t.days_to_full,
             'days_to_full_lo' VALUE t.days_to_full_lo,
             'days_to_full_hi' VALUE t.days_to_full_hi,
             'accel'           VALUE t.accel,
             'train_n'         VALUE t.train_n,
             'sev'             VALUE t.sev,
             'sev_rank'        VALUE t.sev_rank,
             'tbspc' VALUE CASE WHEN t.kind = 'TBSPC' THEN JSON_OBJECT(
                 'used_bytes'   VALUE t.value,
                 'limit_bytes'  VALUE t.limit_value,
                 'limit_source' VALUE t.limit_source
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_fit t;

-- anomaly: CAPR_ANOMALIES, one per (event, baseline mode). doc_key keys on
-- kind, series, mode and the event hour; a level shift keys on obs_day (the
-- window's last day), so it is overwritten, not duplicated, as the window
-- slides, while its @timestamp is the window's first day. HOUR rows carry
-- their hour in @timestamp; DAY rows land on midnight.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH(t.doc_key, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.ts, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'anomaly', 'kind' VALUE t.kind, 'series' VALUE t.series,
             &ident,
             'unit'         VALUE t.unit,
             'anomaly'      VALUE 'true' FORMAT JSON,
             'anomaly_kind' VALUE t.anomaly_kind,
             'baseline_mode' VALUE t.baseline_mode,
             'grain'        VALUE t.grain,
             'n_hist'       VALUE t.n_hist,
             'alerting'     VALUE CASE t.alerting WHEN 'Y' THEN 'true' WHEN 'N' THEN 'false' END FORMAT JSON,
             'obs_day'      VALUE TO_CHAR(t.obs_day, 'YYYY-MM-DD') || 'T00:00:00Z',
             'anomaly_flag' VALUE t.anomaly_flag,
             'value'        VALUE t.value,
             'raw_value'    VALUE t.raw_value,
             'expected'     VALUE t.expected,
             'threshold'    VALUE t.threshold,
             'z'            VALUE t.z,
             'shift_pct'    VALUE t.shift_pct,
             'sev'          VALUE t.sev,
             'sev_rank'     VALUE t.sev_rank,
             'message'      VALUE t.message,
             'tbspc' VALUE CASE WHEN t.kind = 'TBSPC' THEN JSON_OBJECT(
                 'delta_bytes' VALUE t.raw_value,
                 'rate_bpd'    VALUE t.value
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_anomalies t;

-- ===================================================================
-- alert: the pollable CAPR_ALERTS feed, snapshotted per export day; one
-- per alert_key (dbid|con_dbid|kind|series|day|mode) and export day
-- ===================================================================
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('alert|' || t.alert_key || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'alert',
             'kind'   VALUE CASE WHEN t.kind LIKE 'TBSPC%'  THEN 'TBSPC'
                                 WHEN t.kind LIKE 'SERIES%' THEN 'SERIES'
                                 ELSE 'CPU' END,
             'series' VALUE t.series_key,
             &ident,
             'unit'       VALUE LOWER(t.unit),
             'alert_kind' VALUE t.kind,
             'baseline_mode' VALUE t.baseline_mode,
             'sev'        VALUE TRIM(t.severity),
             'sev_rank'   VALUE t.sev_rank,
             'obs_day'    VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
             'value'      VALUE t.value,
             'threshold'  VALUE t.threshold,
             'message'    VALUE t.message
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM  (SELECT a.*, NVL(c.db_pdb, TO_CHAR(a.con_dbid)) AS db, c.db_name, c.con_name
       FROM   capr_alerts a
       LEFT   JOIN capr_container c ON c.dbid = a.dbid AND c.con_dbid = a.con_dbid) t;

UNDEFINE ident
