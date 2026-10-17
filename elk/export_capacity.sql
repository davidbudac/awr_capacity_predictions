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

-- Every SELECT drives from alias t (carrying dbid/con_dbid) and joins the
-- container labels as c; these two fragments rely on that convention.
DEFINE ident = "'db' VALUE NVL(c.db_pdb, TO_CHAR(t.con_dbid)), 'db_name' VALUE c.db_name, 'con_name' VALUE c.con_name, 'dbid' VALUE t.dbid, 'con_dbid' VALUE t.con_dbid, 'source' VALUE :cap_source, 'exported_at' VALUE :exported_at"
DEFINE cjoin = "LEFT JOIN capr_container c ON c.dbid = t.dbid AND c.con_dbid = t.con_dbid"

-- ===================================================================
-- observation
-- ===================================================================
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('obs|' || t.dbid || '|' || t.con_dbid
                    || '|TBSPC|' || t.tablespace_name || '|' || TO_CHAR(t.day_dt, 'YYYY-MM-DD'), 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'observation', 'kind' VALUE 'TBSPC', 'series' VALUE t.tablespace_name,
             &ident,
             'unit'         VALUE 'bytes',
             'value'        VALUE t.used_bytes,
             'limit'        VALUE t.limit_bytes,
             'pct'          VALUE ROUND(100 * t.used_bytes / NULLIF(t.limit_bytes, 0), 2),
             'anomaly'      VALUE CASE WHEN a.anomaly_flag IN ('HIGH', 'LOW') THEN 'true' ELSE 'false' END FORMAT JSON,
             'anomaly_flag' VALUE a.anomaly_flag,
             'z'            VALUE a.robust_z,
             'expected'     VALUE a.median_rate_bpd,
             'threshold'    VALUE a.threshold_bpd,
             'tbspc' VALUE JSON_OBJECT(
                 'used_bytes'   VALUE t.used_bytes,
                 'size_bytes'   VALUE t.size_bytes,
                 'limit_bytes'  VALUE t.limit_bytes,
                 'limit_source' VALUE t.limit_source,
                 'contents'     VALUE t.contents,
                 'delta_bytes'  VALUE x.used_delta_bytes,
                 'rate_bpd'     VALUE x.used_rate_bpd
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capd_tbspc_daily t
LEFT   JOIN capd_tbspc_delta x
  ON   x.dbid = t.dbid AND x.con_dbid = t.con_dbid
 AND   x.tablespace_name = t.tablespace_name AND x.day_dt = t.day_dt
LEFT   JOIN capa_tbspc_anom a
  ON   a.dbid = t.dbid AND a.con_dbid = t.con_dbid
 AND   a.tablespace_name = t.tablespace_name AND a.day_dt = t.day_dt
&cjoin;

-- One observed line per CAPF_CPU_TREND metric so every CPU forecast has
-- its history to chart against. The cpu.* detail rides on the headline
-- series only (BUSY_PCT, DB_CPU_PCT) so it is not counted three times.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('obs|' || t.dbid || '|' || t.con_dbid
                    || '|CPU|' || m.metric || '|' || TO_CHAR(t.day_dt, 'YYYY-MM-DD'), 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'observation', 'kind' VALUE 'CPU', 'series' VALUE m.metric,
             &ident,
             'unit'         VALUE 'pct',
             'value'        VALUE m.val,
             'limit'        VALUE 100,
             'pct'          VALUE m.val,
             'gap'          VALUE CASE t.gap_flag WHEN 'Y' THEN 'true' ELSE 'false' END FORMAT JSON,
             'anomaly'      VALUE CASE WHEN m.metric <> 'BUSY_PCT' THEN NULL
                                       WHEN a.anomaly_flag IN ('HIGH', 'LOW') THEN 'true'
                                       ELSE 'false' END FORMAT JSON,
             'anomaly_flag' VALUE a.anomaly_flag,
             'z'            VALUE a.robust_z,
             'expected'     VALUE a.median_pct,
             'threshold'    VALUE a.threshold_pct,
             'cpu' VALUE CASE WHEN m.metric = 'BUSY_PCT' THEN JSON_OBJECT(
                 'busy_pct'      VALUE t.busy_pct,
                 'busy_p95'      VALUE t.busy_p95,
                 'busy_max'      VALUE t.busy_max,
                 'busy_peak_pct' VALUE t.busy_peak_pct,
                 'host_busy_sec' VALUE t.host_busy_sec,
                 'num_cpus'      VALUE t.num_cpus,
                 'num_cpu_cores' VALUE t.num_cpu_cores
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capd_cpu_daily t
CROSS  APPLY (SELECT 'BUSY_PCT'  AS metric, t.busy_pct      AS val FROM dual UNION ALL
              SELECT 'BUSY_P95',            t.busy_p95             FROM dual UNION ALL
              SELECT 'BUSY_PEAK',           t.busy_peak_pct        FROM dual) m
LEFT   JOIN capa_cpu_anom a
  ON   a.dbid = t.dbid AND a.con_dbid = t.con_dbid AND a.day_dt = t.day_dt
 AND   m.metric = 'BUSY_PCT'
&cjoin
WHERE  m.val IS NOT NULL;

SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('obs|' || t.dbid || '|' || t.con_dbid
                    || '|CPU|' || m.metric || '|' || TO_CHAR(t.day_dt, 'YYYY-MM-DD'), 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'observation', 'kind' VALUE 'CPU', 'series' VALUE m.metric,
             &ident,
             'unit'  VALUE m.unit,
             'value' VALUE m.val,
             'limit' VALUE CASE WHEN m.unit = 'pct' THEN 100 END,
             'pct'   VALUE CASE WHEN m.unit = 'pct' THEN m.val END,
             'gap'   VALUE CASE t.gap_flag WHEN 'Y' THEN 'true' ELSE 'false' END FORMAT JSON,
             'cpu' VALUE CASE WHEN m.metric = 'DB_CPU_PCT' THEN JSON_OBJECT(
                 'db_cpu_sec'      VALUE t.db_cpu_sec,
                 'db_time_sec'     VALUE t.db_time_sec,
                 'db_cpu_pct'      VALUE t.db_cpu_pct,
                 'db_cpu_p95_pct'  VALUE t.db_cpu_p95_pct,
                 'db_cpu_per_core' VALUE t.db_cpu_per_core
                 ABSENT ON NULL) END FORMAT JSON
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capd_dbtime_daily t
CROSS  APPLY (SELECT 'DB_CPU_PCT' AS metric, 'pct' AS unit, t.db_cpu_pct     AS val FROM dual UNION ALL
              SELECT 'DB_CPU_P95',           'pct',         t.db_cpu_p95_pct        FROM dual UNION ALL
              SELECT 'DB_CPU_SEC',           'sec',         t.db_cpu_sec            FROM dual) m
&cjoin
WHERE  m.val IS NOT NULL;

SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('obs|' || t.dbid || '|' || t.con_dbid
                    || '|SERIES|' || t.series || '|' || TO_CHAR(t.day_dt, 'YYYY-MM-DD'), 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'observation', 'kind' VALUE 'SERIES', 'series' VALUE t.series,
             &ident,
             'unit'  VALUE LOWER(t.unit),
             'value' VALUE t.value,
             'limit' VALUE t.limit_value,
             'pct'   VALUE ROUND(100 * t.value / NULLIF(t.limit_value, 0), 2)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capd_series_daily t
&cjoin;

-- ===================================================================
-- forecast: REGR anchors from the Tier-1 views, ESM +30 from CAPF_COMPARE
-- ===================================================================
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fc|' || t.dbid || '|' || t.con_dbid
                    || '|TBSPC|' || t.tablespace_name || '|REGR|' || h.h, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.last_day + h.h, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'forecast', 'kind' VALUE 'TBSPC', 'series' VALUE t.tablespace_name,
             &ident,
             'unit'         VALUE 'bytes',
             'method'       VALUE 'REGR',
             'horizon_days' VALUE h.h,
             'value'        VALUE h.val,
             'lo'           VALUE h.lo,
             'hi'           VALUE h.hi,
             'limit'        VALUE t.limit_bytes,
             'pct'          VALUE ROUND(100 * h.val / NULLIF(t.limit_bytes, 0), 2),
             'quality'      VALUE t.quality
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capf_tbspc_forecast t
CROSS  APPLY (SELECT 0 AS h, t.cur_used AS val, CAST(NULL AS NUMBER) AS lo, CAST(NULL AS NUMBER) AS hi FROM dual UNION ALL
              SELECT 30,  t.proj_30_bytes,  t.proj_30_lo,  t.proj_30_hi  FROM dual UNION ALL
              SELECT 90,  t.proj_90_bytes,  t.proj_90_lo,  t.proj_90_hi  FROM dual UNION ALL
              SELECT 180, t.proj_180_bytes, t.proj_180_lo, t.proj_180_hi FROM dual UNION ALL
              SELECT 365, t.proj_365_bytes, t.proj_365_lo, t.proj_365_hi FROM dual) h
&cjoin
WHERE  t.quality <> 'INSUFFICIENT_HISTORY'
  AND  h.val IS NOT NULL;

SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fc|' || t.dbid || '|' || t.con_dbid
                    || '|CPU|' || t.metric || '|REGR|' || h.h, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.last_day + h.h, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'forecast', 'kind' VALUE 'CPU', 'series' VALUE t.metric,
             &ident,
             'unit'         VALUE CASE t.metric WHEN 'DB_CPU_SEC' THEN 'sec' ELSE 'pct' END,
             'method'       VALUE 'REGR',
             'horizon_days' VALUE h.h,
             'value'        VALUE h.val,
             'lo'           VALUE h.lo,
             'hi'           VALUE h.hi,
             'limit'        VALUE CASE WHEN t.metric <> 'DB_CPU_SEC' THEN 100 END,
             'pct'          VALUE CASE WHEN t.metric <> 'DB_CPU_SEC' THEN h.val END,
             'quality'      VALUE t.quality
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capf_cpu_trend t
CROSS  APPLY (SELECT 0 AS h, t.cur_val AS val, CAST(NULL AS NUMBER) AS lo, CAST(NULL AS NUMBER) AS hi FROM dual UNION ALL
              SELECT 30, t.proj_30, t.proj_30_lo, t.proj_30_hi FROM dual UNION ALL
              SELECT 90, t.proj_90, t.proj_90_lo, t.proj_90_hi FROM dual) h
&cjoin
WHERE  t.quality <> 'INSUFFICIENT_HISTORY'
  AND  h.val IS NOT NULL;

SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fc|' || t.dbid || '|' || t.con_dbid
                    || '|SERIES|' || t.series || '|REGR|' || h.h, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.last_day + h.h, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'forecast', 'kind' VALUE 'SERIES', 'series' VALUE t.series,
             &ident,
             'unit'         VALUE LOWER(t.unit),
             'method'       VALUE 'REGR',
             'horizon_days' VALUE h.h,
             'value'        VALUE h.val,
             'lo'           VALUE h.lo,
             'hi'           VALUE h.hi,
             'limit'        VALUE t.cur_limit,
             'pct'          VALUE ROUND(100 * h.val / NULLIF(t.cur_limit, 0), 2),
             'quality'      VALUE t.quality
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capf_series_forecast t
CROSS  APPLY (SELECT 0 AS h, t.cur_val AS val, CAST(NULL AS NUMBER) AS lo, CAST(NULL AS NUMBER) AS hi FROM dual UNION ALL
              SELECT 30, t.proj_30, t.proj_30_lo, t.proj_30_hi FROM dual UNION ALL
              SELECT 90, t.proj_90, t.proj_90_lo, t.proj_90_hi FROM dual) h
&cjoin
WHERE  t.quality <> 'INSUFFICIENT_HISTORY'
  AND  h.val IS NOT NULL;

-- CAPF_COMPARE folds DB CPU into kind CPU under series_key DB_CPU_SEC, and
-- only returns ESM rows whose model is trained through the series' last
-- day, so that last day anchors the target date.
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fc|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.series_kind || '|' || t.series_key || '|ESM|' || t.horizon_days, 'MD5'))),
         '@timestamp' VALUE TO_CHAR(f.last_day + t.horizon_days, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'forecast', 'kind' VALUE t.series_kind, 'series' VALUE t.series_key,
             &ident,
             'unit'         VALUE CASE WHEN t.series_kind = 'TBSPC' THEN 'bytes'
                                       WHEN t.series_key = 'DB_CPU_SEC' THEN 'sec' ELSE 'pct' END,
             'method'       VALUE 'ESM',
             'horizon_days' VALUE t.horizon_days,
             'value'        VALUE t.value,
             'lo'           VALUE t.lower_bound,
             'hi'           VALUE t.upper_bound,
             'limit'        VALUE f.limit_val,
             'pct'          VALUE ROUND(100 * t.value / NULLIF(f.limit_val, 0), 2),
             'quality'      VALUE f.quality
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capf_compare t
JOIN  (SELECT dbid, con_dbid, 'TBSPC' AS series_kind, tablespace_name AS series_key,
              last_day, limit_bytes AS limit_val, quality
       FROM   capf_tbspc_forecast
       UNION ALL
       SELECT dbid, con_dbid, 'CPU', metric, last_day,
              CASE WHEN metric <> 'DB_CPU_SEC' THEN 100 END, quality
       FROM   capf_cpu_trend) f
  ON   f.dbid = t.dbid AND f.con_dbid = t.con_dbid
 AND   f.series_kind = t.series_kind AND f.series_key = t.series_key
&cjoin
WHERE  t.engine = 'ESM'
  AND  t.value IS NOT NULL;

-- ===================================================================
-- fit: one per series per export day, so days-to-full charts over time
-- ===================================================================
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fit|' || t.dbid || '|' || t.con_dbid
                    || '|TBSPC|' || t.tablespace_name || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'fit', 'kind' VALUE 'TBSPC', 'series' VALUE t.tablespace_name,
             &ident,
             'unit'            VALUE 'bytes',
             'method'          VALUE t.slope_method,
             'value'           VALUE t.cur_used,
             'limit'           VALUE t.limit_bytes,
             'pct'             VALUE t.pct_used,
             'slope_per_day'   VALUE t.slope_bpd,
             'r2'              VALUE t.r2,
             'quality'         VALUE t.quality,
             'days_to_full'    VALUE t.days_to_full,
             'days_to_full_lo' VALUE t.days_to_full_lo,
             'days_to_full_hi' VALUE t.days_to_full_hi,
             'accel'           VALUE t.accel_ratio,
             'train_n'         VALUE t.train_n,
             'sev'             VALUE s.sev,
             'sev_rank'        VALUE CASE s.sev WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END,
             'tbspc' VALUE JSON_OBJECT(
                 'used_bytes'   VALUE t.cur_used,
                 'limit_bytes'  VALUE t.limit_bytes,
                 'limit_source' VALUE t.limit_source
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capf_tbspc_forecast t
CROSS  APPLY (SELECT CASE WHEN 'CRIT' IN (r.sev_dtf, r.sev_nearfull) THEN 'CRIT'
                          WHEN 'WARN' IN (r.sev_dtf, r.sev_nearfull) THEN 'WARN'
                          ELSE 'OK' END AS sev
              FROM   dual
              LEFT   JOIN capr_tbspc_days_to_full r
                ON   r.dbid = t.dbid AND r.con_dbid = t.con_dbid
               AND   r.tablespace_name = t.tablespace_name) s
&cjoin;

SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fit|' || t.dbid || '|' || t.con_dbid
                    || '|CPU|' || t.metric || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'fit', 'kind' VALUE 'CPU', 'series' VALUE t.metric,
             &ident,
             'unit'            VALUE CASE t.metric WHEN 'DB_CPU_SEC' THEN 'sec' ELSE 'pct' END,
             'method'          VALUE t.slope_method,
             'value'           VALUE t.cur_val,
             'limit'           VALUE CASE WHEN t.metric <> 'DB_CPU_SEC' THEN k.cpu_sat END,
             'pct'             VALUE CASE WHEN t.metric <> 'DB_CPU_SEC' THEN t.cur_val END,
             'slope_per_day'   VALUE t.slope_per_day,
             'r2'              VALUE t.r2,
             'quality'         VALUE t.quality,
             'days_to_full'    VALUE t.days_to_sat,
             'days_to_full_lo' VALUE t.days_to_sat_lo,
             'days_to_full_hi' VALUE t.days_to_sat_hi,
             'train_n'         VALUE t.train_n,
             'sev'             VALUE CASE al.sev_rank WHEN 1 THEN 'CRIT' WHEN 2 THEN 'WARN' ELSE 'OK' END,
             'sev_rank'        VALUE NVL(al.sev_rank, 3)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capf_cpu_trend t
CROSS  JOIN (SELECT MAX(cfg_value) AS cpu_sat FROM cap_config WHERE cfg_name = 'cpu_sat_pct') k
LEFT   JOIN (SELECT dbid, con_dbid, series_key, MIN(sev_rank) AS sev_rank
             FROM   capr_alerts
             WHERE  kind IN ('CPU_SAT', 'DBCPU_SAT')
             GROUP  BY dbid, con_dbid, series_key) al
  ON   al.dbid = t.dbid AND al.con_dbid = t.con_dbid AND al.series_key = t.metric
&cjoin;

SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('fit|' || t.dbid || '|' || t.con_dbid
                    || '|SERIES|' || t.series || '|' || :export_day, 'MD5'))),
         '@timestamp' VALUE :export_day || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'fit', 'kind' VALUE 'SERIES', 'series' VALUE t.series,
             &ident,
             'unit'            VALUE LOWER(t.unit),
             'value'           VALUE t.cur_val,
             'limit'           VALUE t.cur_limit,
             'pct'             VALUE t.pct_of_limit,
             'slope_per_day'   VALUE t.slope_per_day,
             'r2'              VALUE t.r2,
             'quality'         VALUE t.quality,
             'days_to_full'    VALUE t.days_to_limit,
             'days_to_full_lo' VALUE t.days_to_limit_lo,
             'days_to_full_hi' VALUE t.days_to_limit_hi,
             'train_n'         VALUE t.train_n,
             'sev'             VALUE NVL(UPPER(r.sev), 'OK'),
             'sev_rank'        VALUE CASE UPPER(r.sev) WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capf_series_forecast t
LEFT   JOIN capr_series r
  ON   r.dbid = t.dbid AND r.con_dbid = t.con_dbid AND r.series = t.series
&cjoin;

-- ===================================================================
-- anomaly: severity comes from the matching CAPR_ALERTS row (WARN for a
-- HIGH, INFO for a LOW/DOWN); events older than the alert window have no
-- alert row and default to INFO.
-- ===================================================================
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('anom|' || t.dbid || '|' || t.con_dbid
                    || '|TBSPC_GROWTH|' || t.tablespace_name || '|' || TO_CHAR(t.day_dt, 'YYYY-MM-DD'), 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'anomaly', 'kind' VALUE 'TBSPC', 'series' VALUE t.tablespace_name,
             &ident,
             'unit'         VALUE 'bytes',
             'anomaly'      VALUE 'true' FORMAT JSON,
             'anomaly_kind' VALUE 'TBSPC_GROWTH',
             'anomaly_flag' VALUE t.anomaly_flag,
             'value'        VALUE t.used_delta_bytes,
             'expected'     VALUE t.median_rate_bpd,
             'threshold'    VALUE t.threshold_bpd,
             'z'            VALUE t.robust_z,
             'sev'          VALUE NVL(TRIM(al.severity), 'INFO'),
             'sev_rank'     VALUE NVL(al.sev_rank, 3),
             'message'      VALUE t.tablespace_name
                                  || CASE t.anomaly_flag WHEN 'HIGH' THEN ' grew ' ELSE ' shrank ' END
                                  || TO_CHAR(ABS(t.used_delta_bytes) / 1073741824, 'FM999999990.0')
                                  || ' GiB on ' || TO_CHAR(t.day_dt, 'YYYY-MM-DD')
                                  || ' (median ' || TO_CHAR(t.median_rate_bpd / 1073741824, 'FM999999990.0')
                                  || ' GiB/day, z=' || NVL(TO_CHAR(t.robust_z, 'FM999999990.0'), 'off-scale') || ')',
             'tbspc' VALUE JSON_OBJECT(
                 'delta_bytes' VALUE t.used_delta_bytes,
                 'rate_bpd'    VALUE t.used_rate_bpd
                 ABSENT ON NULL)
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capa_tbspc_anom t
LEFT   JOIN capr_alerts al
  ON   al.kind = 'TBSPC_ANOM' AND al.dbid = t.dbid AND al.con_dbid = t.con_dbid
 AND   al.series_key = t.tablespace_name AND al.day_dt = t.day_dt
&cjoin
WHERE  t.anomaly_flag IN ('HIGH', 'LOW');

SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('anom|' || t.dbid || '|' || t.con_dbid
                    || '|CPU_BUSY|BUSY_PCT|' || TO_CHAR(t.day_dt, 'YYYY-MM-DD'), 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'anomaly', 'kind' VALUE 'CPU', 'series' VALUE 'BUSY_PCT',
             &ident,
             'unit'         VALUE 'pct',
             'anomaly'      VALUE 'true' FORMAT JSON,
             'anomaly_kind' VALUE 'CPU_BUSY',
             'anomaly_flag' VALUE t.anomaly_flag,
             'value'        VALUE t.busy_pct,
             'expected'     VALUE t.median_pct,
             'threshold'    VALUE t.threshold_pct,
             'z'            VALUE t.robust_z,
             'sev'          VALUE NVL(TRIM(al.severity), 'INFO'),
             'sev_rank'     VALUE NVL(al.sev_rank, 3),
             'message'      VALUE 'Host CPU ' || TO_CHAR(t.busy_pct, 'FM990.0') || '% busy on '
                                  || TO_CHAR(t.day_dt, 'YYYY-MM-DD')
                                  || ' (median ' || TO_CHAR(t.median_pct, 'FM990.0')
                                  || '% for that weekday, z=' || NVL(TO_CHAR(t.robust_z, 'FM999999990.0'), 'off-scale') || ')'
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capa_cpu_anom t
LEFT   JOIN capr_alerts al
  ON   al.kind = 'CPU_ANOM' AND al.dbid = t.dbid AND al.con_dbid = t.con_dbid
 AND   al.series_key = 'BUSY_PCT' AND al.day_dt = t.day_dt
&cjoin
WHERE  t.anomaly_flag IN ('HIGH', 'LOW');

SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('anom|' || t.dbid || '|' || t.con_dbid
                    || '|CPU_SHIFT|' || t.metric || '|' || TO_CHAR(t.last_day, 'YYYY-MM-DD'), 'MD5'))),
         '@timestamp' VALUE TO_CHAR(t.last_day, 'YYYY-MM-DD') || 'T00:00:00Z',
         'cap' VALUE JSON_OBJECT(
             'record' VALUE 'anomaly', 'kind' VALUE 'CPU', 'series' VALUE t.metric,
             &ident,
             'unit'         VALUE LOWER(TRIM(t.unit)),
             'anomaly'      VALUE 'true' FORMAT JSON,
             'anomaly_kind' VALUE 'CPU_SHIFT',
             'anomaly_flag' VALUE t.shift_flag,
             'value'        VALUE t.recent_med,
             'expected'     VALUE t.base_med,
             'threshold'    VALUE t.threshold_pct,
             'shift_pct'    VALUE t.shift_pct,
             'sev'          VALUE NVL(TRIM(al.severity), 'INFO'),
             'sev_rank'     VALUE NVL(al.sev_rank, 3),
             'message'      VALUE t.metric || ' shifted ' || t.shift_flag || ' '
                                  || TO_CHAR(t.shift_pct, 'FMS9999990.0') || ' pts: last '
                                  || TO_CHAR(t.recent_days, 'FM9999990') || ' days median '
                                  || TO_CHAR(t.recent_med, 'FM99999990.0') || '% vs prior '
                                  || TO_CHAR(t.base_days, 'FM9999990') || ' days '
                                  || TO_CHAR(t.base_med, 'FM99999990.0') || '%'
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capa_cpu_shift t
LEFT   JOIN capr_alerts al
  ON   al.kind = 'CPU_SHIFT' AND al.dbid = t.dbid AND al.con_dbid = t.con_dbid
 AND   al.series_key = t.metric AND al.day_dt = t.last_day
&cjoin
WHERE  t.shift_flag IN ('UP', 'DOWN');

-- ===================================================================
-- alert: the pollable CAPR_ALERTS feed, snapshotted per export day
-- ===================================================================
SELECT JSON_OBJECT(
         'id' VALUE LOWER(RAWTOHEX(STANDARD_HASH('alert|' || t.dbid || '|' || t.con_dbid
                    || '|' || t.kind || '|' || t.series_key || '|' || TO_CHAR(t.day_dt, 'YYYY-MM-DD')
                    || '|' || :export_day, 'MD5'))),
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
             'sev'        VALUE TRIM(t.severity),
             'sev_rank'   VALUE t.sev_rank,
             'obs_day'    VALUE TO_CHAR(t.day_dt, 'YYYY-MM-DD') || 'T00:00:00Z',
             'value'      VALUE t.value,
             'threshold'  VALUE t.threshold,
             'message'    VALUE t.message
             ABSENT ON NULL)
         ABSENT ON NULL RETURNING CLOB)
FROM   capr_alerts t
&cjoin;

UNDEFINE ident cjoin
