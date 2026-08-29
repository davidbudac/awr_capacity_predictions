--
-- ddl/35_series_forecast.sql -- CAPF_SERIES_FORECAST: fixed-ceiling series (M11).
-- =====================================================================
-- The Tier 1 (pure-SQL OLS) forecast for CAPD_SERIES_DAILY, i.e. for
-- PROCESSES / SESSIONS (M11.1), REDO_GB_DAY (M11.2) and DB_SIZE_GB (M11.3).
-- One row per (dbid, con_dbid, series).
--
-- It is deliberately the SAME arithmetic as CAPF_CPU_TREND -- REGR_* fit over
-- the last `train_days` days, the M9.1 residual-SE prediction bands, the same
-- quality ladder -- with one difference: the ceiling is not a global percent
-- knob but a PER-DAY, PER-SERIES `limit_value` carried up from the daily view
-- (the instance's `processes` parameter, or the summed tablespace ceilings).
-- The arithmetic is copied rather than shared on purpose: CAPF_CPU_TREND and
-- CAPF_TBSPC_FORECAST evolve on their own schedule (robust slopes, change-point
-- resets, ...), and this view must stay a plain, hand-auditable OLS fit.
--
--   days_to_limit = FLOOR((limit_value * series_sat_pct/100 - cur_val) / slope)
--
-- series_sat_pct (CAP_CONFIG, default 90) is the "call it full here" fraction:
-- hitting `processes` exactly is an outage, so the alert wants the days until
-- the series reaches 90% of the ceiling, not 100%. days_to_limit is NULL when
-- the series has no ceiling (REDO_GB_DAY) or is not growing (slope <= 0), and
-- GREATEST(0, ...) reports 0 -- not a negative "days" -- for a series already
-- past the saturation fraction.
--
-- days_to_limit_lo / _hi are the M9.1 range from the 95% CI on the slope:
-- lo = WORST case (fastest plausible growth, saturates soonest), hi = BEST
-- case, NULL when the slow edge of the CI is <= 0 ("might never get there").
--
-- quality grades, in priority order (identical to the other CAPF_ views):
--   INSUFFICIENT_HISTORY  REGR_COUNT < min_train_days
--   FLAT                  slope = 0 OR R^2 IS NULL  (REGR_R2 returns 1, not
--                         NULL, for a zero-variance y -- so FLAT keys off the
--                         slope, verified on 19c)
--   LOW_CONFIDENCE        R^2 < r2_gate
--   OK                    otherwise
--
-- 19c note: inline OVER (...) on every window call; no 21c WINDOW clause.
--
SET DEFINE OFF

CREATE OR REPLACE VIEW capf_series_forecast AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'train_days'     THEN cfg_value END) AS train_days,
               MAX(CASE WHEN cfg_name = 'min_train_days' THEN cfg_value END) AS min_train_days,
               MAX(CASE WHEN cfg_name = 'r2_gate'        THEN cfg_value END) AS r2_gate,
               MAX(CASE WHEN cfg_name = 'series_sat_pct' THEN cfg_value END) AS sat_pct
        FROM   cap_config
     ),
     d AS (
        SELECT dbid, con_dbid, series, unit, day_dt,
               day_dt - DATE '2020-01-01' AS day_n,
               value AS val, limit_value
        FROM   capd_series_daily
        WHERE  value IS NOT NULL
     ),
     b AS (
        SELECT dbid, con_dbid, series, MAX(day_dt) AS last_day
        FROM   d GROUP BY dbid, con_dbid, series
     ),
     dd AS (
        SELECT d.dbid, d.con_dbid, d.series, d.day_dt, d.day_n, d.val,
               b.last_day, b.last_day - DATE '2020-01-01' AS last_day_n
        FROM   d JOIN b ON b.dbid = d.dbid AND b.con_dbid = d.con_dbid
                       AND b.series = d.series
     ),
     fit AS (
        SELECT dd.dbid, dd.con_dbid, dd.series,
               MAX(dd.last_day)                 AS last_day,
               MAX(dd.last_day_n)               AS last_day_n,
               REGR_SLOPE(dd.val, dd.day_n)     AS slope,
               REGR_INTERCEPT(dd.val, dd.day_n) AS icept,
               REGR_R2(dd.val, dd.day_n)        AS r2,
               REGR_COUNT(dd.val, dd.day_n)     AS n,
               -- Sums for the M9.1 prediction intervals (hand-auditable).
               REGR_SXX(dd.val, dd.day_n)       AS sxx,
               REGR_SYY(dd.val, dd.day_n)       AS syy,
               REGR_SXY(dd.val, dd.day_n)       AS sxy,
               REGR_AVGX(dd.val, dd.day_n)      AS xbar
        FROM   dd CROSS JOIN cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
        GROUP  BY dd.dbid, dd.con_dbid, dd.series
     ),
     -- M9.1 closed forms (see ddl/30_forecast_views.sql for the derivation):
     --   SSE      = SYY - SXY^2/SXX
     --   resid_se = sqrt(SSE / (n-2))
     --   tval     = 1.96 + 2.4/(n-2)     (t_{.975,df} approximation -- part of
     --                                    the contract, mirrored by the fixture)
     --   half_h   = tval * resid_se * sqrt(1 + 1/n + (x0-xbar)^2/SXX)
     --   slope_ci = tval * resid_se / sqrt(SXX)
     stat AS (
        SELECT f.*,
               CASE WHEN f.n > 2 AND f.sxx > 0
                    THEN SQRT(GREATEST(0, f.syy - f.sxy * f.sxy / f.sxx) / (f.n - 2))
               END AS resid_se,
               CASE WHEN f.n > 2 THEN 1.96 + 2.4 / (f.n - 2) END AS tval
        FROM   fit f
     ),
     -- CASE-guarded: resid_se is NULL exactly when sxx = 0 or n <= 2, and the
     -- sxx divisions must not be evaluated then (ORA-01476).
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
     -- The ceiling and the unit are properties of the LAST observed day: a
     -- `processes` parameter change or a datafile resize moves them, and the
     -- current one is what the forecast is aiming at.
     cur AS (
        SELECT dbid, con_dbid, series,
               MAX(unit)        KEEP (DENSE_RANK LAST ORDER BY day_dt) AS unit,
               MAX(val)         KEEP (DENSE_RANK LAST ORDER BY day_dt) AS cur_val,
               MAX(limit_value) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS cur_limit
        FROM   d GROUP BY dbid, con_dbid, series
     )
SELECT f.dbid,
       f.con_dbid,
       f.series,
       c.unit,
       f.last_day,
       f.n                                          AS train_n,
       c.cur_val,
       c.cur_limit,
       -- How close to the ceiling RIGHT NOW, independent of any fit -- the
       -- SERIES_NEARLIMIT alert keys off this, so a series sitting at 95% of
       -- `processes` surfaces even when its trend is too erratic to forecast.
       CASE WHEN c.cur_limit > 0
            THEN ROUND(100 * c.cur_val / c.cur_limit, 1)
       END                                          AS pct_of_limit,
       f.slope                                      AS slope_per_day,
       f.icept,
       f.r2,
       f.icept + f.slope * (f.last_day_n + 30)      AS proj_30,
       f.icept + f.slope * (f.last_day_n + 90)      AS proj_90,
       f.icept + f.slope * (f.last_day_n + 30) - f.half_30 AS proj_30_lo,
       f.icept + f.slope * (f.last_day_n + 30) + f.half_30 AS proj_30_hi,
       f.icept + f.slope * (f.last_day_n + 90) - f.half_90 AS proj_90_lo,
       f.icept + f.slope * (f.last_day_n + 90) + f.half_90 AS proj_90_hi,
       f.slope_ci                                   AS slope_ci_per_day,
       -- The saturation target itself, so a reader can check the arithmetic
       -- without re-reading the knob.
       CASE WHEN c.cur_limit > 0
            THEN c.cur_limit * cfg.sat_pct / 100
       END                                          AS sat_value,
       CASE WHEN c.cur_limit > 0 AND f.slope > 0
            THEN GREATEST(0, FLOOR((c.cur_limit * cfg.sat_pct / 100 - c.cur_val) / f.slope))
       END                                          AS days_to_limit,
       CASE WHEN c.cur_limit > 0 AND f.slope > 0 AND f.slope_ci IS NOT NULL
            THEN GREATEST(0, FLOOR((c.cur_limit * cfg.sat_pct / 100 - c.cur_val)
                                   / (f.slope + f.slope_ci)))
       END                                          AS days_to_limit_lo,
       CASE WHEN c.cur_limit > 0 AND f.slope > 0 AND f.slope_ci IS NOT NULL
                 AND f.slope - f.slope_ci > 0
            THEN GREATEST(0, FLOOR((c.cur_limit * cfg.sat_pct / 100 - c.cur_val)
                                   / (f.slope - f.slope_ci)))
       END                                          AS days_to_limit_hi,
       CASE WHEN f.n  < cfg.min_train_days     THEN 'INSUFFICIENT_HISTORY'
            WHEN f.slope = 0 OR f.r2 IS NULL   THEN 'FLAT'
            WHEN f.r2 < cfg.r2_gate            THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                          AS quality
FROM   band f
JOIN   cur c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid AND c.series = f.series
CROSS  JOIN cfg;
