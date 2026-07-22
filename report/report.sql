--
-- report/report.sql -- read-only text capacity report.
-- =====================================================================
-- Spools a plain-text capacity + anomaly report from the CAPF_/CAPA_ views to
-- reports/cap_report_<db>_<ts>.txt. READ-ONLY: only SELECTs (the CAPF_ESM
-- views call a pipelined function, which writes nothing). Creates/modifies no
-- database object.
--
-- Run from the REPO ROOT so the @@report/sections/* includes resolve (SQL*Plus
-- @@ is relative to the outermost caller's directory on 19c):
--   sqlplus user/pw@svc
--   SQL> @report/defaults.sql      -- optional; sets top_n / anomaly_days / show_esm
--   SQL> @report/report.sql
--
-- Requires the suite installed (any seam mode). Tier 2 rows appear only if
-- cap_forecast_ml.train_all has been run.
--
SET DEFINE '&'
SET VERIFY     OFF
SET FEEDBACK   OFF
SET ECHO       OFF
SET TERMOUT    ON
SET TRIMSPOOL  ON
SET LINESIZE   200
SET PAGESIZE   200
SET NEWPAGE    1
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';

-- Presentation knobs (top_n / anomaly_days / show_esm). Loaded here so a bare
-- `@report/report.sql` never prompts / hangs on an undefined substitution var.
-- To change them, edit report/defaults.sql (the single source of truth).
@@report/defaults.sql

-- --------------------------------------------------------------------
-- Resolve identity, config knobs, ESM availability, report path (once).
-- --------------------------------------------------------------------
COLUMN cap_db   NEW_VALUE cap_db   NOPRINT
COLUMN cap_host NEW_VALUE cap_host NOPRINT
COLUMN cap_user NEW_VALUE cap_user NOPRINT
COLUMN cap_gen  NEW_VALUE cap_gen  NOPRINT
COLUMN cap_path NEW_VALUE cap_path NOPRINT
COLUMN dtf_warn NEW_VALUE dtf_warn NOPRINT
COLUMN dtf_crit NEW_VALUE dtf_crit NOPRINT
COLUMN cpu_sat  NEW_VALUE cpu_sat  NOPRINT
COLUMN esm_ok   NEW_VALUE esm_ok   NOPRINT
COLUMN esm_file NEW_VALUE esm_file NOPRINT

-- Identity via SYS_CONTEXT (no catalog/v$ privileges needed, so the report
-- runs from any monitoring schema, not just one with SELECT_CATALOG_ROLE).
SELECT SYS_CONTEXT('USERENV','DB_NAME')
         || CASE WHEN TO_NUMBER(SYS_CONTEXT('USERENV','CON_ID')) NOT IN (0,1)
                 THEN ' / ' || SYS_CONTEXT('USERENV','CON_NAME') ELSE '' END  AS cap_db,
       SYS_CONTEXT('USERENV','SERVER_HOST')                                   AS cap_host,
       USER                                                                  AS cap_user,
       TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI:SS TZR')                      AS cap_gen,
       'reports/cap_report_'
         || REGEXP_REPLACE(SYS_CONTEXT('USERENV','DB_NAME'),'[^A-Za-z0-9]+','_') || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MI') || '.txt'                       AS cap_path
FROM   dual;

SELECT (SELECT cfg_value FROM cap_config WHERE cfg_name='dtf_warn')    AS dtf_warn,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='dtf_crit')    AS dtf_crit,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='cpu_sat_pct') AS cpu_sat,
       (SELECT COUNT(*)  FROM cap_ml_model WHERE status='OK')          AS esm_ok
FROM   dual;

-- Section 6 dispatch:
--   show_esm='N'                    -> skip stub (note only)
--   show_esm='AUTO' and 0 OK models -> skip stub (nothing to compare yet)
--   otherwise                       -> full ESM-vs-REGR compare
SELECT CASE WHEN UPPER('&show_esm') = 'N'
              OR (UPPER('&show_esm') = 'AUTO' AND &esm_ok = 0)
            THEN 'report/sections/06_esm_skip.sql'
            ELSE 'report/sections/06_esm_compare.sql'
       END AS esm_file
FROM   dual;

SPOOL &cap_path

PROMPT ================================================================================
PROMPT  AWR CAPACITY PREDICTIONS -- capacity + anomaly report
PROMPT ================================================================================
PROMPT  Database : &cap_db
PROMPT  Host     : &cap_host
PROMPT  Schema   : &cap_user
PROMPT  Generated: &cap_gen
PROMPT  Config   : days-to-full WARN<=&dtf_warn CRIT<=&dtf_crit ; CPU saturation &cpu_sat%
PROMPT  Tier 2   : &esm_ok OML ESM model(s) trained (OK)
PROMPT ................................................................................
PROMPT  NOTE: forecasts degrade loudly on short AWR retention -- watch TRAIN_N and
PROMPT        QUALITY. INSUFFICIENT_HISTORY means fewer than the configured minimum
PROMPT        training days; raise DBMS_WORKLOAD_REPOSITORY retention for real trends.
PROMPT ================================================================================

@@report/sections/01_days_to_full.sql
@@report/sections/02_tbspc_forecast.sql
@@report/sections/03_tbspc_anomalies.sql
@@report/sections/04_cpu_trend.sql
@@report/sections/05_cpu_anomalies.sql
@@&esm_file

PROMPT
PROMPT ================================================================================
PROMPT  End of report -- read-only run, no database objects created or modified.
PROMPT ================================================================================

SPOOL OFF

PROMPT
PROMPT Report written to: &cap_path
PROMPT
