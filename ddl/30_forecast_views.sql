--
-- ddl/30_forecast_views.sql -- CAPF_* Tier 1 (pure-SQL linear) forecasts.
-- =====================================================================
-- Linear fits computed three ways -- ordinary least squares via Oracle's
-- built-in REGR_* aggregates, (M9.2) a robust Theil-Sen median-of-pairwise-
-- slopes, and a DRIFT estimator in the rate domain (median day-over-day rate)
-- -- so every projection is reproducible by hand from a slope and the current
-- value. All tuning comes from CAP_CONFIG through the one-row view CAP_CFG.
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
--                          (+lo/hi range), quality. Complete days only.
--
-- day_n is an integer day index off a fixed epoch (DATE '2020-01-01') rather
-- than a raw date number, so slopes are in "per day" and are stable/auditable.
--
-- ---------------------------------------------------------------------
-- Anchoring at today
-- ---------------------------------------------------------------------
-- Every projection starts from the CURRENT value, not from the fitted line:
--
--     proj_h = cur + slope * h        band = proj_h -/+ half_h
--
-- days_to_full / days_to_sat already counted from the current value, so the
-- +30 column and the countdown now describe the same line. The fitted line
-- only supplies the slope. The half-widths are unchanged OLS new-observation
-- quantities (centred on x0 = last_day_n + h), drawn around the anchored
-- projection. A series whose last point sits on its fitted line (FIX_LINEAR)
-- projects exactly as before. icept stays the fitted intercept, so residuals
-- (report/drill_*.sql) are still y - (icept + slope * day_n).
--
-- ---------------------------------------------------------------------
-- Staleness (knob `stale_days`)
-- ---------------------------------------------------------------------
-- newest_day = the newest day of the view's daily source for the same dbid,
-- whatever the series. is_current = 'Y' when last_day >= newest_day -
-- stale_days. A dropped tablespace or a series that stopped arriving keeps
-- its last forecast until AWR purges it, and is_current = 'N' says so. No
-- SYSDATE: the answer depends on the data only.
--
-- ---------------------------------------------------------------------
-- M9.2 -- robust slope (knob `slope_method`: 0 = OLS default, 1 = THEILSEN,
-- 2 = DRIFT, see the next block)
-- ---------------------------------------------------------------------
-- OLS minimises squared error, so ONE step (a bulk load, a partition drop, an
-- import) drags the whole slope with it: FIX_SPIKE grows at 5 MiB/day yet its
-- OLS slope reads ~20 MiB/day because of a single +2 GiB day. The Theil-Sen
-- estimator is the MEDIAN of the pairwise slopes (y_j - y_i)/(x_j - x_i) over
-- every i < j in the training window -- it has a 29% breakdown point, so a
-- minority of stepped pairs cannot move it. Cost is O(n^2): ~4k pairs per
-- series at the shipped 90-day window, computed with a self-join on `w`.
--
-- Theil-Sen is computed ONLY when the knob asks for it (slope_method = 1):
-- the pair self-joins read an input that is empty otherwise, so the default
-- pays nothing for them, and `ts_slope_bpd` / `ts_icept` are NULL. `slope_method`
-- says which estimator the row actually used. When the knob selects
-- THEILSEN, the CHOSEN slope drives `slope_bpd`, `icept`, every `proj_*` point
-- projection, `days_to_full`, the `accel_ratio` numerator and denominator, and
-- the `slope = 0` FLAT test. `r2`, `resid_se` and the M9.1 half-widths stay
-- OLS quantities -- there is no closed-form prediction interval for Theil-Sen
-- in SQL, so the bands are OLS residual bands drawn around the anchored
-- projection, and `slope_ci_bpd` / `days_to_full_lo/hi` remain OLS.
-- (No comment line here may end in a semicolon: SQL*Plus would take it as the
-- statement terminator in plain-SQL context.)
--
-- ---------------------------------------------------------------------
-- DRIFT -- rate-domain estimator (slope_method = 2)
-- ---------------------------------------------------------------------
-- used_bytes is a cumulative level, so the residuals of a line through it
-- are autocorrelated and the OLS slope CI is far too narrow (a driftless
-- random walk often grades OK). DRIFT works on the day-over-day rates of the
-- (reset-aware) training window instead:
--
--     rate_i   = (y_i - y_prev) / (day_n_i - day_n_prev)    within the window
--     slope    = MEDIAN(rate)                 robust to a one-off step
--     sd       = STDDEV_SAMP(rate),  se = sd / SQRT(n_rates)
--     t        = 1.96 + 2.4 / (n_rates - 1)  (the M9.1 approximation)
--     slope CI = t * se
--     half_h   = t * (sd * SQRT(h) + h * se)
--
-- half_h adds the random-walk fan (sd * SQRT(h)) and the rate uncertainty
-- carried h days (h * se) as a plain sum, which is wider than the root of the
-- sum of squares: a conservative band. The first day of the window has no
-- rate (its predecessor is outside the window), so a reset day never
-- contributes its cliff. Projections stay anchored at the current value, so
-- no intercept is fitted: icept is reported as anchor - slope * last_day_n,
-- the line the projections lie on. days_to_full_lo/hi come from slope +- CI.
-- Quality has no R^2 gate: FLAT when slope = 0, LOW_CONFIDENCE when the CI
-- includes 0, else OK (r2 is still the OLS R^2, reported for reference).
-- The median of a strictly alternating series is one of its two rates, not
-- the mean (FIX_ZIGZAG, +50 / -30 MiB, reads 50 MiB/day).
-- drift_slope_bpd / drift_sd_bpd are exposed under every slope_method.
--
-- ---------------------------------------------------------------------
-- CYCLIC -- recurring purges (knob `cyclic_min_cliffs`, default 2)
-- ---------------------------------------------------------------------
-- A rolling-retention tablespace (fill for a month, purge, repeat) has a
-- cliff in every cycle. The M9.3 reset below restarts at the most recent one
-- only, so the post-purge leg reads as fast growth that can never fill, and
-- days_to_full falls through dtf_warn late in every cycle. So the cliffs of
-- the full train_days window are counted with the M9.3 rule. With cycle_n >=
-- cyclic_min_cliffs no reset applies and quality = CYCLIC (after
-- INSUFFICIENT_HISTORY, before FLAT). The row is judged on its peaks:
--
--     cycle_days       = MEDIAN(spacing between consecutive cliffs)
--     cycle_peak_bytes = MAX(used_bytes) in the window, cycle_peak_pct of limit
--     peak_slope_bpd   = REGR_SLOPE through the per-cycle maxima (the maximum
--                        of each segment that ends at a cliff), when there are
--                        at least 3 of them, else NULL
--     days_to_full     = days until the peak line, anchored at the last
--                        cycle maximum, reaches limit_bytes, when
--                        peak_slope_bpd > 0, else NULL
--
-- days_to_full_lo/hi and accel_ratio are NULL for CYCLIC rows. cycle_n is
-- the cliff count on every row (0 = none), the other cycle_* columns are
-- NULL unless quality = CYCLIC. cyclic_min_cliffs = 0 turns the grade off.
-- The count does not depend on reset_on_shrink.
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
--   CYCLIC                tablespaces: cycle_n >= cyclic_min_cliffs (above)
--   FLAT                  chosen slope = 0 (no growth) OR R^2 IS NULL. NOTE:
--                         Oracle's REGR_R2 returns 1 (not NULL) when y has
--                         zero variance and x does not, so a truly flat series
--                         is detected by slope = 0, not by a NULL R^2. R^2 IS
--                         NULL only happens when x has zero variance (single
--                         distinct day), which INSUFFICIENT_HISTORY covers.
--   LOW_CONFIDENCE        R^2 < r2_gate (DRIFT, and CPU under cpu_quality_gate
--                         = 1: the slope CI includes 0)
--   OK                    otherwise
--
-- days_to_full / _lo / _hi are clamped at 0: a limit already below the
-- current usage (an override under the used size) reads 0, not a negative
-- count, and limit_below_used = 'Y' flags the row.
--
-- ---------------------------------------------------------------------
-- Sizing ask (CAPF_TBSPC_FORECAST)
-- ---------------------------------------------------------------------
-- How much space to add, and by when, so the WORST case stays under the
-- ceiling:
--
--     need_gib_h = GREATEST(0, proj_h_hi - limit_bytes) / 2^30   h = 30, 90, 180
--     add_by_day = last_day + days_to_full_lo
--
-- proj_h_hi is the upper edge of the 95% band, so need_gib_h is the space
-- that keeps the high side of the forecast under the ceiling through day h.
-- It reads 0 when the band stays under, and NULL when the band is NULL or
-- the row is CYCLIC (its band is drawn around the sawtooth, not the peaks).
-- A limit already under the current usage asks for at least the overage.
-- add_by_day is the worst-case fill date, NULL when days_to_full_lo is.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPF_TBSPC_FORECAST
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_tbspc_forecast AS
WITH d AS (
        -- used_delta is the raw day-over-day step, computed over the FULL
        -- series (so the first day of the training window still has one) and
        -- used only by the M9.3 / CYCLIC cliff test below. 19c: the OVER
        -- clause is inline -- the standalone WINDOW clause is 21c+.
        SELECT dbid, con_dbid, tablespace_name, day_dt,
               day_dt - DATE '2020-01-01' AS day_n,
               used_bytes, limit_bytes, limit_source,
               used_bytes - LAG(used_bytes) OVER (PARTITION BY dbid, con_dbid, tablespace_name
                                                  ORDER BY day_dt) AS used_delta
        FROM   capd_tbspc_daily
     ),
     -- Staleness reference: the newest day any tablespace of the dbid reached.
     nd AS (
        SELECT dbid, MAX(day_dt) AS newest_day
        FROM   d
        GROUP  BY dbid
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
        SELECT dd.* FROM dd CROSS JOIN cap_cfg cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
     ),
     -- ---- M9.3 / CYCLIC cliff detection, two passes over tw's deltas ----
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
     -- twc = tw with every cliff day marked (is_cliff = 1).
     twc AS (
        SELECT t.*,
               CASE WHEN t.used_delta < -GREATEST(cfg.shrink_mad_k * m.dsig, cfg.abs_floor_bytes)
                    THEN 1 ELSE 0 END AS is_cliff
        FROM   tw t
        LEFT   JOIN dmad m ON m.dbid = t.dbid AND m.con_dbid = t.con_dbid
                          AND m.tablespace_name = t.tablespace_name
        CROSS  JOIN cap_cfg cfg
     ),
     cl AS (
        SELECT dbid, con_dbid, tablespace_name, day_dt,
               day_dt - LAG(day_dt) OVER (PARTITION BY dbid, con_dbid, tablespace_name
                                          ORDER BY day_dt) AS gap_days
        FROM   twc
        WHERE  is_cliff = 1
     ),
     -- One row per tablespace with at least one cliff in the window.
     cyc AS (
        SELECT c.dbid, c.con_dbid, c.tablespace_name,
               COUNT(*)           AS cycle_n,
               MEDIAN(c.gap_days) AS cycle_days,
               MAX(c.day_dt)      AS last_cliff,
               CASE WHEN MAX(cfg.cyclic_min_cliffs) >= 2
                     AND COUNT(*) >= MAX(cfg.cyclic_min_cliffs)
                    THEN 1 ELSE 0 END AS is_cyclic
        FROM   cl c CROSS JOIN cap_cfg cfg
        GROUP  BY c.dbid, c.con_dbid, c.tablespace_name
     ),
     -- M9.3: the MOST RECENT cliff restarts the window (a series purged once
     -- is fit from the purge). A CYCLIC series is not reset.
     rst AS (
        SELECT y.dbid, y.con_dbid, y.tablespace_name,
               y.last_cliff AS reset_day
        FROM   cyc y CROSS JOIN cap_cfg cfg
        WHERE  cfg.reset_on_shrink = 1
          AND  y.is_cyclic = 0
     ),
     -- w = the EFFECTIVE training window: tw, restarted at reset_day when one
     -- was found. Everything downstream (OLS fit, Theil-Sen, DRIFT, recent
     -- fit) uses w, so the reset applies once and consistently.
     w AS (
        SELECT t.* FROM tw t
        LEFT   JOIN rst r ON r.dbid = t.dbid AND r.con_dbid = t.con_dbid
                         AND r.tablespace_name = t.tablespace_name
        WHERE  r.reset_day IS NULL OR t.day_dt >= r.reset_day
     ),
     -- DRIFT input: the day-over-day rate inside w (gap-normalised, so an AWR
     -- gap of k days spreads its step over k days). The first day of w has no
     -- rate, which keeps a reset day's cliff out.
     wr AS (
        SELECT w.*,
               (w.used_bytes - LAG(w.used_bytes) OVER (PARTITION BY w.dbid, w.con_dbid, w.tablespace_name
                                                       ORDER BY w.day_dt))
             / (w.day_n - LAG(w.day_n) OVER (PARTITION BY w.dbid, w.con_dbid, w.tablespace_name
                                             ORDER BY w.day_dt)) AS rate
        FROM   w
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
     -- DRIFT sums (header, "DRIFT"): computed for every row, used when
     -- slope_method = 2.
     dft AS (
        SELECT dbid, con_dbid, tablespace_name,
               MEDIAN(rate)      AS drift,
               STDDEV_SAMP(rate) AS drift_sd,
               COUNT(rate)       AS drift_n
        FROM   wr
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     dband AS (
        SELECT f.*,
               CASE WHEN f.drift_n > 1 THEN 1.96 + 2.4 / (f.drift_n - 1) END AS dtval,
               CASE WHEN f.drift_n > 1 THEN f.drift_sd / SQRT(f.drift_n)  END AS dse
        FROM   dft f
     ),
     -- ---- M9.2 Theil-Sen over the SAME effective window ----
     -- wts is w when slope_method = 1 and empty otherwise, so the O(n^2)
     -- pair join below runs only when Theil-Sen was asked for.
     wts AS (
        SELECT w.* FROM w CROSS JOIN cap_cfg cfg
        WHERE  cfg.slope_method = 1
     ),
     -- One row per ordered pair (i before j); the median of these is the
     -- estimate. Empty for a single-day window, which the pick CTE falls back
     -- from.
     tspair AS (
        SELECT i.dbid, i.con_dbid, i.tablespace_name,
               (j.used_bytes - i.used_bytes) / (j.day_n - i.day_n) AS pslope
        FROM   wts i
        JOIN   wts j ON j.dbid = i.dbid AND j.con_dbid = i.con_dbid
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
        FROM   wts w
        JOIN   tsslp s ON s.dbid = w.dbid AND s.con_dbid = w.con_dbid
                      AND s.tablespace_name = w.tablespace_name
        GROUP  BY w.dbid, w.con_dbid, w.tablespace_name
     ),
     -- ------------------------------------------------------------------
     -- M9.1 prediction-interval arithmetic (95%), classic OLS closed forms:
     --   SSE       = SYY - SXY^2/SXX          (residual sum of squares)
     --   resid_se  = sqrt(SSE / (n-2))        (residual standard error)
     --   tval      = 1.96 + 2.4/(n-2)         (t_{.975,df} approximation, good
     --                                         to ~1% for df>=10, min_train_days
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
     -- ---- which estimator does this row actually use? ----
     -- Falls back to OLS whenever the asked-for estimator could not be
     -- computed (a single-day window has no pairs and no rates), and the
     -- slope_method label always reports what was USED.
     pick AS (
        SELECT b.*,
               t.ts_slope,
               t.ts_icept,
               r.reset_day,
               NVL(y.cycle_n, 0)   AS cycle_n,
               y.cycle_days,
               NVL(y.is_cyclic, 0) AS is_cyclic,
               x.drift, x.drift_sd, x.drift_n, x.dtval, x.dse,
               CASE WHEN cfg.slope_method = 1 AND t.ts_slope IS NOT NULL THEN 'THEILSEN'
                    WHEN cfg.slope_method = 2 AND x.drift    IS NOT NULL THEN 'DRIFT'
                    ELSE 'OLS' END AS slope_method
        FROM   band b
        LEFT   JOIN tsfit t ON t.dbid = b.dbid AND t.con_dbid = b.con_dbid
                           AND t.tablespace_name = b.tablespace_name
        LEFT   JOIN rst r   ON r.dbid = b.dbid AND r.con_dbid = b.con_dbid
                           AND r.tablespace_name = b.tablespace_name
        LEFT   JOIN cyc y   ON y.dbid = b.dbid AND y.con_dbid = b.con_dbid
                           AND y.tablespace_name = b.tablespace_name
        LEFT   JOIN dband x ON x.dbid = b.dbid AND x.con_dbid = b.con_dbid
                           AND x.tablespace_name = b.tablespace_name
        CROSS  JOIN cap_cfg cfg
     ),
     -- use_slope drives the point projections, days_to_full and the FLAT
     -- test. ci_slope / use_ci are the slope and half-width behind the
     -- days_to_full range: OLS for OLS and THEILSEN (M9.2), DRIFT's own for
     -- DRIFT. use_h* are the band half-widths drawn around the projections.
     est AS (
        SELECT p.*,
               CASE p.slope_method WHEN 'THEILSEN' THEN p.ts_slope
                                   WHEN 'DRIFT'    THEN p.drift
                                   ELSE p.slope END                       AS use_slope,
               CASE p.slope_method WHEN 'THEILSEN' THEN p.ts_icept
                                   ELSE p.icept END                       AS use_icept,
               CASE p.slope_method WHEN 'DRIFT' THEN p.drift
                                   ELSE p.slope END                       AS ci_slope,
               CASE p.slope_method WHEN 'DRIFT' THEN p.dtval * p.dse
                                   ELSE p.slope_ci END                    AS use_ci,
               CASE p.slope_method WHEN 'DRIFT' THEN p.dtval * (p.drift_sd * SQRT(30)  +  30 * p.dse)
                                   ELSE p.half_30 END                     AS use_h30,
               CASE p.slope_method WHEN 'DRIFT' THEN p.dtval * (p.drift_sd * SQRT(90)  +  90 * p.dse)
                                   ELSE p.half_90 END                     AS use_h90,
               CASE p.slope_method WHEN 'DRIFT' THEN p.dtval * (p.drift_sd * SQRT(180) + 180 * p.dse)
                                   ELSE p.half_180 END                    AS use_h180,
               CASE p.slope_method WHEN 'DRIFT' THEN p.dtval * (p.drift_sd * SQRT(365) + 365 * p.dse)
                                   ELSE p.half_365 END                    AS use_h365
        FROM   pick p
     ),
     -- ---- CYCLIC peaks ----
     -- seg_no numbers the segments of tw: each cliff day starts a new one.
     -- Segments 0 .. cycle_n - 1 end at a cliff, so their maximum is a cycle
     -- peak. Segment cycle_n is the cycle in progress and is left out.
     seg AS (
        SELECT t.dbid, t.con_dbid, t.tablespace_name, t.day_n, t.used_bytes,
               SUM(t.is_cliff) OVER (PARTITION BY t.dbid, t.con_dbid, t.tablespace_name
                                     ORDER BY t.day_dt ROWS UNBOUNDED PRECEDING) AS seg_no
        FROM   twc t
     ),
     pkc AS (
        SELECT s.dbid, s.con_dbid, s.tablespace_name, s.seg_no,
               MAX(s.used_bytes)                                       AS pk_val,
               MAX(s.day_n) KEEP (DENSE_RANK LAST ORDER BY s.used_bytes) AS pk_day_n
        FROM   seg s
        JOIN   cyc y ON y.dbid = s.dbid AND y.con_dbid = s.con_dbid
                    AND y.tablespace_name = s.tablespace_name
        WHERE  y.is_cyclic = 1
          AND  s.seg_no < y.cycle_n
        GROUP  BY s.dbid, s.con_dbid, s.tablespace_name, s.seg_no
     ),
     pkl AS (
        SELECT dbid, con_dbid, tablespace_name,
               REGR_SLOPE(pk_val, pk_day_n)                         AS pk_slope,
               REGR_COUNT(pk_val, pk_day_n)                         AS pk_n,
               MAX(pk_val) KEEP (DENSE_RANK LAST ORDER BY pk_day_n) AS last_pk_val,
               MAX(pk_day_n)                                        AS last_pk_day_n
        FROM   pkc
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     wpk AS (
        SELECT dbid, con_dbid, tablespace_name, MAX(used_bytes) AS cycle_peak
        FROM   tw
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     -- The "recent" (accel_ratio) fit, over the same effective window so a
     -- post-purge series compares post-purge growth against post-purge growth.
     rw AS (
        SELECT t.* FROM wr t CROSS JOIN cap_cfg cfg
        WHERE  t.day_dt > t.last_day - cfg.recent_days
     ),
     rfit AS (
        SELECT rw.dbid, rw.con_dbid, rw.tablespace_name,
               REGR_SLOPE(rw.used_bytes, rw.day_n)  AS recent_slope,
               REGR_COUNT(rw.used_bytes, rw.day_n)  AS recent_n,
               MEDIAN(rw.rate)                      AS recent_drift
        FROM   rw
        GROUP  BY rw.dbid, rw.con_dbid, rw.tablespace_name
     ),
     -- Same gate as wts.
     rwts AS (
        SELECT rw.* FROM rw CROSS JOIN cap_cfg cfg
        WHERE  cfg.slope_method = 1
     ),
     rtspair AS (
        SELECT i.dbid, i.con_dbid, i.tablespace_name,
               (j.used_bytes - i.used_bytes) / (j.day_n - i.day_n) AS pslope
        FROM   rwts i
        JOIN   rwts j ON j.dbid = i.dbid AND j.con_dbid = i.con_dbid
                     AND j.tablespace_name = i.tablespace_name
                     AND j.day_n > i.day_n
     ),
     rtsslp AS (
        SELECT dbid, con_dbid, tablespace_name, MEDIAN(pslope) AS rts_slope
        FROM   rtspair
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     -- accel_ratio must compare like with like: the recent slope comes from
     -- the same estimator as the row's full-window slope. Mixing estimators
     -- would manufacture acceleration.
     rcomb AS (
        SELECT r.dbid, r.con_dbid, r.tablespace_name, r.recent_n,
               r.recent_slope, rt.rts_slope, r.recent_drift
        FROM   rfit r
        LEFT   JOIN rtsslp rt ON rt.dbid = r.dbid AND rt.con_dbid = r.con_dbid
                             AND rt.tablespace_name = r.tablespace_name
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
     ),
     -- The recent slope that matches the row's estimator.
     fin AS (
        SELECT f.*,
               CASE f.slope_method WHEN 'THEILSEN' THEN r.rts_slope
                                   WHEN 'DRIFT'    THEN r.recent_drift
                                   ELSE r.recent_slope END AS recent_use
        FROM   est f
        LEFT   JOIN rcomb r ON r.dbid = f.dbid AND r.con_dbid = f.con_dbid
                           AND r.tablespace_name = f.tablespace_name
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
       -- DRIFT fits no intercept: report the line the projections lie on.
       CASE f.slope_method WHEN 'DRIFT' THEN c.cur_used - f.use_slope * f.last_day_n
                           ELSE f.use_icept END           AS icept,
       f.slope                                            AS ols_slope_bpd,
       f.ts_slope                                         AS ts_slope_bpd,
       f.ts_icept,
       f.slope_method,
       f.r2,
       -- Anchored at today: cur_used + slope * h (header, "Anchoring").
       c.cur_used + f.use_slope * 30                      AS proj_30_bytes,
       c.cur_used + f.use_slope * 90                      AS proj_90_bytes,
       c.cur_used + f.use_slope * 180                     AS proj_180_bytes,
       c.cur_used + f.use_slope * 365                     AS proj_365_bytes,
       -- M9.1: 95% prediction bands on each projection. OLS residual
       -- half-widths for OLS and THEILSEN (there is no closed-form Theil-Sen
       -- interval in SQL), the random-walk half-widths for DRIFT, drawn
       -- around the anchored projection either way.
       c.cur_used + f.use_slope * 30  - f.use_h30         AS proj_30_lo,
       c.cur_used + f.use_slope * 30  + f.use_h30         AS proj_30_hi,
       c.cur_used + f.use_slope * 90  - f.use_h90         AS proj_90_lo,
       c.cur_used + f.use_slope * 90  + f.use_h90         AS proj_90_hi,
       c.cur_used + f.use_slope * 180 - f.use_h180        AS proj_180_lo,
       c.cur_used + f.use_slope * 180 + f.use_h180        AS proj_180_hi,
       c.cur_used + f.use_slope * 365 - f.use_h365        AS proj_365_lo,
       c.cur_used + f.use_slope * 365 + f.use_h365        AS proj_365_hi,
       f.use_ci                                           AS slope_ci_bpd,
       -- CYCLIC: days until the peak line (anchored at the last cycle peak,
       -- growing peak_slope_bpd a day) reaches the limit, counted from
       -- last_day. Otherwise from cur_used along the chosen slope.
       CASE WHEN f.is_cyclic = 1 THEN
                 CASE WHEN p.pk_n >= 3 AND p.pk_slope > 0
                      THEN GREATEST(0, FLOOR((c.limit_bytes - p.last_pk_val) / p.pk_slope
                                             - (f.last_day_n - p.last_pk_day_n)))
                 END
            WHEN f.use_slope > 0
            THEN GREATEST(0, FLOOR((c.limit_bytes - c.cur_used) / f.use_slope))
       END                                                AS days_to_full,
       -- ... and a range on days_to_full from the slope's 95% CI (OLS for
       -- OLS / THEILSEN, DRIFT's own for DRIFT, none for CYCLIC).
       -- lo = WORST case (fastest plausible growth, fills soonest).
       -- hi = BEST case, NULL when the slow edge of the CI is <= 0
       -- ("might never fill at the low end of plausible growth").
       -- All three clamp at 0 when the limit is already below cur_used.
       -- NB: no trailing semicolon in these comments -- SQL*Plus would
       -- treat it as the statement terminator mid-view.
       CASE WHEN f.is_cyclic = 0 AND f.ci_slope > 0 AND f.use_ci IS NOT NULL
            THEN GREATEST(0, FLOOR((c.limit_bytes - c.cur_used) / (f.ci_slope + f.use_ci)))
       END                                                AS days_to_full_lo,
       CASE WHEN f.is_cyclic = 0 AND f.ci_slope > 0 AND f.use_ci IS NOT NULL
                 AND f.ci_slope - f.use_ci > 0
            THEN GREATEST(0, FLOOR((c.limit_bytes - c.cur_used) / (f.ci_slope - f.use_ci)))
       END                                                AS days_to_full_hi,
       f.recent_use                                       AS recent_slope_bpd,
       -- M7.7: only meaningful when the baseline slope is real growth. Below
       -- accel_slope_floor_bpd (default 1 MiB/day) a near-flat series divides
       -- by ~0 and reports an absurd 500x "acceleration", so the ratio is NULL
       -- instead. slope = 0 (FLAT) was already NULL and still is. A CYCLIC
       -- window has no single growth rate to compare against.
       CASE WHEN f.is_cyclic = 0 AND ABS(f.use_slope) >= cfg.accel_slope_floor_bpd
            THEN f.recent_use / f.use_slope
       END                                                AS accel_ratio,
       CASE WHEN f.n  < cfg.min_train_days THEN 'INSUFFICIENT_HISTORY'
            WHEN f.is_cyclic = 1           THEN 'CYCLIC'
            WHEN f.use_slope = 0
              OR (f.slope_method <> 'DRIFT' AND f.r2 IS NULL) THEN 'FLAT'
            WHEN f.slope_method = 'DRIFT'
                 THEN CASE WHEN ABS(f.use_slope) > f.use_ci THEN 'OK'
                           ELSE 'LOW_CONFIDENCE' END
            WHEN f.r2 < cfg.r2_gate        THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                                AS quality,
       -- The ceiling is already under the current usage: days_to_full reads
       -- 0 (or NULL when not growing) and pct_used is over 100.
       CASE WHEN c.limit_bytes < c.cur_used THEN 'Y' ELSE 'N' END AS limit_below_used,
       n.newest_day,
       CASE WHEN f.last_day >= n.newest_day - cfg.stale_days
            THEN 'Y' ELSE 'N' END                         AS is_current,
       f.drift                                            AS drift_slope_bpd,
       f.drift_sd                                         AS drift_sd_bpd,
       f.cycle_n,
       CASE WHEN f.is_cyclic = 1 THEN f.cycle_days END    AS cycle_days,
       CASE WHEN f.is_cyclic = 1 THEN k.cycle_peak END    AS cycle_peak_bytes,
       CASE WHEN f.is_cyclic = 1 AND c.limit_bytes > 0
            THEN ROUND(100 * k.cycle_peak / c.limit_bytes, 1)
       END                                                AS cycle_peak_pct,
       CASE WHEN f.is_cyclic = 1 AND p.pk_n >= 3
            THEN p.pk_slope END                           AS peak_slope_bpd,
       -- Sizing ask (header): space to add so the band's high edge stays
       -- under the ceiling through +h, and the worst-case fill date.
       CASE WHEN f.is_cyclic = 0
            THEN GREATEST(0, c.cur_used + f.use_slope * 30  + f.use_h30  - c.limit_bytes) / 1073741824
       END                                                AS need_gib_30,
       CASE WHEN f.is_cyclic = 0
            THEN GREATEST(0, c.cur_used + f.use_slope * 90  + f.use_h90  - c.limit_bytes) / 1073741824
       END                                                AS need_gib_90,
       CASE WHEN f.is_cyclic = 0
            THEN GREATEST(0, c.cur_used + f.use_slope * 180 + f.use_h180 - c.limit_bytes) / 1073741824
       END                                                AS need_gib_180,
       f.last_day
         + CASE WHEN f.is_cyclic = 0 AND f.ci_slope > 0 AND f.use_ci IS NOT NULL
                THEN GREATEST(0, FLOOR((c.limit_bytes - c.cur_used) / (f.ci_slope + f.use_ci)))
           END                                            AS add_by_day
FROM   fin f
JOIN   cur  c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid
             AND c.tablespace_name = f.tablespace_name
JOIN   nd   n ON n.dbid = f.dbid
LEFT   JOIN pkl p ON p.dbid = f.dbid AND p.con_dbid = f.con_dbid
                 AND p.tablespace_name = f.tablespace_name
LEFT   JOIN wpk k ON k.dbid = f.dbid AND k.con_dbid = f.con_dbid
                 AND k.tablespace_name = f.tablespace_name
CROSS  JOIN cap_cfg cfg;

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
-- days_to_sat = days until the anchored line (anchor_value + slope * d)
-- crosses cpu_sat_pct; DB_CPU_SEC has no fixed ceiling so its days_to_sat is
-- NULL.
--
-- Only COMPLETE days are fitted (is_complete = 'Y' in the daily views): a
-- partial, restart or outage day averages over less than complete_day_pct
-- of the day and would pull the line. last_day, train_start, cur_val and the
-- anchor all come from complete days. newest_day counts every day that has a
-- value, complete or not, so today's partial day does not make a series stale.
--
-- Weekday / weekend deseasoning (knob cpu_deseason, default 1). A host that
-- runs 60% on weekdays and 20% at weekends has most of its variance in the
-- weekly pattern, so R^2 of any trend stays near 0 and a real trend never
-- grades OK. With cpu_deseason = 1 the fit input is
--     fval = val - AVG(val of the same day type) + AVG(val)
-- over the training window, day type = weekday or Saturday / Sunday. A
-- perfectly periodic weekly pattern drops out and a ramp survives. Every fit
-- quantity (slope, icept, r2, bands, Theil-Sen, DRIFT rates) is computed on
-- fval. deseasoned = 'Y' / 'N' says which input the row used.
--
-- Quality gate (knob cpu_quality_gate, default 1). 1 = slope significance:
-- OK when |slope| > slope_ci_per_day, else LOW_CONFIDENCE (FLAT when the
-- slope is 0). 0 = the legacy R^2 >= r2_gate test. slope_sig = 'Y' when
-- |slope| > slope_ci_per_day, under either gate. DRIFT rows use their own
-- significance rule whatever the gate. Tablespace and series fits keep their
-- gates.
--
-- Anchor. A weekly-seasonal metric's last complete day is a weekday or a
-- weekend sample, so anchoring at cur_val (as tablespaces anchor at
-- cur_used, a level) would swing +30 with the weekday of the last day.
-- anchor_value = MEDIAN(val) over the complete days in the last shift_days
-- days (raw values), and every projection and days_to_sat start there.
-- For BUSY_P95 / DB_CPU_P95 the same median is recent_p95_med, and hot_now =
-- 'Y' when it is at or above cpu_sat_pct: saturated now, whatever the trend.
--
-- M9.2 applies here too (same pairwise-median pattern, same slope_method
-- knob and gate, same "bands stay OLS" rule), and so does DRIFT (rate =
-- day-over-day change of fval). M9.3 does NOT: a change-point reset is
-- defined on a tablespace SHRINK (a purge), which has no CPU analogue -- a
-- CPU level shift is M10.3's job, not this one.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_cpu_trend AS
WITH src AS (
        SELECT dbid, con_dbid, 'BUSY_PCT'   AS metric, day_dt, busy_pct      AS val, is_complete
        FROM   capd_cpu_daily    WHERE busy_pct      IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'BUSY_P95'   AS metric, day_dt, busy_p95      AS val, is_complete
        FROM   capd_cpu_daily    WHERE busy_p95      IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'BUSY_PEAK'  AS metric, day_dt, busy_peak_pct AS val, is_complete
        FROM   capd_cpu_daily    WHERE busy_peak_pct IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_SEC' AS metric, day_dt, db_cpu_sec    AS val, is_complete
        FROM   capd_dbtime_daily WHERE db_cpu_sec    IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_PCT' AS metric, day_dt, db_cpu_pct    AS val, is_complete
        FROM   capd_dbtime_daily WHERE db_cpu_pct    IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_P95' AS metric, day_dt, db_cpu_p95_pct AS val, is_complete
        FROM   capd_dbtime_daily WHERE db_cpu_p95_pct IS NOT NULL
     ),
     -- Staleness reference: every day with a value, complete or not.
     nd AS (
        SELECT dbid, MAX(day_dt) AS newest_day
        FROM   src
        GROUP  BY dbid
     ),
     -- The fit input: complete days only. 1900-01-01 was a Monday, so
     -- MOD(.., 7) >= 5 is Saturday or Sunday whatever the NLS settings.
     d AS (
        SELECT s.dbid, s.con_dbid, s.metric, s.day_dt, s.val,
               s.day_dt - DATE '2020-01-01' AS day_n,
               CASE WHEN MOD(TRUNC(s.day_dt) - DATE '1900-01-01', 7) >= 5
                    THEN 1 ELSE 0 END AS is_wkend
        FROM   src s
        WHERE  s.is_complete = 'Y'
     ),
     b AS (
        SELECT dbid, con_dbid, metric, MAX(day_dt) AS last_day
        FROM   d GROUP BY dbid, con_dbid, metric
     ),
     dd AS (
        SELECT d.dbid, d.con_dbid, d.metric, d.day_dt, d.day_n, d.val, d.is_wkend,
               b.last_day, b.last_day - DATE '2020-01-01' AS last_day_n
        FROM   d JOIN b ON b.dbid = d.dbid AND b.con_dbid = d.con_dbid AND b.metric = d.metric
     ),
     w0 AS (
        SELECT dd.* FROM dd CROSS JOIN cap_cfg cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
     ),
     -- fval = the fit input (header, "deseasoning").
     w AS (
        SELECT w0.*,
               CASE WHEN cfg.cpu_deseason = 1
                    THEN w0.val
                         - AVG(w0.val) OVER (PARTITION BY w0.dbid, w0.con_dbid, w0.metric, w0.is_wkend)
                         + AVG(w0.val) OVER (PARTITION BY w0.dbid, w0.con_dbid, w0.metric)
                    ELSE w0.val
               END AS fval
        FROM   w0 CROSS JOIN cap_cfg cfg
     ),
     wr AS (
        SELECT w.*,
               (w.fval - LAG(w.fval) OVER (PARTITION BY w.dbid, w.con_dbid, w.metric ORDER BY w.day_dt))
             / (w.day_n - LAG(w.day_n) OVER (PARTITION BY w.dbid, w.con_dbid, w.metric ORDER BY w.day_dt)) AS rate
        FROM   w
     ),
     fit AS (
        SELECT w.dbid, w.con_dbid, w.metric,
               MAX(w.last_day)                 AS last_day,
               MAX(w.last_day_n)               AS last_day_n,
               MIN(w.day_dt)                   AS train_start,
               REGR_SLOPE(w.fval, w.day_n)     AS slope,
               REGR_INTERCEPT(w.fval, w.day_n) AS icept,
               REGR_R2(w.fval, w.day_n)        AS r2,
               REGR_COUNT(w.fval, w.day_n)     AS n,
               REGR_SXX(w.fval, w.day_n)       AS sxx,
               REGR_SYY(w.fval, w.day_n)       AS syy,
               REGR_SXY(w.fval, w.day_n)       AS sxy,
               REGR_AVGX(w.fval, w.day_n)      AS xbar
        FROM   w
        GROUP  BY w.dbid, w.con_dbid, w.metric
     ),
     -- DRIFT, as in CAPF_TBSPC_FORECAST.
     dband AS (
        SELECT x.*,
               CASE WHEN x.drift_n > 1 THEN 1.96 + 2.4 / (x.drift_n - 1) END AS dtval,
               CASE WHEN x.drift_n > 1 THEN x.drift_sd / SQRT(x.drift_n)  END AS dse
        FROM  (SELECT dbid, con_dbid, metric,
                      MEDIAN(rate)      AS drift,
                      STDDEV_SAMP(rate) AS drift_sd,
                      COUNT(rate)       AS drift_n
               FROM   wr
               GROUP  BY dbid, con_dbid, metric) x
     ),
     -- M9.2 Theil-Sen, identical pattern (and gate) to CAPF_TBSPC_FORECAST.
     wts AS (
        SELECT w.* FROM w CROSS JOIN cap_cfg cfg
        WHERE  cfg.slope_method = 1
     ),
     tspair AS (
        SELECT i.dbid, i.con_dbid, i.metric,
               (j.fval - i.fval) / (j.day_n - i.day_n) AS pslope
        FROM   wts i
        JOIN   wts j ON j.dbid = i.dbid AND j.con_dbid = i.con_dbid
                    AND j.metric = i.metric AND j.day_n > i.day_n
     ),
     tsslp AS (
        SELECT dbid, con_dbid, metric, MEDIAN(pslope) AS ts_slope
        FROM   tspair GROUP BY dbid, con_dbid, metric
     ),
     tsfit AS (
        SELECT w.dbid, w.con_dbid, w.metric,
               MAX(s.ts_slope)                        AS ts_slope,
               MEDIAN(w.fval - s.ts_slope * w.day_n)  AS ts_icept
        FROM   wts w
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
               x.drift, x.drift_sd, x.drift_n, x.dtval, x.dse,
               CASE WHEN cfg.slope_method = 1 AND t.ts_slope IS NOT NULL THEN 'THEILSEN'
                    WHEN cfg.slope_method = 2 AND x.drift    IS NOT NULL THEN 'DRIFT'
                    ELSE 'OLS' END AS slope_method
        FROM   band b
        LEFT   JOIN tsfit t ON t.dbid = b.dbid AND t.con_dbid = b.con_dbid
                           AND t.metric = b.metric
        LEFT   JOIN dband x ON x.dbid = b.dbid AND x.con_dbid = b.con_dbid
                           AND x.metric = b.metric
        CROSS  JOIN cap_cfg cfg
     ),
     -- Same roles as in CAPF_TBSPC_FORECAST's est CTE.
     est AS (
        SELECT p.*,
               CASE p.slope_method WHEN 'THEILSEN' THEN p.ts_slope
                                   WHEN 'DRIFT'    THEN p.drift
                                   ELSE p.slope END                      AS use_slope,
               CASE p.slope_method WHEN 'THEILSEN' THEN p.ts_icept
                                   ELSE p.icept END                      AS use_icept,
               CASE p.slope_method WHEN 'DRIFT' THEN p.drift
                                   ELSE p.slope END                      AS ci_slope,
               CASE p.slope_method WHEN 'DRIFT' THEN p.dtval * p.dse
                                   ELSE p.slope_ci END                   AS use_ci,
               CASE p.slope_method WHEN 'DRIFT' THEN p.dtval * (p.drift_sd * SQRT(30) + 30 * p.dse)
                                   ELSE p.half_30 END                    AS use_h30,
               CASE p.slope_method WHEN 'DRIFT' THEN p.dtval * (p.drift_sd * SQRT(90) + 90 * p.dse)
                                   ELSE p.half_90 END                    AS use_h90
        FROM   pick p
     ),
     cur AS (
        SELECT dbid, con_dbid, metric,
               MAX(val) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS cur_val
        FROM   d GROUP BY dbid, con_dbid, metric
     ),
     -- The smoothed level every projection starts from (header, "Anchor").
     anc AS (
        SELECT dd.dbid, dd.con_dbid, dd.metric, MEDIAN(dd.val) AS anchor_value
        FROM   dd CROSS JOIN cap_cfg cfg
        WHERE  dd.day_dt > dd.last_day - GREATEST(cfg.shift_days, 1)
        GROUP  BY dd.dbid, dd.con_dbid, dd.metric
     )
SELECT f.dbid,
       f.con_dbid,
       f.metric,
       f.last_day,
       f.n                                          AS train_n,
       f.train_start,
       c.cur_val,
       f.use_slope                                  AS slope_per_day,
       CASE f.slope_method WHEN 'DRIFT' THEN a.anchor_value - f.use_slope * f.last_day_n
                           ELSE f.use_icept END     AS icept,
       f.slope                                      AS ols_slope_per_day,
       f.ts_slope                                   AS ts_slope_per_day,
       f.ts_icept,
       f.slope_method,
       f.r2,
       -- Anchored at the smoothed level, anchor_value + slope * h.
       a.anchor_value + f.use_slope * 30            AS proj_30,
       a.anchor_value + f.use_slope * 90            AS proj_90,
       -- M9.1: 95% prediction bands + days_to_sat range (same semantics as
       -- CAPF_TBSPC_FORECAST: lo = worst case / soonest, hi = best case,
       -- hi NULL when the slow edge of the slope CI is <= 0). OLS half-widths
       -- and slope CI for OLS / THEILSEN (M9.2), DRIFT's own for DRIFT.
       a.anchor_value + f.use_slope * 30 - f.use_h30 AS proj_30_lo,
       a.anchor_value + f.use_slope * 30 + f.use_h30 AS proj_30_hi,
       a.anchor_value + f.use_slope * 90 - f.use_h90 AS proj_90_lo,
       a.anchor_value + f.use_slope * 90 + f.use_h90 AS proj_90_hi,
       f.use_ci                                     AS slope_ci_per_day,
       -- GREATEST(0,...): a level already above the saturation threshold
       -- reads 0 (saturated now) rather than a negative "days".
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.use_slope > 0
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - a.anchor_value) / f.use_slope))
       END                                          AS days_to_sat,
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.ci_slope > 0 AND f.use_ci IS NOT NULL
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - a.anchor_value) / (f.ci_slope + f.use_ci)))
       END                                          AS days_to_sat_lo,
       CASE WHEN f.metric <> 'DB_CPU_SEC' AND f.ci_slope > 0 AND f.use_ci IS NOT NULL
                 AND f.ci_slope - f.use_ci > 0
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - a.anchor_value) / (f.ci_slope - f.use_ci)))
       END                                          AS days_to_sat_hi,
       CASE WHEN f.n  < cfg.min_train_days THEN 'INSUFFICIENT_HISTORY'
            WHEN f.use_slope = 0
              OR (f.slope_method <> 'DRIFT' AND f.r2 IS NULL) THEN 'FLAT'
            WHEN f.slope_method = 'DRIFT' OR cfg.cpu_quality_gate = 1
                 THEN CASE WHEN ABS(f.use_slope) > f.use_ci THEN 'OK'
                           ELSE 'LOW_CONFIDENCE' END
            WHEN f.r2 < cfg.r2_gate        THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                          AS quality,
       n.newest_day,
       CASE WHEN f.last_day >= n.newest_day - cfg.stale_days
            THEN 'Y' ELSE 'N' END                   AS is_current,
       f.drift                                      AS drift_slope_per_day,
       f.drift_sd                                   AS drift_sd_per_day,
       CASE WHEN ABS(f.use_slope) > f.use_ci THEN 'Y' ELSE 'N' END AS slope_sig,
       CASE WHEN cfg.cpu_deseason = 1 THEN 'Y' ELSE 'N' END        AS deseasoned,
       a.anchor_value,
       CASE WHEN f.metric IN ('BUSY_P95', 'DB_CPU_P95') THEN a.anchor_value END AS recent_p95_med,
       CASE WHEN f.metric IN ('BUSY_P95', 'DB_CPU_P95')
            THEN CASE WHEN a.anchor_value >= cfg.cpu_sat_pct THEN 'Y' ELSE 'N' END
       END                                          AS hot_now
FROM   est f
JOIN   cur c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid AND c.metric = f.metric
JOIN   anc a ON a.dbid = f.dbid AND a.con_dbid = f.con_dbid AND a.metric = f.metric
JOIN   nd  n ON n.dbid = f.dbid
CROSS  JOIN cap_cfg cfg;
