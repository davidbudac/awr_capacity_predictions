--
-- ddl/40_anomaly_views.sql -- CAPA_* deterministic rolling-MAD anomalies.
-- =====================================================================
-- Robust (median + MAD) outlier flags. Every flag is reproducible by hand:
-- the views expose value, baseline median, MAD-sigma, the k*sigma threshold,
-- and the robust z-score, so an operator can re-derive any HIGH/LOW arithmetic.
--
-- MAD_sigma = MEDIAN(|x - median|) * 1.4826 (the 1.4826 makes MAD a consistent
-- estimator of the standard deviation for normal data). Rolling MAD cannot be
-- written with nested window MEDIANs, so each view uses a trailing-window
-- self-join computed in two passes (median first, then MAD about that median),
-- always EXCLUDING the current day so a spike cannot inflate its own baseline.
--
--   CAPA_TBSPC_ANOM -- on daily used_bytes delta, trailing mad_window_days.
--                      Threshold is GREATEST(k*sigma, abs_floor_bytes) so a
--                      jump from an exactly-flat baseline (MAD=0) still flags
--                      and sub-floor wiggles never do.
--   CAPA_CPU_ANOM   -- on daily busy%, baseline = the prior dow_weeks SAME
--                      weekdays (handles weekly seasonality deterministically).
--                      A cpu_min_mad_pct floor on sigma plays the abs_floor
--                      role for a perfectly flat seasonal baseline. M10.5:
--                      gap-flagged days (CAPD_CPU_DAILY.gap_flag = 'Y') are
--                      neither scored nor used as baseline.
--   CAPA_CPU_SHIFT  -- M10.3 LEVEL SHIFT, not an outlier: a sustained step
--                      that never crosses k*MAD on any single day. Recent
--                      window median vs the baseline median before it, with
--                      an N-of-M confirmation. One row per (container,
--                      metric) -- current state, not a per-day series.
--
-- Self-join cost is O(days * window) at daily grain -- fine for <= ~400 days.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPA_TBSPC_ANOM -- tablespace daily-growth anomalies.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capa_tbspc_anom AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'mad_k'           THEN cfg_value END) AS mad_k,
               MAX(CASE WHEN cfg_name = 'mad_window_days' THEN cfg_value END) AS mad_window_days,
               MAX(CASE WHEN cfg_name = 'abs_floor_bytes' THEN cfg_value END) AS abs_floor_bytes,
               MAX(CASE WHEN cfg_name = 'tbspc_min_hist'  THEN cfg_value END) AS min_hist
        FROM   cap_config
     ),
     -- val is the per-day growth RATE (gap-normalized), so a multi-day AWR gap
     -- is not mistaken for a one-day spike. raw_delta + day_gap are carried
     -- through for the report's audit trail.
     base AS (
        SELECT dbid, con_dbid, tablespace_name, day_dt,
               used_rate_bpd    AS val,
               used_delta_bytes AS raw_delta,
               day_gap
        FROM   capd_tbspc_delta
        WHERE  used_rate_bpd IS NOT NULL
     ),
     med AS (
        SELECT c.dbid, c.con_dbid, c.tablespace_name, c.day_dt,
               c.val, c.raw_delta, c.day_gap,
               MEDIAN(h.val) AS med, COUNT(h.val) AS n_hist
        FROM   base c
        JOIN   base h
          ON   h.dbid = c.dbid AND h.con_dbid = c.con_dbid
         AND   h.tablespace_name = c.tablespace_name
         AND   h.day_dt BETWEEN c.day_dt - (SELECT mad_window_days FROM cfg)
                            AND c.day_dt - 1
        GROUP  BY c.dbid, c.con_dbid, c.tablespace_name, c.day_dt,
                  c.val, c.raw_delta, c.day_gap
     ),
     madc AS (
        SELECT m.dbid, m.con_dbid, m.tablespace_name, m.day_dt,
               m.val, m.raw_delta, m.day_gap, m.med, m.n_hist,
               MEDIAN(ABS(h.val - m.med)) * 1.4826 AS mad_sigma
        FROM   med m
        JOIN   base h
          ON   h.dbid = m.dbid AND h.con_dbid = m.con_dbid
         AND   h.tablespace_name = m.tablespace_name
         AND   h.day_dt BETWEEN m.day_dt - (SELECT mad_window_days FROM cfg)
                            AND m.day_dt - 1
        GROUP  BY m.dbid, m.con_dbid, m.tablespace_name, m.day_dt,
                  m.val, m.raw_delta, m.day_gap, m.med, m.n_hist
     )
SELECT a.dbid,
       a.con_dbid,
       a.tablespace_name,
       a.day_dt,
       a.raw_delta                                                 AS used_delta_bytes,
       a.day_gap,
       a.val                                                       AS used_rate_bpd,
       a.med                                                       AS median_rate_bpd,
       a.mad_sigma,
       a.n_hist,
       a.val - a.med                                               AS dev_bpd,
       GREATEST(cfg.mad_k * a.mad_sigma, cfg.abs_floor_bytes)      AS threshold_bpd,
       (a.val - a.med) / NULLIF(a.mad_sigma, 0)                    AS robust_z,
       CASE
           WHEN a.n_hist >= cfg.min_hist
            AND (a.val - a.med) >  GREATEST(cfg.mad_k * a.mad_sigma, cfg.abs_floor_bytes) THEN 'HIGH'
           WHEN a.n_hist >= cfg.min_hist
            AND (a.med - a.val) >  GREATEST(cfg.mad_k * a.mad_sigma, cfg.abs_floor_bytes) THEN 'LOW'
           ELSE NULL
       END                                                         AS anomaly_flag
FROM   madc a CROSS JOIN cfg;

-- --------------------------------------------------------------------
-- CAPA_CPU_ANOM -- host CPU busy% anomalies vs a same-weekday baseline.
-- For each day we generate the prior dow_weeks matching weekdays
-- (day - 7*level) via CONNECT BY, take their median + MAD, and flag when the
-- day deviates by more than k * GREATEST(MAD_sigma, cpu_min_mad_pct). The
-- floor keeps an exactly-flat weekly baseline (MAD=0) from swallowing a real
-- jump while never flagging sub-floor jitter.
--
-- M10.5 AWR GAPS. A day whose CAPD_CPU_DAILY row carries gap_flag = 'Y' spans
-- more than one calendar day of counters (see the comment block in ddl/20), so
-- its busy% is an average over a period, not over a day. Such a day is
--   * NEVER used as a baseline observation (the `h` side of the join, so a
--     36 h average cannot drag a same-weekday median around), and
--   * NEVER flagged itself (anomaly_flag stays NULL) -- an AWR outage is an
--     instrumentation event, not a CPU event, and paging on it is noise.
-- gap_flag and day_gap ride through so the report can say WHY a visibly odd
-- day is unflagged.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capa_cpu_anom AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'mad_k'            THEN cfg_value END) AS mad_k,
               MAX(CASE WHEN cfg_name = 'dow_weeks'        THEN cfg_value END) AS dow_weeks,
               MAX(CASE WHEN cfg_name = 'cpu_min_mad_pct'  THEN cfg_value END) AS min_mad,
               MAX(CASE WHEN cfg_name = 'cpu_min_dow_hist' THEN cfg_value END) AS min_hist
        FROM   cap_config
     ),
     base AS (
        SELECT dbid, con_dbid, day_dt, busy_pct AS val, gap_flag, day_gap
        FROM   capd_cpu_daily
        WHERE  busy_pct IS NOT NULL
     ),
     gen AS (
        SELECT LEVEL AS lv FROM dual CONNECT BY LEVEL <= (SELECT dow_weeks FROM cfg)
     ),
     hist AS (
        SELECT c.dbid, c.con_dbid, c.day_dt, c.val, c.gap_flag, c.day_gap,
               h.val AS hval
        FROM   base c
        CROSS  JOIN gen g
        JOIN   base h
          ON   h.dbid = c.dbid AND h.con_dbid = c.con_dbid
         AND   h.day_dt = c.day_dt - 7 * g.lv
         -- M10.5: gap days never join as BASELINE observations.
         AND   h.gap_flag = 'N'
     ),
     med AS (
        SELECT dbid, con_dbid, day_dt, val, gap_flag, day_gap,
               MEDIAN(hval) AS med, COUNT(hval) AS n_hist
        FROM   hist
        GROUP  BY dbid, con_dbid, day_dt, val, gap_flag, day_gap
     ),
     madc AS (
        SELECT m.dbid, m.con_dbid, m.day_dt, m.val, m.gap_flag, m.day_gap,
               m.med, m.n_hist,
               MEDIAN(ABS(h.hval - m.med)) * 1.4826 AS mad_sigma
        FROM   med m
        JOIN   hist h
          ON   h.dbid = m.dbid AND h.con_dbid = m.con_dbid AND h.day_dt = m.day_dt
        GROUP  BY m.dbid, m.con_dbid, m.day_dt, m.val, m.gap_flag, m.day_gap,
                  m.med, m.n_hist
     )
SELECT a.dbid,
       a.con_dbid,
       a.day_dt,
       a.val                                                        AS busy_pct,
       a.med                                                        AS median_pct,
       a.mad_sigma,
       a.n_hist,
       a.gap_flag,
       a.day_gap,
       a.val - a.med                                                AS dev_pct,
       cfg.mad_k * GREATEST(a.mad_sigma, cfg.min_mad)               AS threshold_pct,
       (a.val - a.med) / NULLIF(GREATEST(a.mad_sigma, cfg.min_mad), 0) AS robust_z,
       CASE
           WHEN a.gap_flag = 'Y' THEN NULL          -- M10.5: never flag a gap day
           WHEN a.n_hist >= cfg.min_hist
            AND (a.val - a.med) >  cfg.mad_k * GREATEST(a.mad_sigma, cfg.min_mad) THEN 'HIGH'
           WHEN a.n_hist >= cfg.min_hist
            AND (a.med - a.val) >  cfg.mad_k * GREATEST(a.mad_sigma, cfg.min_mad) THEN 'LOW'
           ELSE NULL
       END                                                          AS anomaly_flag
FROM   madc a CROSS JOIN cfg;

-- --------------------------------------------------------------------
-- CAPA_CPU_SHIFT (M10.3) -- sustained LEVEL SHIFTS in the CPU series.
-- --------------------------------------------------------------------
-- The rolling-MAD views above answer "was YESTERDAY unusual?". They are blind
-- to the failure mode that actually matters for capacity: a new release, a new
-- workload or a consolidation move that adds a permanent +15 points and then
-- stays there. Every individual day sits inside k*MAD of its own weekday
-- baseline, so nothing ever flags -- yet the machine now runs materially
-- hotter than it did a month ago, and the trend fit is too noisy to say so.
--
-- So this view compares WINDOWS, not days. Per (dbid, con_dbid, metric):
--   recent window   = the last `shift_days` days (knob, default 7)
--   baseline window = the `shift_baseline_days` days (knob, default 28)
--                     immediately BEFORE the recent window
--   shift_pct       = recent_med - base_med, in percentage POINTS (all three
--                     metrics are already percentages, so a difference of
--                     medians is points, never a ratio)
-- and flags 'UP' when ALL of
--   (a) shift_pct > shift_min_pct  (knob, default 15 points)
--   (b) n_recent >= shift_days     (a full recent window -- gap days are
--       excluded from the source, so a window with a gap in it cannot flag)
--   (c) n_base   >= shift_days     (enough baseline to have a median at all)
--   (d) n_above  >= shift_days     (the N-of-M confirmation: EVERY day of the
--       recent window is above base_med + max(base_mad_sigma,
--       cpu_min_mad_pct)). This is what separates a genuine step from one
--       loud day dragging a 7-day median: a single spike moves the median but
--       cannot put all seven days over the line.
-- 'DOWN' is the mirror image (workload left, or a container was moved off).
-- Otherwise NULL, and the row still exists -- it is the CURRENT STATE of the
-- series, one row per series, so a poller can read it unconditionally.
--
-- Medians (not means) on both sides, and a MAD-based day threshold, keep the
-- whole thing robust: an outage day, a batch spike or a single idle Sunday
-- shifts nothing. Every input is exposed (recent_med, base_med,
-- base_mad_sigma, n_recent, n_base, n_above, n_below, the thresholds), so a
-- flag can be re-derived by hand from CAPD_CPU_DAILY / CAPD_DBTIME_DAILY.
--
-- M10.5: gap-flagged days are dropped from BOTH windows -- a 36 h average is
-- not a day, and letting it into a 7-day median is exactly how a maintenance
-- window turns into a fake "level shift".
--
-- Metrics: BUSY_PCT and BUSY_P95 (host, per CAPD_CPU_DAILY) and DB_CPU_PCT
-- (per container, per CAPD_DBTIME_DAILY). BUSY_PEAK is deliberately left out:
-- it is already a same-window average of BUSY_PCT's busiest hours, so it
-- shifts with them and would only duplicate the alert.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capa_cpu_shift AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'shift_days'          THEN cfg_value END) AS shift_days,
               MAX(CASE WHEN cfg_name = 'shift_baseline_days' THEN cfg_value END) AS base_days,
               MAX(CASE WHEN cfg_name = 'shift_min_pct'       THEN cfg_value END) AS min_pct,
               MAX(CASE WHEN cfg_name = 'cpu_min_mad_pct'     THEN cfg_value END) AS min_mad
        FROM   cap_config
     ),
     src AS (
        SELECT dbid, con_dbid, 'BUSY_PCT' AS metric, day_dt, busy_pct AS val
        FROM   capd_cpu_daily
        WHERE  busy_pct IS NOT NULL AND gap_flag = 'N'
        UNION ALL
        SELECT dbid, con_dbid, 'BUSY_P95' AS metric, day_dt, busy_p95 AS val
        FROM   capd_cpu_daily
        WHERE  busy_p95 IS NOT NULL AND gap_flag = 'N'
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_PCT' AS metric, day_dt, db_cpu_pct AS val
        FROM   capd_dbtime_daily
        WHERE  db_cpu_pct IS NOT NULL AND gap_flag = 'N'
     ),
     lastd AS (
        SELECT dbid, con_dbid, metric, MAX(day_dt) AS last_day
        FROM   src
        GROUP  BY dbid, con_dbid, metric
     ),
     -- Tag every day with the window it belongs to: R = recent, B = baseline,
     -- NULL = older than both and irrelevant here.
     w AS (
        SELECT s.dbid, s.con_dbid, s.metric, s.day_dt, s.val, l.last_day,
               CASE WHEN s.day_dt > l.last_day - cfg.shift_days THEN 'R'
                    WHEN s.day_dt > l.last_day - cfg.shift_days - cfg.base_days THEN 'B'
               END AS win
        FROM   src s
        JOIN   lastd l
          ON   l.dbid = s.dbid AND l.con_dbid = s.con_dbid AND l.metric = s.metric
        CROSS  JOIN cfg
     ),
     -- Pass 1: the two medians + window sizes.
     m1 AS (
        SELECT dbid, con_dbid, metric,
               MAX(last_day)                            AS last_day,
               MEDIAN(CASE WHEN win = 'R' THEN val END) AS recent_med,
               MEDIAN(CASE WHEN win = 'B' THEN val END) AS base_med,
               COUNT(CASE WHEN win = 'R' THEN 1 END)    AS n_recent,
               COUNT(CASE WHEN win = 'B' THEN 1 END)    AS n_base
        FROM   w
        WHERE  win IS NOT NULL
        GROUP  BY dbid, con_dbid, metric
     ),
     -- Pass 2: MAD about the baseline median (needs base_med, hence a second
     -- pass -- the same two-pass shape CAPA_TBSPC_ANOM uses). LEFT JOIN so a
     -- series too young to have a baseline still produces its row.
     m2 AS (
        SELECT m.dbid, m.con_dbid, m.metric, m.last_day,
               m.recent_med, m.base_med, m.n_recent, m.n_base,
               MEDIAN(ABS(h.val - m.base_med)) * 1.4826 AS base_mad_sigma
        FROM   m1 m
        LEFT   JOIN w h
          ON   h.dbid = m.dbid AND h.con_dbid = m.con_dbid AND h.metric = m.metric
         AND   h.win = 'B'
        GROUP  BY m.dbid, m.con_dbid, m.metric, m.last_day,
                  m.recent_med, m.base_med, m.n_recent, m.n_base
     ),
     -- Pass 3: the N-of-M counts, which need pass 2's sigma.
     m3 AS (
        SELECT m.dbid, m.con_dbid, m.metric, m.last_day,
               m.recent_med, m.base_med, m.n_recent, m.n_base, m.base_mad_sigma,
               COUNT(CASE WHEN r.val > m.base_med
                                     + GREATEST(NVL(m.base_mad_sigma, 0), cfg.min_mad)
                          THEN 1 END) AS n_above,
               COUNT(CASE WHEN r.val < m.base_med
                                     - GREATEST(NVL(m.base_mad_sigma, 0), cfg.min_mad)
                          THEN 1 END) AS n_below
        FROM   m2 m
        CROSS  JOIN cfg
        LEFT   JOIN w r
          ON   r.dbid = m.dbid AND r.con_dbid = m.con_dbid AND r.metric = m.metric
         AND   r.win = 'R'
        GROUP  BY m.dbid, m.con_dbid, m.metric, m.last_day,
                  m.recent_med, m.base_med, m.n_recent, m.n_base, m.base_mad_sigma
     )
SELECT a.dbid,
       a.con_dbid,
       a.metric,
       a.last_day,
       cfg.shift_days                                              AS recent_days,
       cfg.base_days                                               AS base_days,
       a.recent_med,
       a.base_med,
       a.recent_med - a.base_med                                   AS shift_pct,
       a.base_mad_sigma,
       a.n_recent,
       a.n_base,
       a.n_above,
       a.n_below,
       cfg.min_pct                                                 AS threshold_pct,
       a.base_med + GREATEST(NVL(a.base_mad_sigma, 0), cfg.min_mad) AS day_thresh_hi,
       a.base_med - GREATEST(NVL(a.base_mad_sigma, 0), cfg.min_mad) AS day_thresh_lo,
       'PCT'                                                       AS unit,
       CASE
           WHEN a.n_recent >= cfg.shift_days AND a.n_base >= cfg.shift_days
            AND (a.recent_med - a.base_med) >  cfg.min_pct
            AND a.n_above >= cfg.shift_days                        THEN 'UP'
           WHEN a.n_recent >= cfg.shift_days AND a.n_base >= cfg.shift_days
            AND (a.base_med - a.recent_med) >  cfg.min_pct
            AND a.n_below >= cfg.shift_days                        THEN 'DOWN'
           ELSE NULL
       END                                                         AS shift_flag
FROM   m3 a CROSS JOIN cfg;
