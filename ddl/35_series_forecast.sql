--
-- ddl/35_series_forecast.sql -- CAPF_SERIES_FORECAST: fixed-ceiling series (M11).
-- =====================================================================
-- The Tier 1 (pure-SQL OLS) forecast for CAPD_SERIES_DAILY, i.e. for
-- PROCESSES / SESSIONS (M11.1), REDO_GB_DAY (M11.2), DB_SIZE_GB (M11.3) and
-- the ASM_DG / TEMP_PEAK / UNDO_PEAK series. One row per
-- (dbid, con_dbid, series).
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
--   proj_h        = cur_val + slope * h       (anchored at today, as in ddl/30)
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
-- Only complete days are fitted (is_complete = 'Y'): the flow series
-- REDO_GB_DAY drops its partial, restart and outage days, the level series
-- carry 'Y' on every day. newest_day / is_current follow ddl/30: newest_day
-- is the newest day with a value for the dbid, complete or not, and
-- is_current = 'Y' when last_day >= newest_day - stale_days.
--
-- quality grades, in priority order (identical to the other CAPF_ views):
--   INSUFFICIENT_HISTORY  REGR_COUNT < min_train_days
--   FLAT                  slope = 0 OR R^2 IS NULL  (REGR_R2 returns 1, not
--                         NULL, for a zero-variance y -- so FLAT keys off the
--                         slope, verified on 19c)
--   LOW_CONFIDENCE        R^2 < r2_gate (DRIFT: the slope CI includes 0)
--   OK                    otherwise
--
-- slope_method = 2 (DRIFT) applies here exactly as in ddl/30: slope =
-- MEDIAN of the day-over-day rates of the window, CI t * sd / SQRT(n_rates),
-- bands t * (sd * SQRT(h) + h * se), no R^2 gate. slope_method = 1 does not:
-- this view never computes Theil-Sen, and the slope_method column says OLS.
-- drift_slope_per_day / drift_sd_per_day are exposed under every setting.
--
-- FRA days (REDO_GB_DAY rows only, NULL on every other series):
--   fra_size_gb     = db_recovery_file_dest_size / 2^30 at the dbid's newest
--                     snapshot that carries it (CAPV_PARAMETER), NULL when
--                     unset or 0.
--   fra_days_at_cur = fra_size_gb / the dbid's current redo rate: the days
--                     of redo the FRA holds at today's rate. The log stream
--                     is shared, so the rate is the SUM of cur_val over the
--                     dbid's current (is_current = 'Y') REDO_GB_DAY rows, one
--                     per container in local mode, and every REDO row of the
--                     dbid carries the same number. NULL when either side is
--                     NULL or 0. It is an upper bound: the FRA also holds
--                     flashback logs and backups.
--
-- 19c note: inline OVER (...) on every window call; no 21c WINDOW clause.
--
SET DEFINE OFF

CREATE OR REPLACE VIEW capf_series_forecast AS
WITH src AS (
        SELECT dbid, con_dbid, series, unit, day_dt, value AS val, limit_value,
               is_complete
        FROM   capd_series_daily
        WHERE  value IS NOT NULL
     ),
     nd AS (
        SELECT dbid, MAX(day_dt) AS newest_day
        FROM   src
        GROUP  BY dbid
     ),
     d AS (
        SELECT dbid, con_dbid, series, unit, day_dt,
               day_dt - DATE '2020-01-01' AS day_n,
               val, limit_value
        FROM   src
        WHERE  is_complete = 'Y'
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
     w AS (
        SELECT dd.* FROM dd CROSS JOIN cap_cfg cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
     ),
     -- DRIFT input: day-over-day rate inside the window (gap-normalised).
     wr AS (
        SELECT w.*,
               (w.val - LAG(w.val) OVER (PARTITION BY w.dbid, w.con_dbid, w.series ORDER BY w.day_dt))
             / (w.day_n - LAG(w.day_n) OVER (PARTITION BY w.dbid, w.con_dbid, w.series ORDER BY w.day_dt)) AS rate
        FROM   w
     ),
     fit AS (
        SELECT w.dbid, w.con_dbid, w.series,
               MAX(w.last_day)                 AS last_day,
               MAX(w.last_day_n)               AS last_day_n,
               REGR_SLOPE(w.val, w.day_n)      AS slope,
               REGR_INTERCEPT(w.val, w.day_n)  AS icept,
               REGR_R2(w.val, w.day_n)         AS r2,
               REGR_COUNT(w.val, w.day_n)      AS n,
               -- Sums for the M9.1 prediction intervals (hand-auditable).
               REGR_SXX(w.val, w.day_n)        AS sxx,
               REGR_SYY(w.val, w.day_n)        AS syy,
               REGR_SXY(w.val, w.day_n)        AS sxy,
               REGR_AVGX(w.val, w.day_n)       AS xbar
        FROM   w
        GROUP  BY w.dbid, w.con_dbid, w.series
     ),
     dband AS (
        SELECT x.*,
               CASE WHEN x.drift_n > 1 THEN 1.96 + 2.4 / (x.drift_n - 1) END AS dtval,
               CASE WHEN x.drift_n > 1 THEN x.drift_sd / SQRT(x.drift_n)  END AS dse
        FROM  (SELECT dbid, con_dbid, series,
                      MEDIAN(rate)      AS drift,
                      STDDEV_SAMP(rate) AS drift_sd,
                      COUNT(rate)       AS drift_n
               FROM   wr
               GROUP  BY dbid, con_dbid, series) x
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
     est AS (
        SELECT q.*,
               CASE q.slope_method WHEN 'DRIFT' THEN q.drift ELSE q.slope END           AS use_slope,
               CASE q.slope_method WHEN 'DRIFT' THEN q.dtval * q.dse ELSE q.slope_ci END AS use_ci,
               CASE q.slope_method WHEN 'DRIFT' THEN q.dtval * (q.drift_sd * SQRT(30) + 30 * q.dse)
                                   ELSE q.half_30 END                                    AS use_h30,
               CASE q.slope_method WHEN 'DRIFT' THEN q.dtval * (q.drift_sd * SQRT(90) + 90 * q.dse)
                                   ELSE q.half_90 END                                    AS use_h90
        FROM  (SELECT b.*, x.drift, x.drift_sd, x.drift_n, x.dtval, x.dse,
                      CASE WHEN cfg.slope_method = 2 AND x.drift IS NOT NULL
                           THEN 'DRIFT' ELSE 'OLS' END AS slope_method
               FROM   band b
               LEFT   JOIN dband x ON x.dbid = b.dbid AND x.con_dbid = b.con_dbid
                                  AND x.series = b.series
               CROSS  JOIN cap_cfg cfg) q
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
     ),
     -- db_recovery_file_dest_size is database-wide: MAX across instances at
     -- the newest snapshot.
     fra AS (
        SELECT dbid,
               MAX(value_num) KEEP (DENSE_RANK LAST ORDER BY snap_id) AS fra_bytes
        FROM   capv_parameter
        WHERE  parameter_name = 'db_recovery_file_dest_size'
        GROUP  BY dbid
     ),
     -- The dbid's redo rate today: its current REDO_GB_DAY rows summed.
     redo_db AS (
        SELECT b.dbid, SUM(c.cur_val) AS redo_gb_day
        FROM   b
        JOIN   cur c ON c.dbid = b.dbid AND c.con_dbid = b.con_dbid AND c.series = b.series
        JOIN   nd  n ON n.dbid = b.dbid
        CROSS  JOIN cap_cfg cfg
        WHERE  b.series = 'REDO_GB_DAY'
          AND  b.last_day >= n.newest_day - cfg.stale_days
        GROUP  BY b.dbid
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
       f.use_slope                                  AS slope_per_day,
       -- DRIFT fits no intercept: the line the projections lie on.
       CASE f.slope_method WHEN 'DRIFT' THEN c.cur_val - f.use_slope * f.last_day_n
                           ELSE f.icept END         AS icept,
       f.r2,
       -- Anchored at today; the half-widths are drawn around the anchor.
       c.cur_val + f.use_slope * 30                 AS proj_30,
       c.cur_val + f.use_slope * 90                 AS proj_90,
       c.cur_val + f.use_slope * 30 - f.use_h30     AS proj_30_lo,
       c.cur_val + f.use_slope * 30 + f.use_h30     AS proj_30_hi,
       c.cur_val + f.use_slope * 90 - f.use_h90     AS proj_90_lo,
       c.cur_val + f.use_slope * 90 + f.use_h90     AS proj_90_hi,
       f.use_ci                                     AS slope_ci_per_day,
       -- The saturation target itself, so a reader can check the arithmetic
       -- without re-reading the knob.
       CASE WHEN c.cur_limit > 0
            THEN c.cur_limit * cfg.series_sat_pct / 100
       END                                          AS sat_value,
       CASE WHEN c.cur_limit > 0 AND f.use_slope > 0
            THEN GREATEST(0, FLOOR((c.cur_limit * cfg.series_sat_pct / 100 - c.cur_val) / f.use_slope))
       END                                          AS days_to_limit,
       CASE WHEN c.cur_limit > 0 AND f.use_slope > 0 AND f.use_ci IS NOT NULL
            THEN GREATEST(0, FLOOR((c.cur_limit * cfg.series_sat_pct / 100 - c.cur_val)
                                   / (f.use_slope + f.use_ci)))
       END                                          AS days_to_limit_lo,
       CASE WHEN c.cur_limit > 0 AND f.use_slope > 0 AND f.use_ci IS NOT NULL
                 AND f.use_slope - f.use_ci > 0
            THEN GREATEST(0, FLOOR((c.cur_limit * cfg.series_sat_pct / 100 - c.cur_val)
                                   / (f.use_slope - f.use_ci)))
       END                                          AS days_to_limit_hi,
       CASE WHEN f.n  < cfg.min_train_days     THEN 'INSUFFICIENT_HISTORY'
            WHEN f.use_slope = 0
              OR (f.slope_method <> 'DRIFT' AND f.r2 IS NULL) THEN 'FLAT'
            WHEN f.slope_method = 'DRIFT'
                 THEN CASE WHEN ABS(f.use_slope) > f.use_ci THEN 'OK'
                           ELSE 'LOW_CONFIDENCE' END
            WHEN f.r2 < cfg.r2_gate            THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                          AS quality,
       n.newest_day,
       CASE WHEN f.last_day >= n.newest_day - cfg.stale_days
            THEN 'Y' ELSE 'N' END                   AS is_current,
       f.slope_method,
       f.drift                                      AS drift_slope_per_day,
       f.drift_sd                                   AS drift_sd_per_day,
       CASE WHEN f.series = 'REDO_GB_DAY' AND r.fra_bytes > 0
            THEN r.fra_bytes / 1073741824
       END                                          AS fra_size_gb,
       CASE WHEN f.series = 'REDO_GB_DAY' AND r.fra_bytes > 0 AND x.redo_gb_day > 0
            THEN r.fra_bytes / 1073741824 / x.redo_gb_day
       END                                          AS fra_days_at_cur
FROM   est f
JOIN   cur c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid AND c.series = f.series
JOIN   nd  n ON n.dbid = f.dbid
LEFT   JOIN fra     r ON r.dbid = f.dbid
LEFT   JOIN redo_db x ON x.dbid = f.dbid
CROSS  JOIN cap_cfg cfg;
