--
-- ddl/30_forecast_views.sql -- CAPF_* Tier 1 (pure-SQL linear) forecasts.
-- =====================================================================
-- Ordinary-least-squares linear fits via Oracle's built-in REGR_* aggregates,
-- so every projection is reproducible by hand from slope + intercept. All
-- tuning comes from CAP_CONFIG through a one-row `cfg` CTE.
--
--   CAPF_TBSPC_FORECAST -- per tablespace: bytes/day slope, R^2, +30/90/180/365
--                          day projections with 95% prediction bands
--                          (proj_*_lo/hi), days_to_full with a worst/best-case
--                          range (days_to_full_lo/hi, M9.1), recent-vs-full
--                          acceleration ratio, and a quality grade.
--   CAPF_CPU_TREND      -- per CPU metric (host busy% avg/p95/peak-window,
--                          DB CPU sec, DB CPU % of cores avg/p95): slope, R^2,
--                          projections (+95% bands), days_to_saturation
--                          (+lo/hi range), quality.
--
-- day_n is an integer day index off a fixed epoch (DATE '2020-01-01') rather
-- than a raw date number, so slopes are in "per day" and are stable/auditable.
--
-- quality grades (checked in priority order):
--   INSUFFICIENT_HISTORY  REGR_COUNT < min_train_days
--   FLAT                  slope = 0 (no growth) OR R^2 IS NULL. NOTE: Oracle's
--                         REGR_R2 returns 1 (not NULL) when y has zero variance
--                         and x does not, so a truly flat series is detected by
--                         slope = 0, not by a NULL R^2. R^2 IS NULL only happens
--                         when x has zero variance (single distinct day), which
--                         INSUFFICIENT_HISTORY already covers.
--   LOW_CONFIDENCE        R^2 < r2_gate
--   OK                    otherwise
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPF_TBSPC_FORECAST
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_tbspc_forecast AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'train_days'     THEN cfg_value END) AS train_days,
               MAX(CASE WHEN cfg_name = 'recent_days'    THEN cfg_value END) AS recent_days,
               MAX(CASE WHEN cfg_name = 'min_train_days' THEN cfg_value END) AS min_train_days,
               MAX(CASE WHEN cfg_name = 'r2_gate'        THEN cfg_value END) AS r2_gate
        FROM   cap_config
     ),
     d AS (
        SELECT dbid, con_dbid, tablespace_name, day_dt,
               day_dt - DATE '2020-01-01' AS day_n,
               used_bytes, limit_bytes
        FROM   capd_tbspc_daily
     ),
     b AS (
        SELECT dbid, con_dbid, tablespace_name, MAX(day_dt) AS last_day
        FROM   d
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     dd AS (
        SELECT d.dbid, d.con_dbid, d.tablespace_name, d.day_dt, d.day_n,
               d.used_bytes, d.limit_bytes,
               b.last_day,
               b.last_day - DATE '2020-01-01' AS last_day_n
        FROM   d
        JOIN   b ON b.dbid = d.dbid AND b.con_dbid = d.con_dbid
                AND b.tablespace_name = d.tablespace_name
     ),
     fit AS (
        SELECT dd.dbid, dd.con_dbid, dd.tablespace_name,
               MAX(dd.last_day)                  AS last_day,
               MAX(dd.last_day_n)                AS last_day_n,
               REGR_SLOPE(dd.used_bytes, dd.day_n)     AS slope,
               REGR_INTERCEPT(dd.used_bytes, dd.day_n) AS icept,
               REGR_R2(dd.used_bytes, dd.day_n)        AS r2,
               REGR_COUNT(dd.used_bytes, dd.day_n)     AS n,
               -- Sums for the M9.1 prediction intervals (all hand-auditable):
               REGR_SXX(dd.used_bytes, dd.day_n)       AS sxx,
               REGR_SYY(dd.used_bytes, dd.day_n)       AS syy,
               REGR_SXY(dd.used_bytes, dd.day_n)       AS sxy,
               REGR_AVGX(dd.used_bytes, dd.day_n)      AS xbar
        FROM   dd CROSS JOIN cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
        GROUP  BY dd.dbid, dd.con_dbid, dd.tablespace_name
     ),
     -- ------------------------------------------------------------------
     -- M9.1 prediction-interval arithmetic (95%), classic OLS closed forms:
     --   SSE       = SYY - SXY^2/SXX          (residual sum of squares)
     --   resid_se  = sqrt(SSE / (n-2))        (residual standard error)
     --   tval      = 1.96 + 2.4/(n-2)         (t_{.975,df} approximation, good
     --                                         to ~1% for df>=10; min_train_days
     --                                         guarantees df >= 12 before a
     --                                         forecast is trusted)
     --   half_h    = tval * resid_se * sqrt(1 + 1/n + (x0-xbar)^2/SXX)
     --               at x0 = last_day_n + h   (NEW-observation interval)
     --   slope_ci  = tval * resid_se / sqrt(SXX)   (half-width of slope CI)
     -- GREATEST(0,...) guards a tiny negative SSE from floating rounding.
     -- A perfectly linear (or flat) series has SSE = 0, so its bands collapse
     -- onto the point projection -- asserted by the FIX_LINEAR fixture.
     -- ------------------------------------------------------------------
     stat AS (
        SELECT f.*,
               CASE WHEN f.n > 2 AND f.sxx > 0
                    THEN SQRT(GREATEST(0, f.syy - f.sxy * f.sxy / f.sxx) / (f.n - 2))
               END AS resid_se,
               CASE WHEN f.n > 2 THEN 1.96 + 2.4 / (f.n - 2) END AS tval
        FROM   fit f
     ),
     -- CASE-guarded: resid_se is NULL exactly when sxx = 0 (single-day series)
     -- or n <= 2, and the sxx divisions must not be evaluated then (ORA-01476).
     band AS (
        SELECT s.*,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n +  30 - s.xbar, 2) / s.sxx) END AS half_30,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n +  90 - s.xbar, 2) / s.sxx) END AS half_90,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n + 180 - s.xbar, 2) / s.sxx) END AS half_180,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n + 365 - s.xbar, 2) / s.sxx) END AS half_365,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se / SQRT(s.sxx) END                                                     AS slope_ci
        FROM   stat s
     ),
     rfit AS (
        SELECT dd.dbid, dd.con_dbid, dd.tablespace_name,
               REGR_SLOPE(dd.used_bytes, dd.day_n)  AS recent_slope,
               REGR_COUNT(dd.used_bytes, dd.day_n)  AS recent_n
        FROM   dd CROSS JOIN cfg
        WHERE  dd.day_dt > dd.last_day - cfg.recent_days
        GROUP  BY dd.dbid, dd.con_dbid, dd.tablespace_name
     ),
     cur AS (
        SELECT dbid, con_dbid, tablespace_name,
               MAX(used_bytes)  KEEP (DENSE_RANK LAST ORDER BY day_dt) AS cur_used,
               MAX(limit_bytes) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS limit_bytes
        FROM   d
        GROUP  BY dbid, con_dbid, tablespace_name
     )
SELECT f.dbid,
       f.con_dbid,
       f.tablespace_name,
       f.last_day,
       f.n                                                AS train_n,
       c.cur_used,
       c.limit_bytes,
       -- How full RIGHT NOW, independent of any fit: the report's "near-full
       -- now" ranking keys off this so a 97%-full tablespace is never hidden
       -- by a LOW_CONFIDENCE/INSUFFICIENT_HISTORY fit (M7.1).
       CASE WHEN c.limit_bytes > 0
            THEN ROUND(100 * c.cur_used / c.limit_bytes, 1)
       END                                                AS pct_used,
       f.slope                                            AS slope_bpd,
       f.icept,
       f.r2,
       f.icept + f.slope * (f.last_day_n + 30)            AS proj_30_bytes,
       f.icept + f.slope * (f.last_day_n + 90)            AS proj_90_bytes,
       f.icept + f.slope * (f.last_day_n + 180)           AS proj_180_bytes,
       f.icept + f.slope * (f.last_day_n + 365)           AS proj_365_bytes,
       -- M9.1: 95% prediction bands on each projection ...
       f.icept + f.slope * (f.last_day_n + 30)  - f.half_30   AS proj_30_lo,
       f.icept + f.slope * (f.last_day_n + 30)  + f.half_30   AS proj_30_hi,
       f.icept + f.slope * (f.last_day_n + 90)  - f.half_90   AS proj_90_lo,
       f.icept + f.slope * (f.last_day_n + 90)  + f.half_90   AS proj_90_hi,
       f.icept + f.slope * (f.last_day_n + 180) - f.half_180  AS proj_180_lo,
       f.icept + f.slope * (f.last_day_n + 180) + f.half_180  AS proj_180_hi,
       f.icept + f.slope * (f.last_day_n + 365) - f.half_365  AS proj_365_lo,
       f.icept + f.slope * (f.last_day_n + 365) + f.half_365  AS proj_365_hi,
       f.slope_ci                                             AS slope_ci_bpd,
       CASE WHEN f.slope > 0
            THEN FLOOR((c.limit_bytes - c.cur_used) / f.slope)
       END                                                AS days_to_full,
       -- ... and a range on days_to_full from the slope's 95% CI.
       -- lo = WORST case (fastest plausible growth, fills soonest).
       -- hi = BEST case, NULL when the slow edge of the CI is <= 0
       -- ("might never fill at the low end of plausible growth").
       -- NB: no trailing semicolon in these comments -- SQL*Plus would
       -- treat it as the statement terminator mid-view.
       CASE WHEN f.slope > 0 AND f.slope_ci IS NOT NULL
            THEN FLOOR((c.limit_bytes - c.cur_used) / (f.slope + f.slope_ci))
       END                                                AS days_to_full_lo,
       CASE WHEN f.slope > 0 AND f.slope_ci IS NOT NULL AND f.slope - f.slope_ci > 0
            THEN FLOOR((c.limit_bytes - c.cur_used) / (f.slope - f.slope_ci))
       END                                                AS days_to_full_hi,
       r.recent_slope                                     AS recent_slope_bpd,
       CASE WHEN f.slope <> 0
            THEN r.recent_slope / f.slope
       END                                                AS accel_ratio,
       CASE WHEN f.n  < cfg.min_train_days     THEN 'INSUFFICIENT_HISTORY'
            WHEN f.slope = 0 OR f.r2 IS NULL   THEN 'FLAT'
            WHEN f.r2 < cfg.r2_gate            THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                                AS quality
FROM   band f
JOIN   cur  c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid
             AND c.tablespace_name = f.tablespace_name
LEFT   JOIN rfit r ON r.dbid = f.dbid AND r.con_dbid = f.con_dbid
                  AND r.tablespace_name = f.tablespace_name
CROSS  JOIN cfg;

-- --------------------------------------------------------------------
-- CAPF_CPU_TREND -- one row per (dbid, con_dbid, metric):
--   BUSY_PCT    host busy%, daily time-weighted average   (CAPD_CPU_DAILY)
--   BUSY_P95    host busy%, p95 of the day's snapshot intervals (M10.1:
--               "the busy hour" -- what actually saturates)
--   BUSY_PEAK   host busy% inside the configured peak window (M10.1)
--   DB_CPU_SEC  foreground DB CPU seconds/day               (CAPD_DBTIME_DAILY)
--   DB_CPU_PCT  DB CPU as % of the host's core capacity     (M10.2)
--   DB_CPU_P95  p95 of the per-interval DB CPU %            (M10.2)
-- Every percent-of-capacity metric (everything but DB_CPU_SEC) gets
-- days_to_sat = days until the fitted line crosses cpu_sat_pct; DB_CPU_SEC
-- has no fixed ceiling so its days_to_sat is NULL.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_cpu_trend AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'train_days'     THEN cfg_value END) AS train_days,
               MAX(CASE WHEN cfg_name = 'min_train_days' THEN cfg_value END) AS min_train_days,
               MAX(CASE WHEN cfg_name = 'r2_gate'        THEN cfg_value END) AS r2_gate,
               MAX(CASE WHEN cfg_name = 'cpu_sat_pct'    THEN cfg_value END) AS cpu_sat_pct
        FROM   cap_config
     ),
     src AS (
        SELECT dbid, con_dbid, 'BUSY_PCT'   AS metric, day_dt, busy_pct      AS val
        FROM   capd_cpu_daily    WHERE busy_pct      IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'BUSY_P95'   AS metric, day_dt, busy_p95      AS val
        FROM   capd_cpu_daily    WHERE busy_p95      IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'BUSY_PEAK'  AS metric, day_dt, busy_peak_pct AS val
        FROM   capd_cpu_daily    WHERE busy_peak_pct IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_SEC' AS metric, day_dt, db_cpu_sec    AS val
        FROM   capd_dbtime_daily WHERE db_cpu_sec    IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_PCT' AS metric, day_dt, db_cpu_pct    AS val
        FROM   capd_dbtime_daily WHERE db_cpu_pct    IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_P95' AS metric, day_dt, db_cpu_p95_pct AS val
        FROM   capd_dbtime_daily WHERE db_cpu_p95_pct IS NOT NULL
     ),
     d AS (
        SELECT s.*, day_dt - DATE '2020-01-01' AS day_n FROM src s
     ),
     b AS (
        SELECT dbid, con_dbid, metric, MAX(day_dt) AS last_day
        FROM   d GROUP BY dbid, con_dbid, metric
     ),
     dd AS (
        SELECT d.dbid, d.con_dbid, d.metric, d.day_dt, d.day_n, d.val,
               b.last_day, b.last_day - DATE '2020-01-01' AS last_day_n
        FROM   d JOIN b ON b.dbid = d.dbid AND b.con_dbid = d.con_dbid AND b.metric = d.metric
     ),
     fit AS (
        SELECT dd.dbid, dd.con_dbid, dd.metric,
               MAX(dd.last_day)                AS last_day,
               MAX(dd.last_day_n)              AS last_day_n,
               REGR_SLOPE(dd.val, dd.day_n)    AS slope,
               REGR_INTERCEPT(dd.val, dd.day_n) AS icept,
               REGR_R2(dd.val, dd.day_n)       AS r2,
               REGR_COUNT(dd.val, dd.day_n)    AS n,
               REGR_SXX(dd.val, dd.day_n)      AS sxx,
               REGR_SYY(dd.val, dd.day_n)      AS syy,
               REGR_SXY(dd.val, dd.day_n)      AS sxy,
               REGR_AVGX(dd.val, dd.day_n)     AS xbar
        FROM   dd CROSS JOIN cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
        GROUP  BY dd.dbid, dd.con_dbid, dd.metric
     ),
     -- M9.1 interval arithmetic -- same closed forms as CAPF_TBSPC_FORECAST
     -- (see the comment block there for the formulas and guards).
     stat AS (
        SELECT f.*,
               CASE WHEN f.n > 2 AND f.sxx > 0
                    THEN SQRT(GREATEST(0, f.syy - f.sxy * f.sxy / f.sxx) / (f.n - 2))
               END AS resid_se,
               CASE WHEN f.n > 2 THEN 1.96 + 2.4 / (f.n - 2) END AS tval
        FROM   fit f
     ),
     band AS (
        SELECT s.*,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n + 30 - s.xbar, 2) / s.sxx) END AS half_30,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se * SQRT(1 + 1/s.n + POWER(s.last_day_n + 90 - s.xbar, 2) / s.sxx) END AS half_90,
               CASE WHEN s.resid_se IS NOT NULL THEN
                 s.tval * s.resid_se / SQRT(s.sxx) END                                                    AS slope_ci
        FROM   stat s
     ),
     cur AS (
        SELECT dbid, con_dbid, metric,
               MAX(val) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS cur_val
        FROM   d GROUP BY dbid, con_dbid, metric
     )
SELECT f.dbid,
       f.con_dbid,
       f.metric,
       f.last_day,
       f.n                                          AS train_n,
       c.cur_val,
       f.slope                                      AS slope_per_day,
       f.r2,
       f.icept + f.slope * (f.last_day_n + 30)      AS proj_30,
       f.icept + f.slope * (f.last_day_n + 90)      AS proj_90,
       -- M9.1: 95% prediction bands + days_to_sat range (same semantics as
       -- CAPF_TBSPC_FORECAST: lo = worst case / soonest, hi = best case,
       -- hi NULL when the slow edge of the slope CI is <= 0).
       f.icept + f.slope * (f.last_day_n + 30) - f.half_30 AS proj_30_lo,
       f.icept + f.slope * (f.last_day_n + 30) + f.half_30 AS proj_30_hi,
       f.icept + f.slope * (f.last_day_n + 90) - f.half_90 AS proj_90_lo,
       f.icept + f.slope * (f.last_day_n + 90) + f.half_90 AS proj_90_hi,
       f.slope_ci                                   AS slope_ci_per_day,
       -- GREATEST(0,...): if current busy% already exceeds the saturation
       -- threshold, report 0 (saturated now) rather than a negative "days".
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.slope > 0
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - c.cur_val) / f.slope))
       END                                          AS days_to_sat,
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.slope > 0 AND f.slope_ci IS NOT NULL
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - c.cur_val) / (f.slope + f.slope_ci)))
       END                                          AS days_to_sat_lo,
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.slope > 0 AND f.slope_ci IS NOT NULL
                 AND f.slope - f.slope_ci > 0
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - c.cur_val) / (f.slope - f.slope_ci)))
       END                                          AS days_to_sat_hi,
       CASE WHEN f.n  < cfg.min_train_days     THEN 'INSUFFICIENT_HISTORY'
            WHEN f.slope = 0 OR f.r2 IS NULL   THEN 'FLAT'
            WHEN f.r2 < cfg.r2_gate            THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                          AS quality
FROM   band f
JOIN   cur c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid AND c.metric = f.metric
CROSS  JOIN cfg;
