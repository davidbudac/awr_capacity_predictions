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
--   SQL> @report/report.sql 10 30 AUTO 42424242 42424243   -- one container
--   SQL> @report/report.sql - - - - - SNAPSHOT             -- from the last refresh run
-- Arguments are positional and optional (M7.6); each one omitted falls back to
-- report/defaults.sql. show_esm is AUTO | Y | N.
--   [dbid] [con_dbid]  scope: every section shows only that database / that
--                      container, and the top_n bounds rank inside the scope.
--                      Omit them, or pass '-', for every database.
--   [source]           LIVE (default): evaluate the CAPR views now.
--                      SNAPSHOT: the alert list reads CAPR_ALERTS_LATEST, the
--                      section 1 and 7 tables read CAPR_FIT_HISTORY of the
--                      newest OK refresh run, and the coverage line is the
--                      CAPR_COVERAGE roll-up that run kept on CAP_RUN (fast:
--                      no live CAPR_ALERTS or CAPR_COVERAGE evaluation).
--                      The other sections stay live.
--   DEFINE timing = Y  before the run: wall time per section in the spool.
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
--   @report/report.sql [top_n] [anomaly_days] [show_esm] [dbid] [con_dbid] [source]
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
COLUMN 4 NEW_VALUE 4 NOPRINT
COLUMN 5 NEW_VALUE 5 NOPRINT
COLUMN 6 NEW_VALUE 6 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3",
       NULL AS "4", NULL AS "5", NULL AS "6" FROM dual WHERE 1 = 0;

-- DEFINE timing = Y before the run wraps the header and every section in a
-- SQL*Plus TIMING START / STOP pair: wall time per section, in the spool.
-- Otherwise both includes are report/sections/timing_off.sql (a no-op).
-- Same zero-row trick for an undefined name.
COLUMN cap_tm NEW_VALUE timing NOPRINT
SELECT NULL AS cap_tm FROM dual WHERE 1 = 0;
COLUMN cap_tm_start NEW_VALUE cap_tm_start NOPRINT
COLUMN cap_tm_stop  NEW_VALUE cap_tm_stop  NOPRINT
SELECT CASE WHEN UPPER(TRIM('&timing')) = 'Y' THEN 'report/sections/timing_start.sql'
            ELSE 'report/sections/timing_off.sql' END AS cap_tm_start,
       CASE WHEN UPPER(TRIM('&timing')) = 'Y' THEN 'report/sections/timing_stop.sql'
            ELSE 'report/sections/timing_off.sql' END AS cap_tm_stop
FROM   dual;

-- Effective knobs = positional argument, else the defaults.sql value. An
-- omitted argument is the empty string, and '' IS NULL in Oracle, so NVL
-- picks the default; '-' does the same, so a caller can skip an argument to
-- reach a later one. Re-DEFINEs the same three names the sections already use.
COLUMN eff_top_n NEW_VALUE top_n        NOPRINT
COLUMN eff_anom  NEW_VALUE anomaly_days NOPRINT
COLUMN eff_esm   NEW_VALUE show_esm     NOPRINT
SELECT NVL(NULLIF(TRIM('&1'), '-'), '&top_n')                  AS eff_top_n,
       NVL(NULLIF(TRIM('&2'), '-'), '&anomaly_days')           AS eff_anom,
       NVL(NULLIF(UPPER(TRIM('&3')), '-'), UPPER('&show_esm')) AS eff_esm
FROM   dual;

-- Scope and source. cap_sdbid / cap_scon are a number or the literal NULL,
-- so every section filters with
--   (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
-- and an unscoped run reads (NULL IS NULL OR dbid = NULL): always true.
-- Anything but digits (omitted, '-') means every database.
COLUMN eff_sdbid NEW_VALUE cap_sdbid NOPRINT
COLUMN eff_scon  NEW_VALUE cap_scon  NOPRINT
COLUMN eff_src   NEW_VALUE cap_src   NOPRINT
SELECT NVL(REGEXP_SUBSTR(TRIM('&4'), '^[0-9]+$'), 'NULL')                  AS eff_sdbid,
       NVL(REGEXP_SUBSTR(TRIM('&5'), '^[0-9]+$'), 'NULL')                  AS eff_scon,
       CASE WHEN UPPER(TRIM('&6')) = 'SNAPSHOT' THEN 'SNAPSHOT' ELSE 'LIVE' END AS eff_src
FROM   dual;
SET TERMOUT ON
DEFINE cap_tm_lbl = header
@@&cap_tm_start

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
COLUMN esm_failed NEW_VALUE esm_failed NOPRINT
COLUMN esm_stale  NEW_VALUE esm_stale  NOPRINT
COLUMN mad_w      NEW_VALUE mad_w      NOPRINT
COLUMN dow_w      NEW_VALUE dow_w      NOPRINT
COLUMN esm_file NEW_VALUE esm_file NOPRINT
COLUMN min_gb   NEW_VALUE min_gb   NOPRINT
COLUMN ts_total NEW_VALUE ts_total NOPRINT
COLUMN ts_shown NEW_VALUE ts_shown NOPRINT
COLUMN cap_scope_lbl NEW_VALUE cap_scope_lbl NOPRINT
COLUMN cap_src_lbl   NEW_VALUE cap_src_lbl   NOPRINT
COLUMN cap_snap_run  NEW_VALUE cap_snap_run  NOPRINT
COLUMN sec1_file     NEW_VALUE sec1_file     NOPRINT
COLUMN sec7_file     NEW_VALUE sec7_file     NOPRINT

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
SELECT TO_CHAR(c.dtf_warn,                                                    'FM9999990') AS dtf_warn,
       TO_CHAR(c.dtf_crit,                                                    'FM9999990') AS dtf_crit,
       TO_CHAR(c.cpu_sat_pct,                                                 'FM9999990') AS cpu_sat,
       TO_CHAR(c.nearfull_warn_pct,                                           'FM9999990') AS nf_warn,
       TO_CHAR(c.nearfull_crit_pct,                                           'FM9999990') AS nf_crit,
       -- Tier 2 health: FORECAST models only (backtest twins never reach a
       -- forecast). CAPF_ESM_HEALTH_SUMMARY has one row per container.
       TO_CHAR(h.n_ok,                                                        'FM9999990') AS esm_ok,
       TO_CHAR(h.n_failed,                                                    'FM9999990') AS esm_failed,
       TO_CHAR(h.n_stale,                                                     'FM9999990') AS esm_stale,
       -- report_min_gb may be fractional, so keep the decimals and strip the
       -- trailing point FM leaves behind on a whole number (1. -> 1).
       RTRIM(TO_CHAR(c.report_min_gb, 'FM9999990.999'), '.')                                    AS min_gb,
       TO_CHAR((SELECT COUNT(*)  FROM capr_tbspc_rank
                WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
                  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)),               'FM9999990') AS ts_total,
       -- M7.4: how many of them sections 2 / 6a will actually print, i.e. the
       -- exact WHERE those sections apply -- so the header states the truth
       -- even when top_n is larger than the number of tablespaces. The rank
       -- is re-numbered inside the scope, as the sections do.
       TO_CHAR((SELECT COUNT(*)
                FROM  (SELECT is_reportable,
                              ROW_NUMBER() OVER (ORDER BY rank_report) AS s_rank
                       FROM   capr_tbspc_rank
                       WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
                         AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon))
                WHERE is_reportable = 'Y' AND s_rank <= &top_n),                    'FM9999990') AS ts_shown,
       TO_CHAR(c.mad_window_days,                                             'FM9999990') AS mad_w,
       TO_CHAR(c.dow_weeks,                                                   'FM9999990') AS dow_w
FROM   cap_cfg c
CROSS  JOIN (SELECT NVL(SUM(n_ok), 0) AS n_ok, NVL(SUM(n_failed), 0) AS n_failed,
                    NVL(SUM(n_stale), 0) AS n_stale
             FROM   capf_esm_health_summary) h;

-- Defaults first, so a failing lookup below (suite not installed) cannot
-- leave a variable undefined and make SQL*Plus prompt for it.
DEFINE sec1_file     = 'report/sections/01_days_to_full.sql'
DEFINE sec7_file     = 'report/sections/07_series.sql'
DEFINE cap_snap_run  = 0
DEFINE cap_scope_lbl = 'see the arguments'
DEFINE cap_src_lbl   = '&cap_src'

-- Scope label (CAPR_CONTAINER names the container), source label, and the
-- section 1 / 7 files for the source. The SNAPSHOT run is the newest OK
-- live refresh run (CAPR_RUNS.last_ok_run_id).
SELECT CASE WHEN &cap_sdbid IS NULL AND &cap_scon IS NULL THEN 'every database in this schema'
            ELSE TRIM(CASE WHEN &cap_sdbid IS NOT NULL THEN 'dbid ' || '&cap_sdbid' END
                      || CASE WHEN &cap_scon IS NOT NULL THEN ' con_dbid ' || '&cap_scon' END)
                 || ' (' || NVL((SELECT LISTAGG(db_pdb, ', ') WITHIN GROUP (ORDER BY db_pdb)
                                 FROM   capr_container
                                 WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
                                   AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)),
                                'no such container') || ')'
       END                                                                    AS cap_scope_lbl,
       NVL((SELECT TO_CHAR(MAX(last_ok_run_id)) FROM capr_runs), '0')         AS cap_snap_run,
       CASE WHEN '&cap_src' = 'SNAPSHOT'
            THEN NVL((SELECT 'SNAPSHOT, from refresh run ' || r.run_id || ' at '
                             || TO_CHAR(r.started_at, 'YYYY-MM-DD HH24:MI')
                             || ' (as of ' || TO_CHAR(r.as_of_day, 'YYYY-MM-DD') || ')'
                      FROM   capr_runs r
                      WHERE  r.run_id = r.last_ok_run_id),
                     'SNAPSHOT, but no OK refresh run exists yet: sections 0, 1 and 7 are empty')
            ELSE 'LIVE (CAPR views evaluated now)'
       END                                                                    AS cap_src_lbl,
       CASE WHEN '&cap_src' = 'SNAPSHOT' THEN 'report/sections/01_days_to_full_snap.sql'
            ELSE 'report/sections/01_days_to_full.sql' END                    AS sec1_file,
       CASE WHEN '&cap_src' = 'SNAPSHOT' THEN 'report/sections/07_series_snap.sql'
            ELSE 'report/sections/07_series.sql' END                          AS sec7_file
FROM   dual;

-- Section 6 dispatch:
--   show_esm='N'                    -> skip stub (note only)
--   show_esm='AUTO' and 0 OK FORECAST models -> skip stub (nothing to compare yet)
--   otherwise                       -> full ESM-vs-REGR compare
SELECT CASE WHEN UPPER('&show_esm') = 'N'
              OR (UPPER('&show_esm') = 'AUTO' AND &esm_ok = 0)
            THEN 'report/sections/06_esm_skip.sql'
            ELSE 'report/sections/06_esm_compare.sql'
       END AS esm_file
FROM   dual;

-- reports/ is gitignored, so a fresh clone does not have it.
HOST mkdir -p reports
SPOOL &cap_path
@@&cap_tm_stop

PROMPT ================================================================================
PROMPT  AWR CAPACITY PREDICTIONS -- capacity + anomaly report
PROMPT ================================================================================
PROMPT  Database : &cap_db
PROMPT  Host     : &cap_host
PROMPT  Schema   : &cap_user
PROMPT  Generated: &cap_gen
PROMPT  Config   : days-to-full WARN<=&dtf_warn CRIT<=&dtf_crit ; CPU saturation &cpu_sat%
PROMPT  Tier 2   : OML ESM forecast models &esm_ok ok, &esm_failed failed, &esm_stale stale
PROMPT  Scope    : &cap_scope_lbl
PROMPT  Source   : &cap_src_lbl
PROMPT ................................................................................
PROMPT  NOTE: forecasts degrade loudly on short AWR retention -- watch TRAIN_N and
PROMPT        QUALITY. INSUFFICIENT_HISTORY means fewer than the configured minimum
PROMPT        training days; raise DBMS_WORKLOAD_REPOSITORY retention for real trends.
PROMPT ================================================================================

DEFINE cap_tm_lbl = s0
@@&cap_tm_start
@@report/sections/00_at_a_glance.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s1
@@&cap_tm_start
@@&sec1_file
@@&cap_tm_stop
DEFINE cap_tm_lbl = s2
@@&cap_tm_start
@@report/sections/02_tbspc_forecast.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s3
@@&cap_tm_start
@@report/sections/03_tbspc_anomalies.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s4
@@&cap_tm_start
@@report/sections/04_cpu_trend.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s5
@@&cap_tm_start
@@report/sections/05_cpu_anomalies.sql
@@&cap_tm_stop
DEFINE cap_tm_lbl = s6
@@&cap_tm_start
@@&esm_file
@@&cap_tm_stop
DEFINE cap_tm_lbl = s7
@@&cap_tm_start
@@&sec7_file
@@&cap_tm_stop

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
UNDEFINE 4
UNDEFINE 5
UNDEFINE 6

PROMPT
PROMPT Report written to: &cap_path
PROMPT
