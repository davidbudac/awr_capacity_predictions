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
--   SQL> @report/report.sql                  -- defaults from report/defaults.sql
--   SQL> @report/report.sql 5                -- top_n=5
--   SQL> @report/report.sql 5 7 N            -- top_n / anomaly_days / show_esm
-- Arguments are positional and optional (M7.6); each one omitted falls back to
-- report/defaults.sql. show_esm is AUTO | Y | N.
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
-- To change them for every run, edit report/defaults.sql (the single source of
-- truth); to change one run, pass them positionally (M7.6):
--   @report/report.sql [top_n] [anomaly_days] [show_esm]
@@report/defaults.sql

-- M7.6: make &1..&3 safe to reference whether or not they were passed. A
-- COLUMN ... NEW_VALUE whose query returns NO rows defines the variable as
-- empty instead of leaving it undefined (an undefined &1 would PROMPT, and a
-- non-interactive caller's next heredoc line would be eaten as the answer);
-- an argument that WAS passed keeps its value -- SQL*Plus only reassigns
-- NEW_VALUE on a fetched row. Verified both ways on 19c.
SET TERMOUT OFF
COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3" FROM dual WHERE 1 = 0;

-- Effective knobs = positional argument, else the defaults.sql value. An
-- omitted argument is the empty string, and '' IS NULL in Oracle, so NVL
-- picks the default. Re-DEFINEs the same three names the sections already use.
COLUMN eff_top_n NEW_VALUE top_n        NOPRINT
COLUMN eff_anom  NEW_VALUE anomaly_days NOPRINT
COLUMN eff_esm   NEW_VALUE show_esm     NOPRINT
SELECT NVL('&1', '&top_n')               AS eff_top_n,
       NVL('&2', '&anomaly_days')        AS eff_anom,
       NVL(UPPER('&3'), UPPER('&show_esm')) AS eff_esm
FROM   dual;
SET TERMOUT ON

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
COLUMN nf_warn  NEW_VALUE nf_warn  NOPRINT
COLUMN nf_crit  NEW_VALUE nf_crit  NOPRINT
COLUMN esm_ok   NEW_VALUE esm_ok   NOPRINT
COLUMN esm_file NEW_VALUE esm_file NOPRINT
COLUMN min_gb   NEW_VALUE min_gb   NOPRINT
COLUMN ts_total NEW_VALUE ts_total NOPRINT
COLUMN ts_shown NEW_VALUE ts_shown NOPRINT

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

-- M7.7: TO_CHAR(...,'FM...') every knob. A NUMBER column's NEW_VALUE keeps
-- SQL*Plus's right-justified display width, so a raw cfg_value would print as
-- "WARN<=        90" wherever a PROMPT interpolates it.
SELECT TO_CHAR((SELECT cfg_value FROM cap_config WHERE cfg_name='dtf_warn'),         'FM9999990') AS dtf_warn,
       TO_CHAR((SELECT cfg_value FROM cap_config WHERE cfg_name='dtf_crit'),         'FM9999990') AS dtf_crit,
       TO_CHAR((SELECT cfg_value FROM cap_config WHERE cfg_name='cpu_sat_pct'),      'FM9999990') AS cpu_sat,
       TO_CHAR((SELECT cfg_value FROM cap_config WHERE cfg_name='nearfull_warn_pct'),'FM9999990') AS nf_warn,
       TO_CHAR((SELECT cfg_value FROM cap_config WHERE cfg_name='nearfull_crit_pct'),'FM9999990') AS nf_crit,
       TO_CHAR((SELECT COUNT(*)  FROM cap_ml_model WHERE status='OK'),               'FM9999990') AS esm_ok,
       -- report_min_gb may be fractional, so keep the decimals and strip the
       -- trailing point FM leaves behind on a whole number (1. -> 1).
       RTRIM(TO_CHAR((SELECT cfg_value FROM cap_config WHERE cfg_name='report_min_gb'),
                     'FM9999990.999'), '.')                                                       AS min_gb,
       TO_CHAR((SELECT COUNT(*)  FROM capr_tbspc_forecast),                          'FM9999990') AS ts_total,
       -- M7.4: how many of them sections 2 / 6a will actually print, i.e. the
       -- exact WHERE those sections apply -- so the header states the truth
       -- even when top_n is larger than the number of tablespaces.
       TO_CHAR((SELECT COUNT(*)  FROM capr_tbspc_forecast
                WHERE is_reportable = 'Y' AND rank_report <= &top_n),               'FM9999990') AS ts_shown
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

@@report/sections/00_at_a_glance.sql
@@report/sections/01_days_to_full.sql
@@report/sections/02_tbspc_forecast.sql
@@report/sections/03_tbspc_anomalies.sql
@@report/sections/04_cpu_trend.sql
@@report/sections/05_cpu_anomalies.sql
@@&esm_file
@@report/sections/07_series.sql

PROMPT
PROMPT ================================================================================
PROMPT  End of report -- read-only run, no database objects created or modified.
PROMPT ================================================================================

SPOOL OFF

-- M7.6: positional arguments stay DEFINEd for the rest of the SQL*Plus
-- session, so drop them -- otherwise a following `@report/report_html.sql`
-- with no arguments would silently inherit this run's.
UNDEFINE 1
UNDEFINE 2
UNDEFINE 3

PROMPT
PROMPT Report written to: &cap_path
PROMPT
