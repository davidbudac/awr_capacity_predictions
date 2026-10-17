--
-- report/report_csv.sql -- read-only CSV export of the CAPR report views.
-- =====================================================================
-- Writes one CSV file per CAPR section view into
-- reports/cap_csv_<db>_<ts>/<view>.csv, with a header line (line 1) and every value
-- quoted (SET MARKUP CSV ON QUOTE ON): capr_alerts, capr_tbspc_days_to_full,
-- capr_tbspc_forecast, capr_tbspc_anomalies, capr_cpu_trend,
-- capr_cpu_anomalies, capr_cpu_shifts, capr_series, capr_fit,
-- capr_anomalies. Every column of the view, every row in the scope (no top_n
-- bound), so a spreadsheet or a script gets what the reports format. A view
-- with no rows in the scope leaves an empty file: SQL*Plus prints no header
-- without a row.
-- READ-ONLY: only SELECTs. Never prompts.
--
-- Run from the REPO ROOT (needs report/defaults.sql only for a consistent
-- session setup, like the other drivers):
--   SQL> @report/report_csv.sql                       -- every database
--   SQL> @report/report_csv.sql 42424242              -- one dbid
--   SQL> @report/report_csv.sql 42424242 42424243     -- one container
--   SQL> @report/report_csv.sql - 42424243            -- one con_dbid, any dbid
-- Positional arguments are optional and UNDEFINEd at the end. Dates print as
-- YYYY-MM-DD HH24:MI:SS, numbers unformatted (NUMFORMAT TM9).
--
SET DEFINE '&'
SET VERIFY     OFF
SET FEEDBACK   OFF
SET ECHO       OFF
SET TERMOUT    OFF
SET TRIMSPOOL  ON
SET LINESIZE   32767
SET PAGESIZE   50000
SET HEADING    ON
SET NUMFORMAT  TM9
SET NEWPAGE    NONE
WHENEVER SQLERROR CONTINUE

-- COLUMN settings live for the whole SQL*Plus session: a report run earlier
-- in it would rename and reformat these columns. Start clean.
CLEAR COLUMNS
CLEAR BREAKS

ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

@@report/defaults.sql

COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;

-- Scope, as in report/report.sql: a number or the literal NULL.
COLUMN eff_sdbid NEW_VALUE cap_sdbid NOPRINT
COLUMN eff_scon  NEW_VALUE cap_scon  NOPRINT
COLUMN cap_dir   NEW_VALUE cap_dir   NOPRINT
SELECT NVL(REGEXP_SUBSTR(TRIM('&1'), '^[0-9]+$'), 'NULL') AS eff_sdbid,
       NVL(REGEXP_SUBSTR(TRIM('&2'), '^[0-9]+$'), 'NULL') AS eff_scon,
       'reports/cap_csv_'
         || REGEXP_REPLACE(SYS_CONTEXT('USERENV','DB_NAME'),'[^A-Za-z0-9]+','_') || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS')                AS cap_dir
FROM   dual;
COLUMN 1 CLEAR
COLUMN 2 CLEAR
COLUMN eff_sdbid CLEAR
COLUMN eff_scon  CLEAR
COLUMN cap_dir   CLEAR

HOST mkdir -p &cap_dir

SET MARKUP CSV ON DELIMITER , QUOTE ON

SPOOL &cap_dir/capr_alerts.csv
SELECT *
FROM   capr_alerts
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY sev_rank, kind, db_pdb, series_key, day_dt;
SPOOL OFF

SPOOL &cap_dir/capr_tbspc_days_to_full.csv
SELECT *
FROM   capr_tbspc_days_to_full
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY rank_dtf;
SPOOL OFF

SPOOL &cap_dir/capr_tbspc_forecast.csv
SELECT *
FROM   capr_tbspc_forecast
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY rank_report;
SPOOL OFF

SPOOL &cap_dir/capr_tbspc_anomalies.csv
SELECT *
FROM   capr_tbspc_anomalies
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY days_ago, con_dbid, tablespace_name, mode_rank;
SPOOL OFF

SPOOL &cap_dir/capr_cpu_trend.csv
SELECT *
FROM   capr_cpu_trend
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY con_dbid, metric;
SPOOL OFF

SPOOL &cap_dir/capr_cpu_anomalies.csv
SELECT *
FROM   capr_cpu_anomalies
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY days_ago, con_dbid, metric, mode_rank, ts;
SPOOL OFF

SPOOL &cap_dir/capr_cpu_shifts.csv
SELECT *
FROM   capr_cpu_shifts
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY rank_shift;
SPOOL OFF

SPOOL &cap_dir/capr_series.csv
SELECT *
FROM   capr_series
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY rank_series;
SPOOL OFF

SPOOL &cap_dir/capr_fit.csv
SELECT *
FROM   capr_fit
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY sev_rank, days_to_full, db, kind, series;
SPOOL OFF

SPOOL &cap_dir/capr_anomalies.csv
SELECT *
FROM   capr_anomalies
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY ts, dbid, con_dbid, kind, series;
SPOOL OFF

SET MARKUP CSV OFF
SET NUMFORMAT ""

-- SQL*Plus 19c starts every CSV spool with an empty line (verified with
-- NEWPAGE NONE / 0 and PAGESIZE 0); drop it so line 1 is the header.
HOST sed -i '1{/^$/d}' &cap_dir/*.csv
SET TERMOUT ON
SET PAGESIZE 200
SET NEWPAGE 1

UNDEFINE 1
UNDEFINE 2

PROMPT
PROMPT CSV written to: &cap_dir
PROMPT
