--
-- report/drill_cpu.sql -- hand-auditable drill-down for ONE CPU metric series.
-- =====================================================================
-- The CPU twin of report/drill_tbspc.sql. Prints (and spools) everything
-- needed to re-derive a CPU trend and its anomaly flags by hand:
--   1. the fit header      -- slope / intercept / R2 / slope CI / days-to-sat
--   2. the daily series    -- actual, fitted, residual, day-over-day delta,
--                             gap, the day's p95/max/peak-window companions,
--                             and both day baselines (trailing, same weekday)
--   3. residual footer     -- SUM(resid) ~ 0 and resid_se = sqrt(SSE/(n-2)),
--                             the number the M9.1 prediction bands are built on;
--                             residuals are against the deseasoned fit input
--                             when cpu_deseason = 1, as the view fits it
--   4. anomaly arithmetic  -- one spelled-out line per flagged (day, mode),
--                             then the flagged hours vs the hour-of-week baseline
--
-- METRICS (as in CAPF_CPU_TREND / ddl/30_forecast_views.sql `src`):
--   BUSY_PCT   host busy%, daily time-weighted average   (CAPD_CPU_DAILY)
--   BUSY_P95   host busy%, p95 of the day's intervals    (CAPD_CPU_DAILY)
--   BUSY_PEAK  host busy% inside the peak-hour window    (CAPD_CPU_DAILY)
--   DB_CPU_SEC foreground DB CPU seconds/day             (CAPD_DBTIME_DAILY)
--   DB_CPU_PCT DB CPU as % of host core capacity         (CAPD_DBTIME_DAILY)
--   DB_CPU_P95 p95 of the per-interval DB CPU %          (CAPD_DBTIME_DAILY)
-- Anomalies are scored for BUSY_PCT and DB_CPU_PCT only (per day and per
-- hour), so the anomaly columns and section 3 read "n/a" for the other four.
--
-- READ-ONLY: SELECTs against CAPD_/CAPF_/CAPA_/CAPR_ views only (never
-- DBA_HIST_*), no DML/DDL, no database object created or modified.
--
-- Run from the REPO ROOT (SQL*Plus @@ resolves against the outermost caller):
--   SQL> @report/drill_cpu.sql                     -- BUSY_PCT, all containers
--   SQL> @report/drill_cpu.sql BUSY_P95
--   SQL> @report/drill_cpu.sql DB_CPU_PCT 2482321331
-- Both positional arguments are optional (the "COLUMN n NEW_VALUE n +
-- zero-row SELECT" trick), so a bare call never prompts or hangs, and both
-- are UNDEFINEd at the end so a later argument-less @-call cannot inherit them.
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
-- Optional positional arguments without prompting (see drill_tbspc.sql).
--   drill_metric -- &1 upper-cased, default BUSY_PCT
--   drill_con    -- &2 when numeric, else '0' = every container
-- --------------------------------------------------------------------
COLUMN 1 NEW_VALUE 1
COLUMN 2 NEW_VALUE 2
SET TERMOUT OFF
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;

COLUMN drill_met_c NEW_VALUE drill_metric NOPRINT
COLUMN drill_con_c NEW_VALUE drill_con    NOPRINT
COLUMN cap_path    NEW_VALUE cap_path     NOPRINT
SELECT NVL(UPPER(TRIM('&1')), 'BUSY_PCT')                           AS drill_met_c,
       CASE WHEN REGEXP_LIKE(TRIM('&2'), '^[0-9]+$')
            THEN TRIM('&2') ELSE '0' END                            AS drill_con_c
FROM   dual;

SELECT 'reports/cap_drill_'
       || REGEXP_REPLACE('&drill_metric', '[^A-Za-z0-9]+', '_')
       || '_' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '.txt' AS cap_path
FROM   dual;

COLUMN k_train NEW_VALUE k_train NOPRINT
COLUMN k_min   NEW_VALUE k_min   NOPRINT
COLUMN k_madk  NEW_VALUE k_madk  NOPRINT
COLUMN k_dow   NEW_VALUE k_dow   NOPRINT
COLUMN k_mmad  NEW_VALUE k_mmad  NOPRINT
COLUMN k_hist  NEW_VALUE k_hist  NOPRINT
COLUMN k_madw  NEW_VALUE k_madw  NOPRINT
COLUMN k_thist NEW_VALUE k_thist NOPRINT
COLUMN k_mmadh NEW_VALUE k_mmadh NOPRINT
COLUMN k_sat   NEW_VALUE k_sat   NOPRINT
SELECT TO_CHAR(c.train_days,                 'FM9999990')         AS k_train,
       TO_CHAR(c.min_train_days,             'FM9999990')         AS k_min,
       -- RTRIM '.': FM strips the trailing zero of a whole number and leaves "3."
       RTRIM(TO_CHAR(c.mad_k,                'FM9999990.9'), '.') AS k_madk,
       TO_CHAR(c.dow_weeks,                  'FM9999990')         AS k_dow,
       RTRIM(TO_CHAR(c.cpu_min_mad_pct,      'FM9999990.9'), '.') AS k_mmad,
       TO_CHAR(c.weekly_min_hist,            'FM9999990')         AS k_hist,
       TO_CHAR(c.mad_window_days,            'FM9999990')         AS k_madw,
       TO_CHAR(c.trailing_min_hist,          'FM9999990')         AS k_thist,
       RTRIM(TO_CHAR(c.cpu_min_mad_pct_hour, 'FM9999990.9'), '.') AS k_mmadh,
       TO_CHAR(c.cpu_sat_pct,                'FM9999990')         AS k_sat
FROM   cap_cfg c;
SET TERMOUT ON

UNDEFINE 1
UNDEFINE 2

-- reports/ is gitignored, so a fresh clone does not have it.
HOST mkdir -p reports
SPOOL &cap_path

PROMPT ================================================================================
PROMPT  CAPACITY DRILL-DOWN  --  CPU metric &drill_metric
PROMPT ================================================================================
PROMPT  Read-only. Every number below is reproducible by hand from the columns shown.
PROMPT  Fit window = the COMPLETE days (is_complete = Y) from TRAIN_START to
PROMPT  LAST_DAY, inside the last &k_train days (CAP_CONFIG train_days). Partial,
PROMPT  restart and outage days are left out here exactly as the view leaves them out.
PROMPT  Day index DAY_N = day_dt - DATE '2020-01-01' exactly as ddl/30_forecast_views.sql uses.
PROMPT  Saturation threshold cpu_sat_pct = &k_sat (percent metrics only).
PROMPT ================================================================================

-- Unknown metric: name the six valid ones. No exit / no prompt -- every query
-- below simply matches nothing.
BEGIN
    IF '&drill_metric' NOT IN ('BUSY_PCT','BUSY_P95','BUSY_PEAK',
                               'DB_CPU_SEC','DB_CPU_PCT','DB_CPU_P95') THEN
        -- No leading indentation: SERVEROUTPUT's default WORD_WRAPPED format
        -- strips leading blanks.
        DBMS_OUTPUT.PUT_LINE('Unknown metric "&drill_metric".');
        DBMS_OUTPUT.PUT_LINE('Usage: @report/drill_cpu.sql [metric] [con_dbid]');
        DBMS_OUTPUT.PUT_LINE('metric ... BUSY_PCT (default) | BUSY_P95 | BUSY_PEAK |');
        DBMS_OUTPUT.PUT_LINE('.......... DB_CPU_SEC | DB_CPU_PCT | DB_CPU_P95');
        DBMS_OUTPUT.PUT_LINE('con_dbid . optional; omit for every container.');
    END IF;
END;
/

PROMPT
PROMPT == 1. FIT HEADER (CAPF_CPU_TREND + CAPR_CONTAINER) ==
PROMPT    FIT(day_n) = ICEPT + SLOPE/DAY * day_n (CAPF_CPU_TREND.icept, the fitted
PROMPT    intercept, on the deseasoned input when cpu_deseason = 1). Projections
PROMPT    start from ANCHOR instead (CAPF_CPU_TREND.anchor_value, the median of the
PROMPT    last shift_days complete days): +h days = ANCHOR + SLOPE/DAY * h, and
PROMPT    DAYS_SAT counts from ANCHOR too.
PROMPT    R2/QUALITY grade the fit (INSUFFICIENT_HISTORY = TRAIN_N < &k_min).
PROMPT    +-CI = 95% half-width on the slope; WORST/BEST = days-to-saturation at
PROMPT    the fast/slow edge of that CI (BEST empty = might never saturate).

COLUMN db_pdb    FORMAT A18            HEADING 'DB/PDB'
COLUMN metric    FORMAT A11            HEADING 'METRIC'
COLUMN last_day  FORMAT A10            HEADING 'LAST_DAY'
COLUMN tr_start  FORMAT A11            HEADING 'TRAIN_START'
COLUMN train_n   FORMAT 99990          HEADING 'TRAIN_N'
COLUMN cur_val   FORMAT 99999990.000   HEADING 'CURRENT'
COLUMN slope_day FORMAT 9999990.00000  HEADING 'SLOPE/DAY'
COLUMN slope_ci  FORMAT 999990.00000   HEADING '+-CI'
COLUMN icept     FORMAT 9999999990.000 HEADING 'ICEPT'
COLUMN r2        FORMAT 90.9999        HEADING 'R2'
COLUMN dts       FORMAT 9999990        HEADING 'DAYS_SAT'
COLUMN dts_lo    FORMAT 9999990        HEADING 'WORST'
COLUMN dts_hi    FORMAT 9999990        HEADING 'BEST'
COLUMN quality   FORMAT A20            HEADING 'QUALITY'
COLUMN anchor    FORMAT 99999990.000   HEADING 'ANCHOR'

SELECT NVL(c.db_pdb, TO_CHAR(f.con_dbid))                       AS db_pdb,
       f.metric                                                 AS metric,
       TO_CHAR(f.last_day, 'YYYY-MM-DD')                        AS last_day,
       TO_CHAR(f.train_start, 'YYYY-MM-DD')                     AS tr_start,
       f.train_n                                                AS train_n,
       f.cur_val                                                AS cur_val,
       f.slope_per_day                                          AS slope_day,
       f.slope_ci_per_day                                       AS slope_ci,
       f.icept                                                  AS icept,
       f.r2                                                     AS r2,
       f.days_to_sat                                            AS dts,
       f.days_to_sat_lo                                         AS dts_lo,
       f.days_to_sat_hi                                         AS dts_hi,
       f.quality                                                AS quality,
       f.anchor_value                                           AS anchor
FROM   capf_cpu_trend f
LEFT   JOIN capr_container c
  ON   c.dbid = f.dbid AND c.con_dbid = f.con_dbid
WHERE  f.metric = '&drill_metric'
  AND  ('&drill_con' = '0' OR TO_CHAR(f.con_dbid) = '&drill_con')
ORDER  BY f.con_dbid;

PROMPT
PROMPT == 2. DAILY SERIES OVER THE FIT WINDOW (CAPD_CPU_DAILY / CAPD_DBTIME_DAILY) ==
PROMPT    FIT = ICEPT + SLOPE/DAY * DAY_N ; RESID = FIT_IN - FIT ; DELTA = change
PROMPT    since the previous sampled day, GAP = calendar days since it.
PROMPT    FIT_IN = the value the fit saw: VALUE when cpu_deseason = 0, else VALUE
PROMPT    - AVG(same day type) + AVG(all) over the fit window (day type = weekday
PROMPT    or Saturday / Sunday), exactly as CAPF_CPU_TREND deseasons it.
PROMPT    P95/MAX/PEAK are the same day's companions (busy_p95/busy_max/
PROMPT    busy_peak_pct for BUSY_*, db_cpu_p95/max/peak_pct for DB_CPU_*).
PROMPT    N_IVL = snapshot intervals that survived the restart/reset guard.
PROMPT    Incomplete days (is_complete = N) are not listed: the fit skips them.
PROMPT    Each day is judged against two baselines (CAPA_ANOM baseline_mode = ...):
PROMPT    TRL_* = TRAILING, the previous &k_madw days; DOW_* = SAME_DOW, the same
PROMPT    weekday over the previous &k_dow weeks. MED = baseline median, Z = robust z.
PROMPT    Only BUSY_PCT and DB_CPU_PCT are scored; the other metrics read n/a.

COLUMN day_dt  FORMAT A10           HEADING 'DAY'
COLUMN day_n   FORMAT 999990        HEADING 'DAY_N'
COLUMN val     FORMAT 99999990.000  HEADING 'VALUE'
COLUMN v_p95   FORMAT 9999990.00    HEADING 'P95'
COLUMN v_max   FORMAT 9999990.00    HEADING 'MAX'
COLUMN v_peak  FORMAT 9999990.00    HEADING 'PEAK'
COLUMN fit_in  FORMAT 99999990.000  HEADING 'FIT_IN'
COLUMN fit     FORMAT 99999990.000  HEADING 'FIT'
COLUMN resid   FORMAT 9999990.000   HEADING 'RESID'
COLUMN delta   FORMAT 9999990.000   HEADING 'DELTA'
COLUMN gap     FORMAT 990           HEADING 'GAP'
COLUMN n_ivl   FORMAT 9990          HEADING 'N_IVL'
COLUMN trl_med  FORMAT 99990.00   HEADING 'TRL_MED'  NULL 'n/a'
COLUMN trl_z    FORMAT 99990.0    HEADING 'TRL_Z'    NULL 'n/a'
COLUMN trl_flag FORMAT A8         HEADING 'TRL_FLAG' NULL 'n/a'
COLUMN dow_med  FORMAT 99990.00   HEADING 'DOW_MED'  NULL 'n/a'
COLUMN dow_z    FORMAT 99990.0    HEADING 'DOW_Z'    NULL 'n/a'
COLUMN dow_flag FORMAT A8         HEADING 'DOW_FLAG' NULL 'n/a'

-- Metric -> source column, mirroring the `src` CTE of CAPF_CPU_TREND,
-- complete days only, as the view fits them. Only the branch owning the
-- requested metric contributes rows.
WITH src AS (
        SELECT dbid, con_dbid, day_dt, n_intervals,
               CASE '&drill_metric' WHEN 'BUSY_PCT'  THEN busy_pct
                                    WHEN 'BUSY_P95'  THEN busy_p95
                                    WHEN 'BUSY_PEAK' THEN busy_peak_pct END AS val,
               busy_p95, busy_max, busy_peak_pct
        FROM   capd_cpu_daily
        WHERE  '&drill_metric' IN ('BUSY_PCT','BUSY_P95','BUSY_PEAK')
          AND  is_complete = 'Y'
        UNION  ALL
        SELECT dbid, con_dbid, day_dt, n_intervals,
               CASE '&drill_metric' WHEN 'DB_CPU_SEC' THEN db_cpu_sec
                                    WHEN 'DB_CPU_PCT' THEN db_cpu_pct
                                    WHEN 'DB_CPU_P95' THEN db_cpu_p95_pct END,
               db_cpu_p95_pct, db_cpu_max_pct, db_cpu_peak_pct
        FROM   capd_dbtime_daily
        WHERE  '&drill_metric' IN ('DB_CPU_SEC','DB_CPU_PCT','DB_CPU_P95')
          AND  is_complete = 'Y'
     ),
     -- LAG over the WHOLE series, then filter to the fit window, so the first
     -- printed day still shows its true delta / gap.
     s AS (
        SELECT x.*,
               x.day_dt - DATE '2020-01-01' AS day_n,
               x.val - LAG(x.val)
                 OVER (PARTITION BY x.dbid, x.con_dbid ORDER BY x.day_dt) AS d_val,
               x.day_dt - LAG(x.day_dt)
                 OVER (PARTITION BY x.dbid, x.con_dbid ORDER BY x.day_dt) AS day_gap
        FROM   src x
        WHERE  x.val IS NOT NULL
     ),
     f AS (
        SELECT dbid, con_dbid, metric, last_day, train_start, slope_per_day, icept
        FROM   capf_cpu_trend
        WHERE  metric = '&drill_metric'
          AND  ('&drill_con' = '0' OR TO_CHAR(con_dbid) = '&drill_con')
     ),
     -- The fit window with the fit input. The AVGs run after the WHERE, so
     -- they cover the window only, as in the view.
     wv AS (
        SELECT s.*, f.icept, f.slope_per_day,
               CASE WHEN cfg.cpu_deseason = 1
                    THEN s.val
                         - AVG(s.val) OVER (PARTITION BY s.dbid, s.con_dbid,
                                            CASE WHEN MOD(TRUNC(s.day_dt) - DATE '1900-01-01', 7) >= 5
                                                 THEN 1 ELSE 0 END)
                         + AVG(s.val) OVER (PARTITION BY s.dbid, s.con_dbid)
                    ELSE s.val
               END AS fval
        FROM   f
        JOIN   s ON s.dbid = f.dbid AND s.con_dbid = f.con_dbid
        CROSS  JOIN cap_cfg cfg
        WHERE  s.day_dt BETWEEN f.train_start AND f.last_day
     )
SELECT TO_CHAR(s.day_dt, 'YYYY-MM-DD')                          AS day_dt,
       s.day_n                                                  AS day_n,
       s.val                                                    AS val,
       s.busy_p95                                               AS v_p95,
       s.busy_max                                               AS v_max,
       s.busy_peak_pct                                          AS v_peak,
       s.fval                                                   AS fit_in,
       s.icept + s.slope_per_day * s.day_n                      AS fit,
       s.fval - (s.icept + s.slope_per_day * s.day_n)           AS resid,
       s.d_val                                                  AS delta,
       s.day_gap                                                AS gap,
       s.n_intervals                                            AS n_ivl,
       -- CAST: pins the datatypes so the FORMAT/NULL 'n/a' widths hold even
       -- when the optimizer describes an outer join that can match nothing
       -- (an unscored metric) as NULL literals one character wide.
       CAST(t.expected     AS NUMBER)                           AS trl_med,
       CAST(t.robust_z     AS NUMBER)                           AS trl_z,
       CAST(t.anomaly_flag AS VARCHAR2(5))                      AS trl_flag,
       CAST(w.expected     AS NUMBER)                           AS dow_med,
       CAST(w.robust_z     AS NUMBER)                           AS dow_z,
       CAST(w.anomaly_flag AS VARCHAR2(5))                      AS dow_flag
FROM   wv s
LEFT   JOIN capa_anom t
  ON   t.dbid = s.dbid AND t.con_dbid = s.con_dbid AND t.kind = 'CPU'
 AND   t.series = '&drill_metric' AND t.ts = s.day_dt
 AND   t.baseline_mode = 'TRAILING'
LEFT   JOIN capa_anom w
  ON   w.dbid = s.dbid AND w.con_dbid = s.con_dbid AND w.kind = 'CPU'
 AND   w.series = '&drill_metric' AND w.ts = s.day_dt
 AND   w.baseline_mode = 'SAME_DOW'
ORDER  BY s.con_dbid, s.day_dt;

PROMPT
PROMPT == 2b. RESIDUAL FOOTER -- the basis of the M9.1 prediction bands ==
PROMPT    Residuals are against FIT_IN (section 2), so under cpu_deseason = 1 they
PROMPT    are those of the deseasoned fit the view made (DESEASON = Y).
PROMPT    OLS guarantees SUM_RESID = 0 (rounding aside). SSE = SUM(RESID^2),
PROMPT    RESID_SE = sqrt(SSE/(n-2)), TVAL = 1.96 + 2.4/(n-2), and
PROMPT    CI_CALC = TVAL * RESID_SE / sqrt(SXX) must equal the view's CI_VIEW.

COLUMN n         FORMAT 99990          HEADING 'N'
COLUMN sum_resid FORMAT 99990.000000   HEADING 'SUM_RESID'
COLUMN sse       FORMAT 999999990.000  HEADING 'SSE'
COLUMN resid_se  FORMAT 999990.0000    HEADING 'RESID_SE'
COLUMN tval      FORMAT 90.0000        HEADING 'TVAL'
COLUMN sxx       FORMAT 999999999990   HEADING 'SXX'
COLUMN ci_calc   FORMAT 99990.00000    HEADING 'CI_CALC'
COLUMN ci_view   FORMAT 99990.00000    HEADING 'CI_VIEW'
COLUMN deseason  FORMAT A8             HEADING 'DESEASON'

WITH src AS (
        SELECT dbid, con_dbid, day_dt,
               CASE '&drill_metric' WHEN 'BUSY_PCT'  THEN busy_pct
                                    WHEN 'BUSY_P95'  THEN busy_p95
                                    WHEN 'BUSY_PEAK' THEN busy_peak_pct END AS val
        FROM   capd_cpu_daily
        WHERE  '&drill_metric' IN ('BUSY_PCT','BUSY_P95','BUSY_PEAK')
          AND  is_complete = 'Y'
        UNION  ALL
        SELECT dbid, con_dbid, day_dt,
               CASE '&drill_metric' WHEN 'DB_CPU_SEC' THEN db_cpu_sec
                                    WHEN 'DB_CPU_PCT' THEN db_cpu_pct
                                    WHEN 'DB_CPU_P95' THEN db_cpu_p95_pct END
        FROM   capd_dbtime_daily
        WHERE  '&drill_metric' IN ('DB_CPU_SEC','DB_CPU_PCT','DB_CPU_P95')
          AND  is_complete = 'Y'
     ),
     f AS (
        SELECT dbid, con_dbid, last_day, train_start, slope_per_day, slope_ci_per_day, icept
        FROM   capf_cpu_trend
        WHERE  metric = '&drill_metric'
          AND  ('&drill_con' = '0' OR TO_CHAR(con_dbid) = '&drill_con')
     ),
     wv AS (
        SELECT s.con_dbid,
               s.day_dt - DATE '2020-01-01' AS day_n,
               s.val,
               CASE WHEN cfg.cpu_deseason = 1
                    THEN s.val
                         - AVG(s.val) OVER (PARTITION BY s.dbid, s.con_dbid,
                                            CASE WHEN MOD(TRUNC(s.day_dt) - DATE '1900-01-01', 7) >= 5
                                                 THEN 1 ELSE 0 END)
                         + AVG(s.val) OVER (PARTITION BY s.dbid, s.con_dbid)
                    ELSE s.val
               END AS fval,
               CASE WHEN cfg.cpu_deseason = 1 THEN 'Y' ELSE 'N' END AS deseason,
               f.icept, f.slope_per_day, f.slope_ci_per_day
        FROM   f
        JOIN   src s ON s.dbid = f.dbid AND s.con_dbid = f.con_dbid
        CROSS  JOIN cap_cfg cfg
        WHERE  s.val IS NOT NULL
          AND  s.day_dt BETWEEN f.train_start AND f.last_day
     ),
     r AS (
        SELECT con_dbid, day_n, val, deseason,
               fval - (icept + slope_per_day * day_n) AS resid,
               slope_ci_per_day
        FROM   wv
     )
SELECT MAX(deseason)                                                AS deseason,
       COUNT(*)                                                     AS n,
       SUM(resid)                                                   AS sum_resid,
       SUM(resid * resid)                                           AS sse,
       SQRT(SUM(resid * resid) / NULLIF(COUNT(*) - 2, 0))           AS resid_se,
       1.96 + 2.4 / NULLIF(COUNT(*) - 2, 0)                          AS tval,
       REGR_SXX(val, day_n)                                          AS sxx,
       (1.96 + 2.4 / NULLIF(COUNT(*) - 2, 0))
         * SQRT(SUM(resid * resid) / NULLIF(COUNT(*) - 2, 0))
         / SQRT(NULLIF(REGR_SXX(val, day_n), 0))                     AS ci_calc,
       MAX(slope_ci_per_day)                                         AS ci_view
FROM   r
GROUP  BY con_dbid
ORDER  BY con_dbid;

PROMPT
PROMPT == 3. ANOMALY ARITHMETIC (flagged days in the fit window, one line per mode) ==
PROMPT    Knobs: mad_k=&k_madk, cpu_min_mad_pct=&k_mmad (sigma floor). TRL baseline = the
PROMPT    previous &k_madw days (trailing_min_hist=&k_thist obs needed), DOW = the same weekday
PROMPT    over the previous &k_dow weeks (weekly_min_hist=&k_hist). Every baseline EXCLUDES
PROMPT    the day itself. Values in percent points.

COLUMN arith FORMAT A190 HEADING 'FLAGGED DAY'

WITH f AS (
        SELECT dbid, con_dbid, last_day, train_start
        FROM   capf_cpu_trend
        WHERE  metric = '&drill_metric'
          AND  ('&drill_con' = '0' OR TO_CHAR(con_dbid) = '&drill_con')
     ),
     modes AS (
        SELECT 'TRAILING' AS bm, 1 AS mrank, 'TRL' AS mshort FROM dual
        UNION ALL SELECT 'SAME_DOW', 2, 'DOW' FROM dual
     ),
     hits AS (
        SELECT a.con_dbid, a.ts AS day_dt, a.dow, m.mrank, m.mshort, a.anomaly_flag,
               a.n_hist, a.robust_z, a.value, a.expected, a.dev, a.mad_sigma,
               a.thr_floor / cfg.mad_k AS floor_sigma, a.threshold, cfg.mad_k
        FROM   f
        JOIN   capa_anom a
          ON   a.dbid = f.dbid AND a.con_dbid = f.con_dbid
         AND   a.kind = 'CPU' AND a.series = '&drill_metric'
        JOIN   modes m
          ON   a.baseline_mode = m.bm
        CROSS  JOIN cap_cfg cfg
        WHERE  a.ts BETWEEN f.train_start AND f.last_day
          AND  a.anomaly_flag IS NOT NULL
     )
SELECT arith FROM (
    SELECT 1 AS ord, day_dt AS srt, mrank,
           TO_CHAR(day_dt, 'YYYY-MM-DD') || ' '
           || DECODE(dow, 0, 'Mon', 1, 'Tue', 2, 'Wed', 3, 'Thu', 4, 'Fri', 5, 'Sat', 'Sun') || ' '
           || mshort || ' ' || RPAD(anomaly_flag, 5)
           || 'value ' || TO_CHAR(value, 'FM99990.000')
           || ' - median ' || TO_CHAR(expected, 'FM99990.000')
           || ' = dev ' || TO_CHAR(dev, 'FM99990.000')
           || ' | threshold = k ' || TO_CHAR(mad_k, 'FM990.00')
           || ' * GREATEST(sigma ' || TO_CHAR(NVL(mad_sigma, 0), 'FM99990.000')
           || ', floor ' || TO_CHAR(floor_sigma, 'FM99990.000')
           || ') = ' || TO_CHAR(threshold, 'FM99990.000')
           || ' | z = ' || NVL(TO_CHAR(robust_z, 'FM99990.00'), 'n/a')
           || ' | n_hist ' || TO_CHAR(n_hist)                                   AS arith
    FROM   hits
    UNION  ALL
    SELECT 2, NULL, NULL,
           CASE WHEN '&drill_metric' IN ('BUSY_PCT', 'DB_CPU_PCT')
                THEN '(no day flagged in this window)'
                ELSE 'n/a -- anomalies are scored for BUSY_PCT and DB_CPU_PCT only;'
                     || ' re-run as @report/drill_cpu.sql BUSY_PCT for anomalies.'
           END
    FROM   dual
    WHERE  NOT EXISTS (SELECT 1 FROM hits)
)
ORDER  BY ord, srt, mrank;

PROMPT
PROMPT == 3b. HOUR-OF-WEEK ANOMALIES (flagged hours in the fit window) ==
PROMPT    Each hour (END hour shown) against the same weekday and hour over the previous
PROMPT    &k_dow weeks (CAPA_ANOM baseline_mode = HOUR_OF_WEEK, weekly_min_hist=&k_hist).
PROMPT    EFF_SIGMA = GREATEST(MAD sigma, cpu_min_mad_pct_hour=&k_mmadh), THRESHOLD = mad_k *
PROMPT    EFF_SIGMA, Z = DEV / EFF_SIGMA. Gap hours are never scored nor baseline.

COLUMN h_day     FORMAT A10          HEADING 'DAY'
COLUMN h_when    FORMAT A9           HEADING 'WHEN'
COLUMN h_flag    FORMAT A4           HEADING 'FLAG'
COLUMN h_val     FORMAT 99990.00     HEADING 'VALUE'
COLUMN h_exp     FORMAT 99990.00     HEADING 'EXPECTED'
COLUMN h_dev     FORMAT S9990.00     HEADING 'DEV'
COLUMN h_sig     FORMAT 99990.000    HEADING 'EFF_SIGMA'
COLUMN h_thr     FORMAT 99990.00     HEADING 'THRESHOLD'
COLUMN h_z       FORMAT S9990.00     HEADING 'Z'
COLUMN h_n       FORMAT 9990         HEADING 'N_HIST'

WITH f AS (
        SELECT dbid, con_dbid, last_day, train_start
        FROM   capf_cpu_trend
        WHERE  metric = '&drill_metric'
          AND  ('&drill_con' = '0' OR TO_CHAR(con_dbid) = '&drill_con')
     )
SELECT TO_CHAR(a.ts, 'YYYY-MM-DD')                                   AS h_day,
       DECODE(a.dow, 0, 'Mon', 1, 'Tue', 2, 'Wed', 3, 'Thu', 4, 'Fri', 5, 'Sat', 'Sun')
         || ' ' || TO_CHAR(a.ts, 'HH24:MI')                          AS h_when,
       a.anomaly_flag                                                AS h_flag,
       a.value                                                       AS h_val,
       a.expected                                                    AS h_exp,
       a.dev                                                         AS h_dev,
       a.eff_sigma                                                   AS h_sig,
       a.threshold                                                   AS h_thr,
       a.robust_z                                                    AS h_z,
       a.n_hist                                                      AS h_n
FROM   f
JOIN   capa_anom a
  ON   a.dbid = f.dbid AND a.con_dbid = f.con_dbid
 AND   a.kind = 'CPU' AND a.series = '&drill_metric'
 AND   a.baseline_mode = 'HOUR_OF_WEEK'
WHERE  TRUNC(a.ts) BETWEEN f.train_start AND f.last_day
  AND  a.anomaly_flag IS NOT NULL
ORDER  BY a.con_dbid, a.ts;

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
UNDEFINE drill_metric
UNDEFINE drill_con
UNDEFINE cap_path
UNDEFINE k_train
UNDEFINE k_min
UNDEFINE k_madk
UNDEFINE k_dow
UNDEFINE k_mmad
UNDEFINE k_hist
UNDEFINE k_madw
UNDEFINE k_thist
UNDEFINE k_mmadh
UNDEFINE k_sat
CLEAR COLUMNS
