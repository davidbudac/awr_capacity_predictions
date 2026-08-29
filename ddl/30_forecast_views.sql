--
-- ddl/30_forecast_views.sql -- CAPF_* Tier 1 (pure-SQL linear) forecasts.
-- =====================================================================
-- Linear fits computed two ways -- ordinary least squares via Oracle's built-in
-- REGR_* aggregates, and (M9.2) a robust Theil-Sen median-of-pairwise-slopes --
-- so every projection is reproducible by hand from slope + intercept. All
-- tuning comes from CAP_CONFIG through a one-row `cfg` CTE.
--
--   CAPF_TBSPC_FORECAST -- per tablespace: bytes/day slope, R^2, +30/90/180/365
--                          day projections with 95% prediction bands
--                          (proj_*_lo/hi), days_to_full with a worst/best-case
--                          range (days_to_full_lo/hi, M9.1), recent-vs-full
--                          acceleration ratio, and a quality grade. The
--                          training window may be restarted after a purge
--                          (M9.3: train_start / reset_day).
--   CAPF_CPU_TREND      -- per CPU metric (host busy% avg/p95/peak-window,
--                          DB CPU sec, DB CPU % of cores avg/p95): slope, R^2,
--                          projections (+95% bands), days_to_saturation
--                          (+lo/hi range), quality.
--
-- day_n is an integer day index off a fixed epoch (DATE '2020-01-01') rather
-- than a raw date number, so slopes are in "per day" and are stable/auditable.
--
-- ---------------------------------------------------------------------
-- M9.2 -- robust slope (knob `slope_method`: 0 = OLS default, 1 = THEILSEN)
-- ---------------------------------------------------------------------
-- OLS minimises squared error, so ONE step (a bulk load, a partition drop, an
-- import) drags the whole slope with it: FIX_SPIKE grows at 5 MiB/day yet its
-- OLS slope reads ~20 MiB/day because of a single +2 GiB day. The Theil-Sen
-- estimator is the MEDIAN of the pairwise slopes (y_j - y_i)/(x_j - x_i) over
-- every i < j in the training window -- it has a 29% breakdown point, so a
-- minority of stepped pairs cannot move it. Cost is O(n^2): ~4k pairs per
-- series at the shipped 90-day window, computed with a self-join on `w`.
--
-- BOTH slopes are always exposed (`ols_slope_bpd` and `ts_slope_bpd`), and
-- `slope_method` says which one the row actually used. When the knob selects
-- THEILSEN, the CHOSEN line drives `slope_bpd`, `icept`, every `proj_*` point
-- projection, `days_to_full`, the `accel_ratio` numerator and denominator, and
-- the `slope = 0` FLAT test. `r2`, `resid_se` and the M9.1 half-widths stay
-- OLS quantities -- there is no closed-form prediction interval for Theil-Sen
-- in SQL, so the bands are OLS residual bands drawn AROUND the chosen line,
-- and `slope_ci_bpd` / `days_to_full_lo/hi` remain OLS. Acceptable for v1 --
-- with the default slope_method = 0 nothing about the output changes at all.
-- (No comment line here may end in a semicolon: SQL*Plus would take it as the
-- statement terminator in plain-SQL context.)
--
-- ---------------------------------------------------------------------
-- M9.3 -- change-point reset (knobs `reset_on_shrink`, `shrink_mad_k`)
-- ---------------------------------------------------------------------
-- After a purge / archive / partition drop, a tablespace's history has a cliff
-- in it, and a line fitted across the cliff is a fiction: it under-states the
-- slope and over-states the headroom. When `reset_on_shrink = 1` (default) the
-- training window RESTARTS at the most recent day whose day-over-day delta is
-- a large NEGATIVE step:
--
--     delta < -GREATEST(shrink_mad_k * MAD_sigma(deltas), abs_floor_bytes)
--
-- with MAD_sigma = MEDIAN(|delta - MEDIAN(delta)|) * 1.4826 over the deltas of
-- the full train_days window (two passes, exactly like ddl/40 -- but per
-- series over one window, not rolling, so a plain GROUP BY suffices). The
-- abs_floor_bytes term is what stops an exactly-flat series (MAD = 0) from
-- treating every wiggle as a cliff, and shrink_mad_k = 6 (vs mad_k = 3 for
-- anomalies) keeps this to real cliffs rather than merely notable days.
--
-- The reset day ITSELF is the first day of the new window (its used_bytes is
-- already the post-purge level), so `train_start = reset_day` and the fit sees
-- only post-cliff data. `reset_day` is NULL when no reset applied. If fewer
-- than min_train_days rows survive the reset, quality becomes
-- INSUFFICIENT_HISTORY -- that is the honest answer: we genuinely do not yet
-- know the post-purge growth rate.
--
-- quality grades (checked in priority order):
--   INSUFFICIENT_HISTORY  train_n < min_train_days
--   FLAT                  chosen slope = 0 (no growth) OR R^2 IS NULL. NOTE:
--                         Oracle's REGR_R2 returns 1 (not NULL) when y has
--                         zero variance and x does not, so a truly flat series
--                         is detected by slope = 0, not by a NULL R^2. R^2 IS
--                         NULL only happens when x has zero variance (single
--                         distinct day), which INSUFFICIENT_HISTORY covers.
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
               MAX(CASE WHEN cfg_name = 'r2_gate'        THEN cfg_value END) AS r2_gate,
               MAX(CASE WHEN cfg_name = 'accel_slope_floor_bpd' THEN cfg_value END) AS accel_floor,
               -- M9.2 / M9.3 knobs
               MAX(CASE WHEN cfg_name = 'slope_method'    THEN cfg_value END) AS slope_method,
               MAX(CASE WHEN cfg_name = 'reset_on_shrink' THEN cfg_value END) AS reset_on_shrink,
               MAX(CASE WHEN cfg_name = 'shrink_mad_k'    THEN cfg_value END) AS shrink_mad_k,
               MAX(CASE WHEN cfg_name = 'abs_floor_bytes' THEN cfg_value END) AS abs_floor
        FROM   cap_config
     ),
     d AS (
        -- used_delta is the raw day-over-day step, computed over the FULL
        -- series (so the first day of the training window still has one) and
        -- used only by the M9.3 change-point test below. 19c: the OVER clause
        -- is inline -- the standalone WINDOW clause is 21c+.
        SELECT dbid, con_dbid, tablespace_name, day_dt,
               day_dt - DATE '2020-01-01' AS day_n,
               used_bytes, limit_bytes, limit_source,
               used_bytes - LAG(used_bytes) OVER (PARTITION BY dbid, con_dbid, tablespace_name
                                                  ORDER BY day_dt) AS used_delta
        FROM   capd_tbspc_daily
     ),
     b AS (
        SELECT dbid, con_dbid, tablespace_name, MAX(day_dt) AS last_day
        FROM   d
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     dd AS (
        SELECT d.dbid, d.con_dbid, d.tablespace_name, d.day_dt, d.day_n,
               d.used_bytes, d.limit_bytes, d.used_delta,
               b.last_day,
               b.last_day - DATE '2020-01-01' AS last_day_n
        FROM   d
        JOIN   b ON b.dbid = d.dbid AND b.con_dbid = d.con_dbid
                AND b.tablespace_name = d.tablespace_name
     ),
     -- tw = the nominal training window (the last train_days days).
     tw AS (
        SELECT dd.* FROM dd CROSS JOIN cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
     ),
     -- ---- M9.3 change-point detection, two passes over tw's deltas ----
     dmed AS (
        SELECT dbid, con_dbid, tablespace_name,
               MEDIAN(used_delta) AS dmed
        FROM   tw
        WHERE  used_delta IS NOT NULL
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     dmad AS (
        SELECT t.dbid, t.con_dbid, t.tablespace_name,
               MAX(m.dmed)                                AS dmed,
               MEDIAN(ABS(t.used_delta - m.dmed)) * 1.4826 AS dsig
        FROM   tw t
        JOIN   dmed m ON m.dbid = t.dbid AND m.con_dbid = t.con_dbid
                     AND m.tablespace_name = t.tablespace_name
        WHERE  t.used_delta IS NOT NULL
        GROUP  BY t.dbid, t.con_dbid, t.tablespace_name
     ),
     -- The MOST RECENT cliff wins (MAX(day_dt)): a series purged twice is fit
     -- from the last purge, not the first.
     rst AS (
        SELECT t.dbid, t.con_dbid, t.tablespace_name,
               MAX(t.day_dt) AS reset_day
        FROM   tw t
        JOIN   dmad m ON m.dbid = t.dbid AND m.con_dbid = t.con_dbid
                     AND m.tablespace_name = t.tablespace_name
        CROSS  JOIN cfg
        WHERE  cfg.reset_on_shrink = 1
          AND  t.used_delta < -GREATEST(cfg.shrink_mad_k * m.dsig, cfg.abs_floor)
        GROUP  BY t.dbid, t.con_dbid, t.tablespace_name
     ),
     -- w = the EFFECTIVE training window: tw, restarted at reset_day when one
     -- was found. Everything downstream (OLS fit, Theil-Sen, recent fit) uses
     -- w, so the reset applies once and consistently.
     w AS (
        SELECT t.* FROM tw t
        LEFT   JOIN rst r ON r.dbid = t.dbid AND r.con_dbid = t.con_dbid
                         AND r.tablespace_name = t.tablespace_name
        WHERE  r.reset_day IS NULL OR t.day_dt >= r.reset_day
     ),
     fit AS (
        SELECT w.dbid, w.con_dbid, w.tablespace_name,
               MAX(w.last_day)                  AS last_day,
               MAX(w.last_day_n)                AS last_day_n,
               MIN(w.day_dt)                    AS train_start,
               REGR_SLOPE(w.used_bytes, w.day_n)     AS slope,
               REGR_INTERCEPT(w.used_bytes, w.day_n) AS icept,
               REGR_R2(w.used_bytes, w.day_n)        AS r2,
               REGR_COUNT(w.used_bytes, w.day_n)     AS n,
               -- Sums for the M9.1 prediction intervals (all hand-auditable):
               REGR_SXX(w.used_bytes, w.day_n)       AS sxx,
               REGR_SYY(w.used_bytes, w.day_n)       AS syy,
               REGR_SXY(w.used_bytes, w.day_n)       AS sxy,
               REGR_AVGX(w.used_bytes, w.day_n)      AS xbar
        FROM   w
        GROUP  BY w.dbid, w.con_dbid, w.tablespace_name
     ),
     -- ---- M9.2 Theil-Sen over the SAME effective window ----
     -- One row per ordered pair (i before j); the median of these is the
     -- estimate. Empty for a single-day window, which the pick CTE falls back
     -- from.
     tspair AS (
        SELECT i.dbid, i.con_dbid, i.tablespace_name,
               (j.used_bytes - i.used_bytes) / (j.day_n - i.day_n) AS pslope
        FROM   w i
        JOIN   w j ON j.dbid = i.dbid AND j.con_dbid = i.con_dbid
                  AND j.tablespace_name = i.tablespace_name
                  AND j.day_n > i.day_n
     ),
     tsslp AS (
        SELECT dbid, con_dbid, tablespace_name, MEDIAN(pslope) AS ts_slope
        FROM   tspair
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     -- Theil-Sen intercept = MEDIAN(y - slope*x), the standard companion
     -- estimator (it puts the robust line through the bulk of the points).
     tsfit AS (
        SELECT w.dbid, w.con_dbid, w.tablespace_name,
               MAX(s.ts_slope)                                  AS ts_slope,
               MEDIAN(w.used_bytes - s.ts_slope * w.day_n)      AS ts_icept
        FROM   w
        JOIN   tsslp s ON s.dbid = w.dbid AND s.con_dbid = w.con_dbid
                      AND s.tablespace_name = w.tablespace_name
        GROUP  BY w.dbid, w.con_dbid, w.tablespace_name
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
     -- ---- M9.2: which line does this row actually use? ----
     -- Falls back to OLS whenever Theil-Sen could not be computed (a
     -- single-day window has no pairs), and the slope_method label always
     -- reports what was USED, never merely what was asked for.
     pick AS (
        SELECT b.*,
               t.ts_slope,
               t.ts_icept,
               r.reset_day,
               CASE WHEN cfg.slope_method = 1 AND t.ts_slope IS NOT NULL
                    THEN 'THEILSEN' ELSE 'OLS' END AS slope_method,
               CASE WHEN cfg.slope_method = 1 AND t.ts_slope IS NOT NULL
                    THEN t.ts_slope ELSE b.slope END AS use_slope,
               CASE WHEN cfg.slope_method = 1 AND t.ts_slope IS NOT NULL
                    THEN t.ts_icept ELSE b.icept END AS use_icept
        FROM   band b
        LEFT   JOIN tsfit t ON t.dbid = b.dbid AND t.con_dbid = b.con_dbid
                           AND t.tablespace_name = b.tablespace_name
        LEFT   JOIN rst r   ON r.dbid = b.dbid AND r.con_dbid = b.con_dbid
                           AND r.tablespace_name = b.tablespace_name
        CROSS  JOIN cfg
     ),
     -- The "recent" (accel_ratio) fit, over the same effective window so a
     -- post-purge series compares post-purge growth against post-purge growth.
     rw AS (
        SELECT t.* FROM w t CROSS JOIN cfg
        WHERE  t.day_dt > t.last_day - cfg.recent_days
     ),
     rfit AS (
        SELECT rw.dbid, rw.con_dbid, rw.tablespace_name,
               REGR_SLOPE(rw.used_bytes, rw.day_n)  AS recent_slope,
               REGR_COUNT(rw.used_bytes, rw.day_n)  AS recent_n
        FROM   rw
        GROUP  BY rw.dbid, rw.con_dbid, rw.tablespace_name
     ),
     rtspair AS (
        SELECT i.dbid, i.con_dbid, i.tablespace_name,
               (j.used_bytes - i.used_bytes) / (j.day_n - i.day_n) AS pslope
        FROM   rw i
        JOIN   rw j ON j.dbid = i.dbid AND j.con_dbid = i.con_dbid
                   AND j.tablespace_name = i.tablespace_name
                   AND j.day_n > i.day_n
     ),
     rtsslp AS (
        SELECT dbid, con_dbid, tablespace_name, MEDIAN(pslope) AS rts_slope
        FROM   rtspair
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     -- accel_ratio must compare like with like: when the row uses Theil-Sen,
     -- BOTH the numerator (recent) and the denominator (full window) are
     -- Theil-Sen. Mixing estimators would manufacture acceleration.
     rcomb AS (
        SELECT r.dbid, r.con_dbid, r.tablespace_name, r.recent_n,
               CASE WHEN cfg.slope_method = 1 AND rt.rts_slope IS NOT NULL
                    THEN rt.rts_slope ELSE r.recent_slope END AS recent_slope
        FROM   rfit r
        LEFT   JOIN rtsslp rt ON rt.dbid = r.dbid AND rt.con_dbid = r.con_dbid
                             AND rt.tablespace_name = r.tablespace_name
        CROSS  JOIN cfg
     ),
     cur AS (
        SELECT dbid, con_dbid, tablespace_name,
               MAX(used_bytes)  KEEP (DENSE_RANK LAST ORDER BY day_dt) AS cur_used,
               MAX(limit_bytes) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS limit_bytes,
               -- M9.5: where limit_bytes came from (OVERRIDE | AUTOEXTEND |
               -- ALLOCATED), so the report can flag a hand-set ceiling.
               MAX(limit_source) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS limit_source
        FROM   d
        GROUP  BY dbid, con_dbid, tablespace_name
     )
SELECT f.dbid,
       f.con_dbid,
       f.tablespace_name,
       f.last_day,
       f.n                                                AS train_n,
       -- M9.3: the first day actually fitted, and the cliff that caused it
       -- (NULL = no reset, the window is simply the last train_days days).
       f.train_start,
       f.reset_day,
       c.cur_used,
       c.limit_bytes,
       c.limit_source,
       -- How full RIGHT NOW, independent of any fit: the report's "near-full
       -- now" ranking keys off this so a 97%-full tablespace is never hidden
       -- by a LOW_CONFIDENCE/INSUFFICIENT_HISTORY fit (M7.1).
       CASE WHEN c.limit_bytes > 0
            THEN ROUND(100 * c.cur_used / c.limit_bytes, 1)
       END                                                AS pct_used,
       -- M9.2: the chosen line, then BOTH estimators so the choice is visible.
       f.use_slope                                        AS slope_bpd,
       f.use_icept                                        AS icept,
       f.slope                                            AS ols_slope_bpd,
       f.ts_slope                                         AS ts_slope_bpd,
       f.ts_icept,
       f.slope_method,
       f.r2,
       f.use_icept + f.use_slope * (f.last_day_n + 30)    AS proj_30_bytes,
       f.use_icept + f.use_slope * (f.last_day_n + 90)    AS proj_90_bytes,
       f.use_icept + f.use_slope * (f.last_day_n + 180)   AS proj_180_bytes,
       f.use_icept + f.use_slope * (f.last_day_n + 365)   AS proj_365_bytes,
       -- M9.1: 95% prediction bands on each projection. The half-widths are
       -- OLS residual quantities (there is no closed-form Theil-Sen interval
       -- in SQL), drawn around whichever line the row chose -- see the M9.2
       -- block in the header.
       f.use_icept + f.use_slope * (f.last_day_n + 30)  - f.half_30   AS proj_30_lo,
       f.use_icept + f.use_slope * (f.last_day_n + 30)  + f.half_30   AS proj_30_hi,
       f.use_icept + f.use_slope * (f.last_day_n + 90)  - f.half_90   AS proj_90_lo,
       f.use_icept + f.use_slope * (f.last_day_n + 90)  + f.half_90   AS proj_90_hi,
       f.use_icept + f.use_slope * (f.last_day_n + 180) - f.half_180  AS proj_180_lo,
       f.use_icept + f.use_slope * (f.last_day_n + 180) + f.half_180  AS proj_180_hi,
       f.use_icept + f.use_slope * (f.last_day_n + 365) - f.half_365  AS proj_365_lo,
       f.use_icept + f.use_slope * (f.last_day_n + 365) + f.half_365  AS proj_365_hi,
       f.slope_ci                                             AS slope_ci_bpd,
       CASE WHEN f.use_slope > 0
            THEN FLOOR((c.limit_bytes - c.cur_used) / f.use_slope)
       END                                                AS days_to_full,
       -- ... and a range on days_to_full from the OLS slope's 95% CI.
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
       -- M7.7: only meaningful when the baseline slope is real growth. Below
       -- accel_slope_floor_bpd (default 1 MiB/day) a near-flat series divides
       -- by ~0 and reports an absurd 500x "acceleration", so the ratio is NULL
       -- instead. slope = 0 (FLAT) was already NULL and still is.
       CASE WHEN ABS(f.use_slope) >= cfg.accel_floor
            THEN r.recent_slope / f.use_slope
       END                                                AS accel_ratio,
       CASE WHEN f.n  < cfg.min_train_days       THEN 'INSUFFICIENT_HISTORY'
            WHEN f.use_slope = 0 OR f.r2 IS NULL THEN 'FLAT'
            WHEN f.r2 < cfg.r2_gate              THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                                AS quality
FROM   pick f
JOIN   cur  c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid
             AND c.tablespace_name = f.tablespace_name
LEFT   JOIN rcomb r ON r.dbid = f.dbid AND r.con_dbid = f.con_dbid
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
--
-- M9.2 applies here too (same pairwise-median pattern, same slope_method
-- knob, same "bands stay OLS" rule). M9.3 does NOT: a change-point reset is
-- defined on a tablespace SHRINK (a purge), which has no CPU analogue -- a
-- CPU level shift is M10.3's job, not this one.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_cpu_trend AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'train_days'     THEN cfg_value END) AS train_days,
               MAX(CASE WHEN cfg_name = 'min_train_days' THEN cfg_value END) AS min_train_days,
               MAX(CASE WHEN cfg_name = 'r2_gate'        THEN cfg_value END) AS r2_gate,
               MAX(CASE WHEN cfg_name = 'cpu_sat_pct'    THEN cfg_value END) AS cpu_sat_pct,
               MAX(CASE WHEN cfg_name = 'slope_method'   THEN cfg_value END) AS slope_method
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
     w AS (
        SELECT dd.* FROM dd CROSS JOIN cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
     ),
     fit AS (
        SELECT w.dbid, w.con_dbid, w.metric,
               MAX(w.last_day)                AS last_day,
               MAX(w.last_day_n)              AS last_day_n,
               MIN(w.day_dt)                  AS train_start,
               REGR_SLOPE(w.val, w.day_n)     AS slope,
               REGR_INTERCEPT(w.val, w.day_n) AS icept,
               REGR_R2(w.val, w.day_n)        AS r2,
               REGR_COUNT(w.val, w.day_n)     AS n,
               REGR_SXX(w.val, w.day_n)       AS sxx,
               REGR_SYY(w.val, w.day_n)       AS syy,
               REGR_SXY(w.val, w.day_n)       AS sxy,
               REGR_AVGX(w.val, w.day_n)      AS xbar
        FROM   w
        GROUP  BY w.dbid, w.con_dbid, w.metric
     ),
     -- M9.2 Theil-Sen, identical pattern to CAPF_TBSPC_FORECAST.
     tspair AS (
        SELECT i.dbid, i.con_dbid, i.metric,
               (j.val - i.val) / (j.day_n - i.day_n) AS pslope
        FROM   w i
        JOIN   w j ON j.dbid = i.dbid AND j.con_dbid = i.con_dbid
                  AND j.metric = i.metric AND j.day_n > i.day_n
     ),
     tsslp AS (
        SELECT dbid, con_dbid, metric, MEDIAN(pslope) AS ts_slope
        FROM   tspair GROUP BY dbid, con_dbid, metric
     ),
     tsfit AS (
        SELECT w.dbid, w.con_dbid, w.metric,
               MAX(s.ts_slope)                        AS ts_slope,
               MEDIAN(w.val - s.ts_slope * w.day_n)   AS ts_icept
        FROM   w
        JOIN   tsslp s ON s.dbid = w.dbid AND s.con_dbid = w.con_dbid
                      AND s.metric = w.metric
        GROUP  BY w.dbid, w.con_dbid, w.metric
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
     pick AS (
        SELECT b.*,
               t.ts_slope,
               t.ts_icept,
               CASE WHEN cfg.slope_method = 1 AND t.ts_slope IS NOT NULL
                    THEN 'THEILSEN' ELSE 'OLS' END AS slope_method,
               CASE WHEN cfg.slope_method = 1 AND t.ts_slope IS NOT NULL
                    THEN t.ts_slope ELSE b.slope END AS use_slope,
               CASE WHEN cfg.slope_method = 1 AND t.ts_slope IS NOT NULL
                    THEN t.ts_icept ELSE b.icept END AS use_icept
        FROM   band b
        LEFT   JOIN tsfit t ON t.dbid = b.dbid AND t.con_dbid = b.con_dbid
                           AND t.metric = b.metric
        CROSS  JOIN cfg
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
       f.train_start,
       c.cur_val,
       f.use_slope                                  AS slope_per_day,
       f.use_icept                                  AS icept,
       f.slope                                      AS ols_slope_per_day,
       f.ts_slope                                   AS ts_slope_per_day,
       f.ts_icept,
       f.slope_method,
       f.r2,
       f.use_icept + f.use_slope * (f.last_day_n + 30)      AS proj_30,
       f.use_icept + f.use_slope * (f.last_day_n + 90)      AS proj_90,
       -- M9.1: 95% prediction bands + days_to_sat range (same semantics as
       -- CAPF_TBSPC_FORECAST: lo = worst case / soonest, hi = best case,
       -- hi NULL when the slow edge of the slope CI is <= 0). Band half-widths
       -- and the slope CI are OLS quantities either way (M9.2).
       f.use_icept + f.use_slope * (f.last_day_n + 30) - f.half_30 AS proj_30_lo,
       f.use_icept + f.use_slope * (f.last_day_n + 30) + f.half_30 AS proj_30_hi,
       f.use_icept + f.use_slope * (f.last_day_n + 90) - f.half_90 AS proj_90_lo,
       f.use_icept + f.use_slope * (f.last_day_n + 90) + f.half_90 AS proj_90_hi,
       f.slope_ci                                   AS slope_ci_per_day,
       -- GREATEST(0,...): if current busy% already exceeds the saturation
       -- threshold, report 0 (saturated now) rather than a negative "days".
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.use_slope > 0
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - c.cur_val) / f.use_slope))
       END                                          AS days_to_sat,
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.slope > 0 AND f.slope_ci IS NOT NULL
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - c.cur_val) / (f.slope + f.slope_ci)))
       END                                          AS days_to_sat_lo,
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.slope > 0 AND f.slope_ci IS NOT NULL
                 AND f.slope - f.slope_ci > 0
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - c.cur_val) / (f.slope - f.slope_ci)))
       END                                          AS days_to_sat_hi,
       CASE WHEN f.n  < cfg.min_train_days       THEN 'INSUFFICIENT_HISTORY'
            WHEN f.use_slope = 0 OR f.r2 IS NULL THEN 'FLAT'
            WHEN f.r2 < cfg.r2_gate              THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                          AS quality
FROM   pick f
JOIN   cur c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid AND c.metric = f.metric
CROSS  JOIN cfg;
