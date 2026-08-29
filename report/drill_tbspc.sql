--
-- report/drill_tbspc.sql -- hand-auditable drill-down for ONE tablespace series.
-- =====================================================================
-- Prints (and spools) everything needed to re-derive a tablespace forecast and
-- its anomaly flags with a pocket calculator:
--   1. the fit header      -- slope / intercept / R2 / slope CI / days-to-full
--   2. the daily series    -- actual, fitted, residual, day-over-day delta, gap
--                             and the CAPA_* anomaly baseline for that day
--   3. residual footer     -- SUM(resid) ~ 0 and resid_se = sqrt(SSE/(n-2)),
--                             the number the M9.1 prediction bands are built on
--   4. anomaly arithmetic  -- one spelled-out line per flagged day
--
-- READ-ONLY: SELECTs against CAPD_/CAPF_/CAPA_/CAPR_ views only (never
-- DBA_HIST_*), no DML/DDL, no database object created or modified.
--
-- Run from the REPO ROOT (SQL*Plus @@ resolves against the outermost caller):
--   SQL> @report/drill_tbspc.sql SYSAUX
--   SQL> @report/drill_tbspc.sql SYSAUX 2482321331     -- one container only
-- The tablespace name is REQUIRED; without it the script prints usage and
-- every query below degrades to zero rows (no prompt, no hang). Both
-- positional arguments are optional to SQL*Plus thanks to the
-- "COLUMN n NEW_VALUE n + zero-row SELECT" trick, and are UNDEFINEd at the
-- end so a later argument-less @-call in the same session cannot inherit them.
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

-- --------------------------------------------------------------------
-- Optional positional arguments without prompting.
-- COLUMN n NEW_VALUE n + a SELECT that returns NO rows leaves an argument
-- that WAS passed untouched and defines an argument that was NOT passed as
-- empty -- so &1 / &2 below always resolve and SQL*Plus never prompts.
-- Sentinels ('?' / '0') keep the rest of the script free of NULL handling:
--   drill_ts  = '?' -> no tablespace given  -> usage + zero rows everywhere
--   drill_con = '0' -> no con_dbid given    -> all containers
-- --------------------------------------------------------------------
COLUMN 1 NEW_VALUE 1
COLUMN 2 NEW_VALUE 2
SET TERMOUT OFF
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;

COLUMN drill_ts_c  NEW_VALUE drill_ts  NOPRINT
COLUMN drill_con_c NEW_VALUE drill_con NOPRINT
COLUMN cap_path    NEW_VALUE cap_path  NOPRINT
SELECT NVL(UPPER(TRIM('&1')), '?')                                  AS drill_ts_c,
       CASE WHEN REGEXP_LIKE(TRIM('&2'), '^[0-9]+$')
            THEN TRIM('&2') ELSE '0' END                            AS drill_con_c
FROM   dual;

SELECT 'reports/cap_drill_'
       || REGEXP_REPLACE(CASE WHEN '&drill_ts' = '?' THEN 'USAGE' ELSE '&drill_ts' END,
                         '[^A-Za-z0-9]+', '_')
       || '_' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '.txt' AS cap_path
FROM   dual;

-- Knobs echoed in the headers; every one of them also drives the views below.
COLUMN k_train NEW_VALUE k_train NOPRINT
COLUMN k_min   NEW_VALUE k_min   NOPRINT
COLUMN k_madk  NEW_VALUE k_madk  NOPRINT
COLUMN k_madw  NEW_VALUE k_madw  NOPRINT
COLUMN k_floor NEW_VALUE k_floor NOPRINT
COLUMN k_hist  NEW_VALUE k_hist  NOPRINT
-- FM/RTRIM: a raw NUMBER NEW_VALUE keeps SQL*Plus's right-justified width
-- ("WARN<=        90"), and FM on a whole number leaves a trailing "3." behind.
SELECT TO_CHAR(MAX(CASE WHEN cfg_name = 'train_days'      THEN cfg_value END), 'FM9999990') AS k_train,
       TO_CHAR(MAX(CASE WHEN cfg_name = 'min_train_days'  THEN cfg_value END), 'FM9999990') AS k_min,
       RTRIM(TO_CHAR(MAX(CASE WHEN cfg_name = 'mad_k'     THEN cfg_value END), 'FM9999990.9'), '.') AS k_madk,
       TO_CHAR(MAX(CASE WHEN cfg_name = 'mad_window_days' THEN cfg_value END), 'FM9999990') AS k_madw,
       TO_CHAR(MAX(CASE WHEN cfg_name = 'abs_floor_bytes' THEN cfg_value END)
               / 1048576, 'FM99999990.0')                                                   AS k_floor,
       TO_CHAR(MAX(CASE WHEN cfg_name = 'tbspc_min_hist'  THEN cfg_value END), 'FM9999990') AS k_hist
FROM   cap_config;
SET TERMOUT ON

UNDEFINE 1
UNDEFINE 2

SPOOL &cap_path

PROMPT ================================================================================
PROMPT  CAPACITY DRILL-DOWN  --  tablespace &drill_ts
PROMPT ================================================================================
PROMPT  Read-only. Every number below is reproducible by hand from the columns shown.
PROMPT  Fit window = the last &k_train days (CAP_CONFIG train_days), day index
PROMPT  DAY_N = day_dt - DATE '2020-01-01' exactly as ddl/30_forecast_views.sql uses.
PROMPT ================================================================================

-- Usage when the (required) tablespace argument is missing. No exit / no
-- prompt: every query below is keyed on '&drill_ts' = '?' and returns nothing.
BEGIN
    IF '&drill_ts' = '?' THEN
        -- No leading indentation: SERVEROUTPUT's default WORD_WRAPPED format
        -- strips leading blanks, so alignment has to be built with dots.
        DBMS_OUTPUT.PUT_LINE('Usage: @report/drill_tbspc.sql <TABLESPACE_NAME> [con_dbid]');
        DBMS_OUTPUT.PUT_LINE('-- run from the repo root, with the suite installed.');
        DBMS_OUTPUT.PUT_LINE('<TABLESPACE_NAME> .. required, case-insensitive (e.g. SYSAUX).');
        DBMS_OUTPUT.PUT_LINE('[con_dbid] ......... optional; omit for every container.');
        DBMS_OUTPUT.PUT_LINE('List the candidates with: SELECT db_pdb, tablespace_name,');
        DBMS_OUTPUT.PUT_LINE('con_dbid FROM capr_tbspc_days_to_full;');
        DBMS_OUTPUT.PUT_LINE('No tablespace given -- nothing to drill into.');
    END IF;
END;
/

PROMPT
PROMPT == 1. FIT HEADER (CAPF_TBSPC_FORECAST + CAPR_CONTAINER) ==
PROMPT    FIT(day_n) = ICEPT_MIB + MIB/DAY * day_n. R2/QUALITY grade the fit
PROMPT    (INSUFFICIENT_HISTORY = TRAIN_N below min_train_days &k_min).
PROMPT    +-CI = 95% half-width on the slope; WORST/BEST = days-to-full at the
PROMPT    fast/slow edge of that CI (BEST empty = might never fill).

COLUMN db_pdb    FORMAT A18            HEADING 'DB/PDB'
COLUMN last_day  FORMAT A10            HEADING 'LAST_DAY'
COLUMN train_n   FORMAT 99990          HEADING 'TRAIN_N'
COLUMN slope_mib FORMAT 999990.000     HEADING 'MIB/DAY'
COLUMN slope_ci  FORMAT 99990.000      HEADING '+-CI'
COLUMN icept_mib FORMAT 99999990.00    HEADING 'ICEPT_MIB'
COLUMN r2        FORMAT 90.9999        HEADING 'R2'
COLUMN cur_gib   FORMAT 999990.00      HEADING 'CUR_GIB'
COLUMN limit_gib FORMAT 999990.00      HEADING 'LIMIT_GIB'
COLUMN pct_used  FORMAT 990.0          HEADING 'PCT'
COLUMN dtf       FORMAT 9999990        HEADING 'DAYS_FULL'
COLUMN dtf_lo    FORMAT 9999990        HEADING 'WORST'
COLUMN dtf_hi    FORMAT 9999990        HEADING 'BEST'
COLUMN quality   FORMAT A20            HEADING 'QUALITY'

SELECT NVL(c.db_pdb, TO_CHAR(f.con_dbid))     AS db_pdb,
       TO_CHAR(f.last_day, 'YYYY-MM-DD')      AS last_day,
       f.train_n                              AS train_n,
       f.slope_bpd     / 1048576              AS slope_mib,
       f.slope_ci_bpd  / 1048576              AS slope_ci,
       f.icept         / 1048576              AS icept_mib,
       f.r2                                   AS r2,
       f.cur_used      / 1073741824           AS cur_gib,
       f.limit_bytes   / 1073741824           AS limit_gib,
       f.pct_used                             AS pct_used,
       f.days_to_full                         AS dtf,
       f.days_to_full_lo                      AS dtf_lo,
       f.days_to_full_hi                      AS dtf_hi,
       f.quality                              AS quality
FROM   capf_tbspc_forecast f
LEFT   JOIN capr_container c
  ON   c.dbid = f.dbid AND c.con_dbid = f.con_dbid
WHERE  f.tablespace_name = '&drill_ts'
  AND  ('&drill_con' = '0' OR TO_CHAR(f.con_dbid) = '&drill_con')
ORDER  BY f.con_dbid;

PROMPT
PROMPT == 2. DAILY SERIES OVER THE FIT WINDOW (CAPD_TBSPC_DELTA + CAPA_TBSPC_ANOM) ==
PROMPT    FIT_MIB = ICEPT_MIB + MIB/DAY * DAY_N ; RESID_MIB = USED_MIB - FIT_MIB.
PROMPT    DELTA_MIB = change since the previous SAMPLED day, GAP = calendar days
PROMPT    since it (>1 across an AWR gap), RATE = DELTA/GAP -- the anomaly input.
PROMPT    MED/SIGMA/THR are the trailing &k_madw-day baseline the flag is judged against.

COLUMN day_dt    FORMAT A10            HEADING 'DAY'
COLUMN day_n     FORMAT 999990         HEADING 'DAY_N'
COLUMN used_gib  FORMAT 999990.000     HEADING 'USED_GIB'
COLUMN used_mib  FORMAT 999999990.000  HEADING 'USED_MIB'
COLUMN fit_mib   FORMAT 999999990.000  HEADING 'FIT_MIB'
COLUMN resid_mib FORMAT 99999990.000   HEADING 'RESID_MIB'
COLUMN delta_mib FORMAT 99999990.000   HEADING 'DELTA_MIB'
COLUMN gap       FORMAT 990            HEADING 'GAP'
COLUMN rate_mib  FORMAT 99999990.00    HEADING 'RATE_MIB/D'
COLUMN med_mib   FORMAT 99999990.00    HEADING 'MED_MIB/D'
COLUMN sig_mib   FORMAT 9999990.00     HEADING 'SIGMA'
COLUMN thr_mib   FORMAT 99999990.00    HEADING 'THR_MIB/D'
COLUMN z         FORMAT 99990.0        HEADING 'Z'
COLUMN flag      FORMAT A4             HEADING 'FLAG'

WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'train_days' THEN cfg_value END) AS train_days
        FROM   cap_config
     ),
     f AS (
        SELECT dbid, con_dbid, tablespace_name, last_day, slope_bpd, icept
        FROM   capf_tbspc_forecast
        WHERE  tablespace_name = '&drill_ts'
          AND  ('&drill_con' = '0' OR TO_CHAR(con_dbid) = '&drill_con')
     )
SELECT TO_CHAR(d.day_dt, 'YYYY-MM-DD')                    AS day_dt,
       d.day_dt - DATE '2020-01-01'                       AS day_n,
       d.used_bytes / 1073741824                          AS used_gib,
       d.used_bytes / 1048576                             AS used_mib,
       (f.icept + f.slope_bpd * (d.day_dt - DATE '2020-01-01')) / 1048576  AS fit_mib,
       (d.used_bytes - (f.icept + f.slope_bpd * (d.day_dt - DATE '2020-01-01'))) / 1048576
                                                          AS resid_mib,
       d.used_delta_bytes / 1048576                       AS delta_mib,
       d.day_gap                                          AS gap,
       d.used_rate_bpd    / 1048576                       AS rate_mib,
       a.median_rate_bpd  / 1048576                       AS med_mib,
       a.mad_sigma        / 1048576                       AS sig_mib,
       a.threshold_bpd    / 1048576                       AS thr_mib,
       a.robust_z                                         AS z,
       a.anomaly_flag                                     AS flag
FROM   f
JOIN   capd_tbspc_delta d
  ON   d.dbid = f.dbid AND d.con_dbid = f.con_dbid
 AND   d.tablespace_name = f.tablespace_name
CROSS  JOIN cfg
LEFT   JOIN capa_tbspc_anom a
  ON   a.dbid = d.dbid AND a.con_dbid = d.con_dbid
 AND   a.tablespace_name = d.tablespace_name AND a.day_dt = d.day_dt
WHERE  d.day_dt > f.last_day - cfg.train_days
ORDER  BY d.con_dbid, d.day_dt;

PROMPT
PROMPT == 2b. RESIDUAL FOOTER -- the basis of the M9.1 prediction bands ==
PROMPT    OLS guarantees SUM_RESID = 0 (rounding aside). SSE = SUM(RESID^2),
PROMPT    RESID_SE = sqrt(SSE/(n-2)), TVAL = 1.96 + 2.4/(n-2), and
PROMPT    CI_CALC = TVAL * RESID_SE / sqrt(SXX) must equal the view's CI_VIEW.

COLUMN n          FORMAT 99990           HEADING 'N'
COLUMN sum_resid  FORMAT 999990.000000   HEADING 'SUM_RESID_MIB'
COLUMN sse_mib2   FORMAT 999999990.00    HEADING 'SSE_MIB2'
COLUMN resid_se   FORMAT 9999990.000     HEADING 'RESID_SE_MIB'
COLUMN tval       FORMAT 90.0000         HEADING 'TVAL'
COLUMN sxx        FORMAT 999999999990    HEADING 'SXX'
COLUMN ci_calc    FORMAT 999990.000000   HEADING 'CI_CALC_MIB'
COLUMN ci_view    FORMAT 999990.000000   HEADING 'CI_VIEW_MIB'

WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'train_days' THEN cfg_value END) AS train_days
        FROM   cap_config
     ),
     f AS (
        SELECT dbid, con_dbid, tablespace_name, last_day, slope_bpd, icept, slope_ci_bpd
        FROM   capf_tbspc_forecast
        WHERE  tablespace_name = '&drill_ts'
          AND  ('&drill_con' = '0' OR TO_CHAR(con_dbid) = '&drill_con')
     ),
     r AS (
        SELECT d.con_dbid,
               d.day_dt - DATE '2020-01-01'                                          AS day_n,
               d.used_bytes,
               d.used_bytes - (f.icept + f.slope_bpd * (d.day_dt - DATE '2020-01-01')) AS resid,
               f.slope_ci_bpd
        FROM   f
        JOIN   capd_tbspc_daily d
          ON   d.dbid = f.dbid AND d.con_dbid = f.con_dbid
         AND   d.tablespace_name = f.tablespace_name
        CROSS  JOIN cfg
        WHERE  d.day_dt > f.last_day - cfg.train_days
     )
SELECT COUNT(*)                                                          AS n,
       SUM(resid) / 1048576                                              AS sum_resid,
       SUM(resid * resid) / 1048576 / 1048576                            AS sse_mib2,
       SQRT(SUM(resid * resid) / NULLIF(COUNT(*) - 2, 0)) / 1048576      AS resid_se,
       1.96 + 2.4 / NULLIF(COUNT(*) - 2, 0)                              AS tval,
       REGR_SXX(used_bytes, day_n)                                       AS sxx,
       (1.96 + 2.4 / NULLIF(COUNT(*) - 2, 0))
         * SQRT(SUM(resid * resid) / NULLIF(COUNT(*) - 2, 0))
         / SQRT(NULLIF(REGR_SXX(used_bytes, day_n), 0)) / 1048576        AS ci_calc,
       MAX(slope_ci_bpd) / 1048576                                       AS ci_view
FROM   r
GROUP  BY con_dbid
ORDER  BY con_dbid;

PROMPT
PROMPT == 3. ANOMALY ARITHMETIC (CAPA_TBSPC_ANOM, flagged days in the fit window) ==
PROMPT    Knobs: mad_k=&k_madk, mad_window_days=&k_madw, abs_floor_bytes=&k_floor MiB,
PROMPT    tbspc_min_hist=&k_hist (min trailing obs). Baseline EXCLUDES the day itself, so a spike
PROMPT    can never inflate its own threshold. All values in MiB/day.

COLUMN arith FORMAT A190 HEADING 'FLAGGED DAY'

WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'train_days' THEN cfg_value END) AS train_days,
               MAX(CASE WHEN cfg_name = 'mad_k'      THEN cfg_value END) AS mad_k
        FROM   cap_config
     ),
     f AS (
        SELECT dbid, con_dbid, tablespace_name, last_day
        FROM   capf_tbspc_forecast
        WHERE  tablespace_name = '&drill_ts'
          AND  ('&drill_con' = '0' OR TO_CHAR(con_dbid) = '&drill_con')
     ),
     hits AS (
        SELECT a.con_dbid, a.day_dt, a.anomaly_flag, a.n_hist, a.robust_z,
               a.used_rate_bpd / 1048576   AS rate_mib,
               a.median_rate_bpd / 1048576 AS med_mib,
               a.dev_bpd / 1048576         AS dev_mib,
               a.mad_sigma / 1048576       AS sig_mib,
               a.threshold_bpd / 1048576   AS thr_mib,
               cfg.mad_k                   AS mad_k,
               cfg.mad_k * a.mad_sigma / 1048576 AS ksig_mib
        FROM   f
        JOIN   capa_tbspc_anom a
          ON   a.dbid = f.dbid AND a.con_dbid = f.con_dbid
         AND   a.tablespace_name = f.tablespace_name
        CROSS  JOIN cfg
        WHERE  a.day_dt > f.last_day - cfg.train_days
          AND  a.anomaly_flag IS NOT NULL
     )
SELECT arith FROM (
    SELECT 1 AS ord, day_dt AS srt,
           TO_CHAR(day_dt, 'YYYY-MM-DD') || ' ' || RPAD(anomaly_flag, 5)
           || 'rate ' || TO_CHAR(rate_mib, 'FM999999990.000')
           || ' - median ' || TO_CHAR(med_mib, 'FM999999990.000')
           || ' = dev ' || TO_CHAR(dev_mib, 'FM999999990.000')
           || ' | threshold = GREATEST(k ' || TO_CHAR(mad_k, 'FM990.00')
           || ' * sigma ' || TO_CHAR(sig_mib, 'FM999999990.000')
           || ' = ' || TO_CHAR(ksig_mib, 'FM999999990.000')
           || ', floor &k_floor) = ' || TO_CHAR(thr_mib, 'FM999999990.000')
           || ' | z = ' || NVL(TO_CHAR(robust_z, 'FM99990.00'), 'n/a')
           || ' | n_hist ' || TO_CHAR(n_hist)                                   AS arith
    FROM   hits
    UNION  ALL
    SELECT 2, NULL, '(no day flagged in this window)'
    FROM   dual
    WHERE  NOT EXISTS (SELECT 1 FROM hits)
      AND  '&drill_ts' != '?'
)
ORDER  BY ord, srt;

PROMPT
PROMPT ================================================================================
PROMPT  End of drill-down -- read-only run, no database objects created or modified.
PROMPT ================================================================================

SPOOL OFF

PROMPT
PROMPT Drill-down written to: &cap_path
PROMPT

-- Leave no positional leftovers: a later argument-less @report/drill_*.sql in
-- the same session must not silently inherit this run's arguments.
UNDEFINE drill_ts
UNDEFINE drill_con
UNDEFINE cap_path
UNDEFINE k_train
UNDEFINE k_min
UNDEFINE k_madk
UNDEFINE k_madw
UNDEFINE k_floor
UNDEFINE k_hist
CLEAR COLUMNS
