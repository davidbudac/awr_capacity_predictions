--
-- ddl/40_anomaly_views.sql -- CAPA_* deterministic rolling-MAD anomalies.
-- =====================================================================
-- Robust (median + MAD) outlier flags. Every flag is reproducible by hand:
-- the views expose value, baseline median, MAD-sigma, the threshold, the
-- robust z-score and the baseline size, so an operator can re-derive any
-- HIGH/LOW arithmetic. They also state the deviation as a percentage of the
-- baseline median (pct_vs_expected) and of the long-run train_days mean
-- (pct_vs_avg); both are NULL when that baseline is not positive.
--
-- MAD_sigma = MEDIAN(|x - median|) * 1.4826 (the 1.4826 makes MAD a consistent
-- estimator of the standard deviation for normal data). Rolling MAD cannot be
-- written with nested window MEDIANs, so the engine joins each point to its
-- baseline rows (a self-join of the observations), takes the median as an
-- analytic MEDIAN over those rows and the MAD as a grouped MEDIAN about it,
-- always EXCLUDING the scored point so a spike cannot inflate its own
-- baseline.
--
--   CAPA_OBS        -- (M15) every scorable observation in one shape:
--                      tablespace growth rates, host BUSY_PCT and container
--                      DB_CPU_PCT (day and hour grain), the M11 series.
--   CAPA_ANOM       -- (M15) each observation scored against every baseline
--                      MODE of its grain: TRAILING (last mad_window_days) and
--                      SAME_DOW (same weekday, dow_weeks back) at day grain,
--                      HOUR_OF_WEEK (same weekday and hour) at hour grain. A
--                      per-unit threshold floor keeps a flat baseline (MAD=0)
--                      from swallowing a real jump and sub-floor wiggles from
--                      ever flagging. Gap rows and incomplete days are never
--                      scored nor baseline.
--   CAPA_ANOM_DAY   -- (M15) CAPA_ANOM's day rows, one row per observation:
--                      the join target that cannot fan out.
--   CAPA_CPU_SHIFT  -- M10.3 LEVEL SHIFT, not an outlier: a sustained step
--                      that never crosses k*MAD on any single day. Recent
--                      window median vs the baseline median before it, with
--                      an N-of-M confirmation. One row per (container,
--                      metric) -- current state, not a per-day series.
--
-- Self-join cost is O(points * window): fine at day grain for <= ~400 days,
-- and the hour grain only joins dow_weeks exact lags per point.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPA_OBS (M15) -- every scorable observation, one shape for every series.
-- Key (dbid, con_dbid, kind, series, grain, ts). The registry of WHAT is
-- scored and HOW:
--   kind / series  TBSPC / tablespace; CPU / BUSY_PCT (host, OSSTAT) and
--                  DB_CPU_PCT (per container); SERIES / the M11 names.
--   grain / ts     DAY rows carry day_dt; HOUR rows (CPU only) the END-hour
--                  bucket of CAPD_CPU_HOURLY.
--   value          the number the baselines compare: TBSPC the gap-normalised
--                  growth RATE (bytes/day), DB_SIZE_GB its GiB/day growth
--                  rate, everything else the level itself.
--   raw_value      the un-normalised number (TBSPC / DB_SIZE_GB the delta
--                  over span_days; else = value).
--   gap_flag       'Y' rows are never scored and never baseline.
--                  anomaly_hour_grain = 0 drops the HOUR rows (no hourly
--                  scoring at all).
--   is_complete    'N' on a CPU / DB time / REDO_GB_DAY day whose valid
--                  intervals cover less than complete_day_pct of it (first
--                  day, restart day, today): never scored, never baseline.
--                  'Y' everywhere else, hour rows included.
--   thr_floor      the smallest THRESHOLD a flag may use, in value units
--                  (one row per (unit, grain) in ufloor): a perfectly flat
--                  baseline (MAD = 0) still flags a real jump, and sub-floor
--                  wiggles never do.
--   alert_modes    the family's CAP_CONFIG bitmask of modes that alert.
--   headline_bit   the DAY mode whose numbers observation-grain consumers
--                  show: the lowest DAY bit set in alert_modes (1 = TRAILING
--                  if none); HOUR rows 4.
-- Series are scored only when listed in sreg (M11) or in a branch below.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capa_obs AS
WITH ufloor AS (
        SELECT 'BYTES_PER_DAY' AS unit, 'DAY' AS grain, cfg.abs_floor_bytes AS thr_floor FROM cap_cfg cfg
        UNION ALL SELECT 'PCT',         'DAY',  cfg.mad_k * cfg.cpu_min_mad_pct      FROM cap_cfg cfg
        UNION ALL SELECT 'PCT',         'HOUR', cfg.mad_k * cfg.cpu_min_mad_pct_hour FROM cap_cfg cfg
        UNION ALL SELECT 'COUNT',       'DAY',  cfg.series_floor_count               FROM cap_cfg cfg
        UNION ALL SELECT 'GIB_PER_DAY', 'DAY',  cfg.series_floor_gib                 FROM cap_cfg cfg
     ),
     sreg AS (
        SELECT 'PROCESSES' AS series, 'LEVEL' AS basis, 'COUNT' AS unit, 'SERIES_LEVEL' AS anomaly_kind FROM dual
        UNION ALL SELECT 'SESSIONS',    'LEVEL', 'COUNT',       'SERIES_LEVEL'  FROM dual
        UNION ALL SELECT 'REDO_GB_DAY', 'LEVEL', 'GIB_PER_DAY', 'SERIES_LEVEL'  FROM dual
        UNION ALL SELECT 'DB_SIZE_GB',  'RATE',  'GIB_PER_DAY', 'SERIES_GROWTH' FROM dual
     ),
     ser AS (
        SELECT s.dbid, s.con_dbid, s.series, s.day_dt, s.value, s.day_gap,
               s.max_interval_hours, s.gap_flag, s.is_complete,
               s.value - LAG(s.value) OVER (PARTITION BY s.dbid, s.con_dbid, s.series
                                            ORDER BY s.day_dt) AS d_value
        FROM   capd_series_daily s
     ),
     src AS (
        SELECT t.dbid, t.con_dbid, 'TBSPC' AS kind, t.tablespace_name AS series,
               'DAY' AS grain, t.day_dt AS ts,
               t.used_rate_bpd AS value, t.used_delta_bytes AS raw_value, t.day_gap AS span_days,
               'BYTES_PER_DAY' AS unit, 'N' AS gap_flag, 'Y' AS is_complete, t.day_gap,
               CAST(NULL AS NUMBER) AS ivl_hours,
               'TBSPC_GROWTH' AS anomaly_kind, 'TBSPC_ANOM' AS alert_kind
        FROM   capd_tbspc_delta t
        WHERE  t.used_rate_bpd IS NOT NULL
        UNION ALL
        SELECT c.dbid, c.con_dbid, 'CPU', 'BUSY_PCT', 'DAY', c.day_dt,
               c.busy_pct, c.busy_pct, 1, 'PCT', c.gap_flag, c.is_complete, c.day_gap, c.max_interval_hours,
               'CPU_BUSY', 'CPU_ANOM'
        FROM   capd_cpu_daily c
        WHERE  c.busy_pct IS NOT NULL
        UNION ALL
        SELECT d.dbid, d.con_dbid, 'CPU', 'DB_CPU_PCT', 'DAY', d.day_dt,
               d.db_cpu_pct, d.db_cpu_pct, 1, 'PCT', d.gap_flag, d.is_complete, d.day_gap, d.max_interval_hours,
               'DBCPU_BUSY', 'DBCPU_ANOM'
        FROM   capd_dbtime_daily d
        WHERE  d.db_cpu_pct IS NOT NULL
        UNION ALL
        SELECT h.dbid, h.con_dbid, 'CPU', h.metric, 'HOUR', h.hour_ts,
               h.value, h.value, 1/24, 'PCT', h.gap_flag, 'Y', CAST(NULL AS NUMBER), h.ivl_hours,
               CASE h.metric WHEN 'BUSY_PCT' THEN 'CPU_BUSY' ELSE 'DBCPU_BUSY' END,
               CASE h.metric WHEN 'BUSY_PCT' THEN 'CPU_ANOM' ELSE 'DBCPU_ANOM' END
        FROM   capd_cpu_hourly h
        CROSS  JOIN cap_cfg cfg
        WHERE  h.value IS NOT NULL
          AND  cfg.anomaly_hour_grain <> 0
        UNION ALL
        SELECT s.dbid, s.con_dbid, 'SERIES', s.series, 'DAY', s.day_dt,
               CASE r.basis WHEN 'RATE' THEN s.d_value / s.day_gap ELSE s.value END,
               CASE r.basis WHEN 'RATE' THEN s.d_value             ELSE s.value END,
               CASE r.basis WHEN 'RATE' THEN s.day_gap             ELSE 1       END,
               r.unit, s.gap_flag, s.is_complete, s.day_gap, s.max_interval_hours,
               r.anomaly_kind, 'SERIES_ANOM'
        FROM   ser s
        JOIN   sreg r ON r.series = s.series
        WHERE  CASE r.basis WHEN 'RATE' THEN s.d_value / NULLIF(s.day_gap, 0) ELSE s.value END IS NOT NULL
     )
SELECT o.dbid, o.con_dbid, o.kind, o.series, o.grain, o.ts,
       o.value, o.raw_value, o.span_days, o.unit, o.gap_flag, o.is_complete, o.day_gap, o.ivl_hours,
       f.thr_floor, o.anomaly_kind, o.alert_kind,
       m.alert_modes,
       CASE WHEN o.grain = 'HOUR'              THEN 4
            WHEN BITAND(m.alert_modes, 1) > 0  THEN 1
            WHEN BITAND(m.alert_modes, 2) > 0  THEN 2
            ELSE 1
       END                                                     AS headline_bit
FROM   src o
JOIN   ufloor f ON f.unit = o.unit AND f.grain = o.grain
JOIN  (SELECT 'TBSPC' AS kind, cfg.alert_modes_tbspc AS alert_modes FROM cap_cfg cfg
       UNION ALL SELECT 'CPU',    cfg.alert_modes_cpu    FROM cap_cfg cfg
       UNION ALL SELECT 'SERIES', cfg.alert_modes_series FROM cap_cfg cfg) m
  ON   m.kind = o.kind;

-- --------------------------------------------------------------------
-- CAPA_ANOM (M15) -- the anomaly engine: every CAPA_OBS row scored against
-- every baseline mode of its grain. Key (dbid, con_dbid, kind, series,
-- baseline_mode, ts); row count = 2 x DAY obs + 1 x HOUR obs.
--   TRAILING      (DAY,  bit 1) every non-gap day in [ts - mad_window_days,
--                 ts - 1]: "unusual vs how it has been going lately?"
--   SAME_DOW      (DAY,  bit 2) the same weekday 1..dow_weeks weeks back.
--   HOUR_OF_WEEK  (HOUR, bit 4) the same weekday AND clock hour 1..dow_weeks
--                 weeks back. ts is a DB-local DATE, so ts - 7k is that slot
--                 with no weekday arithmetic (NLS-proof), and it follows the
--                 local clock across a DST change, as workload does.
-- Baselines EXCLUDE the point itself and every gap_flag = 'Y' or
-- is_complete = 'N' row, and neither kind of row is ever flagged. The
-- median comes first, then the MAD about it: a rolling MAD cannot be a
-- nested window MEDIAN on 19c.
--   expected   baseline median;  mad_sigma = MEDIAN(|h - expected|) * 1.4826
--   eff_sigma  GREATEST(mad_sigma, thr_floor / mad_k); sigma_floored says
--              which side won
--   threshold  mad_k * eff_sigma, a DEVIATION (bound = expected +/- it)
--   robust_z   dev / eff_sigma, so |z| > mad_k <=> flagged
--   anomaly_flag HIGH / LOW, NULL on a gap or incomplete row or when
--              n_hist < min_hist
--              (trailing_min_hist for TRAILING, weekly_min_hist otherwise)
--   avg_value / avg_days / pct_vs_avg  the long-run mean over train_days,
--              SUM(raw_value) / SUM(span_days) over non-gap complete rows (TBSPC: the
--              gap-weighted mean growth rate), DAY rows only, mode-independent
--   alerting_mode  'Y' when the family's alert_modes bitmask has this mode
--   is_headline    1 on the mode CAPA_ANOM_DAY reports for the observation
--   kind_last_day  the newest DAY ts of the kind over every container (NULL
--              when the kind has no DAY rows): the anchor of the alert
--              window, so CAPR_ANOMALIES needs no second CAPA_OBS read
-- CAPA_OBS is read once (obs, referenced four times, so Oracle materializes
-- it): joined directly, the optimizer pushes the history join into the
-- CAPA_OBS view and recomputes its daily sources per scored point. The
-- history rows are read once too: med takes the median as an analytic over
-- each point's rows, madc the MAD about it, instead of joining the medians
-- back to the history. Both sorts carry only (pid, value): pid numbers the
-- scored point (obs_id * 8 + mode_bit, obs_id from the CAPA_OBS key), so a
-- small work area sorts a fraction of the bytes the full key would cost.
-- Readers either filter baseline_mode or GROUP BY the observation key:
-- joined on the observation key alone this view fans out two rows per day
-- (test/lint_anom_joins.sh enforces it outside ddl/40, ddl/45 and the tests).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capa_anom AS
WITH obs AS (
        SELECT o.*,
               ROW_NUMBER() OVER (ORDER BY o.dbid, o.con_dbid, o.kind, o.series, o.grain, o.ts) AS obs_id,
               MAX(CASE WHEN o.grain = 'DAY' THEN o.ts END) OVER (PARTITION BY o.kind) AS kind_last_day
        FROM   capa_obs o
     ),
     modes AS (
        SELECT 'TRAILING' AS baseline_mode, 1 AS mode_bit, 'DAY' AS grain FROM dual
        UNION ALL SELECT 'SAME_DOW',     2, 'DAY'  FROM dual
        UNION ALL SELECT 'HOUR_OF_WEEK', 4, 'HOUR' FROM dual
     ),
     lags AS (
        SELECT LEVEL AS lv FROM dual CONNECT BY LEVEL <= (SELECT dow_weeks FROM cap_cfg)
     ),
     cur AS (
        SELECT o.*, m.baseline_mode, m.mode_bit, o.obs_id * 8 + m.mode_bit AS pid
        FROM   obs o
        JOIN   modes m ON m.grain = o.grain
     ),
     hist AS (
        SELECT c.pid, h.value AS hval
        FROM   cur c
        JOIN   obs h
          ON   h.dbid = c.dbid AND h.con_dbid = c.con_dbid
         AND   h.kind = c.kind AND h.series = c.series AND h.grain = c.grain
         AND   h.gap_flag = 'N' AND h.is_complete = 'Y'
         AND   h.ts BETWEEN c.ts - (SELECT mad_window_days FROM cap_cfg) AND c.ts - 1
        WHERE  c.baseline_mode = 'TRAILING'
        UNION ALL
        SELECT c.pid, h.value
        FROM   cur c
        CROSS  JOIN lags g
        JOIN   obs h
          ON   h.dbid = c.dbid AND h.con_dbid = c.con_dbid
         AND   h.kind = c.kind AND h.series = c.series AND h.grain = c.grain
         AND   h.gap_flag = 'N' AND h.is_complete = 'Y'
         AND   h.ts = c.ts - 7 * g.lv
        WHERE  c.baseline_mode IN ('SAME_DOW', 'HOUR_OF_WEEK')
     ),
     med AS (
        SELECT h.pid, h.hval, MEDIAN(h.hval) OVER (PARTITION BY h.pid) AS med
        FROM   hist h
     ),
     madc AS (
        SELECT pid, MAX(med) AS med, COUNT(hval) AS n_hist,
               MEDIAN(ABS(hval - med)) * 1.4826 AS mad_sigma
        FROM   med
        GROUP  BY pid
     ),
     avgw AS (
        SELECT o.dbid, o.con_dbid, o.kind, o.series, o.ts,
               SUM(CASE WHEN o.gap_flag = 'N' AND o.is_complete = 'Y' THEN o.raw_value END)
                 OVER (PARTITION BY o.dbid, o.con_dbid, o.kind, o.series ORDER BY o.ts
                       RANGE BETWEEN (SELECT train_days FROM cap_cfg) PRECEDING AND 1 PRECEDING)
               / NULLIF(SUM(CASE WHEN o.gap_flag = 'N' AND o.is_complete = 'Y' THEN o.span_days END)
                 OVER (PARTITION BY o.dbid, o.con_dbid, o.kind, o.series ORDER BY o.ts
                       RANGE BETWEEN (SELECT train_days FROM cap_cfg) PRECEDING AND 1 PRECEDING), 0) AS avg_value,
               SUM(CASE WHEN o.gap_flag = 'N' AND o.is_complete = 'Y' THEN o.span_days END)
                 OVER (PARTITION BY o.dbid, o.con_dbid, o.kind, o.series ORDER BY o.ts
                       RANGE BETWEEN (SELECT train_days FROM cap_cfg) PRECEDING AND 1 PRECEDING) AS avg_days
        FROM   obs o
        WHERE  o.grain = 'DAY'
     ),
     scored AS (
        SELECT c.*,
               a.med                                              AS expected,
               a.mad_sigma,
               NVL(a.n_hist, 0)                                   AS n_hist,
               GREATEST(NVL(a.mad_sigma, 0), c.thr_floor / cfg.mad_k) AS eff_sigma,
               CASE c.baseline_mode WHEN 'TRAILING' THEN cfg.trailing_min_hist
                                    ELSE cfg.weekly_min_hist END  AS min_hist,
               w.avg_value, w.avg_days, cfg.mad_k
        FROM   cur c
        CROSS  JOIN cap_cfg cfg
        LEFT   JOIN madc a
          ON   a.pid = c.pid
        LEFT   JOIN avgw w
          ON   c.grain = 'DAY'
         AND   w.dbid = c.dbid AND w.con_dbid = c.con_dbid AND w.kind = c.kind
         AND   w.series = c.series AND w.ts = c.ts
     )
SELECT s.dbid, s.con_dbid, s.kind, s.series, s.baseline_mode, s.mode_bit, s.grain, s.ts,
       MOD(TRUNC(s.ts) - DATE '2020-01-06', 7)                            AS dow,
       CASE WHEN s.grain = 'HOUR' THEN TO_NUMBER(TO_CHAR(s.ts, 'HH24')) END AS hod,
       s.value, s.raw_value, s.span_days, s.unit, s.gap_flag, s.is_complete, s.day_gap, s.ivl_hours,
       s.expected, s.mad_sigma, s.thr_floor, s.eff_sigma,
       CASE WHEN NVL(s.mad_sigma, 0) < s.thr_floor / s.mad_k THEN 'Y' ELSE 'N' END AS sigma_floored,
       s.n_hist, s.min_hist,
       s.value - s.expected                                               AS dev,
       s.mad_k * s.eff_sigma                                              AS threshold,
       (s.value - s.expected) / NULLIF(s.eff_sigma, 0)                    AS robust_z,
       CASE WHEN s.expected > 0 THEN 100 * (s.value - s.expected) / s.expected END AS pct_vs_expected,
       s.avg_value, s.avg_days,
       CASE WHEN s.avg_value > 0 THEN 100 * (s.value - s.avg_value) / s.avg_value END AS pct_vs_avg,
       CASE
           WHEN s.gap_flag = 'Y' OR s.is_complete = 'N'         THEN NULL
           WHEN s.n_hist < s.min_hist                           THEN NULL
           WHEN  (s.value - s.expected) > s.mad_k * s.eff_sigma THEN 'HIGH'
           WHEN -(s.value - s.expected) > s.mad_k * s.eff_sigma THEN 'LOW'
       END                                                                AS anomaly_flag,
       s.anomaly_kind, s.alert_kind, s.alert_modes,
       CASE WHEN BITAND(s.alert_modes, s.mode_bit) > 0 THEN 'Y' ELSE 'N' END AS alerting_mode,
       CASE WHEN s.mode_bit = s.headline_bit THEN 1 ELSE 0 END             AS is_headline,
       s.kind_last_day
FROM   scored s;

-- --------------------------------------------------------------------
-- CAPA_ANOM_DAY (M15) -- CAPA_ANOM's DAY rows rolled up to ONE row per
-- observation (dbid, con_dbid, kind, series, ts): the join target for
-- anything keyed by observation, which can therefore never fan out.
--   anomaly        1 when any DAY mode flagged, else 0
--   anomaly_modes  the flagging modes, comma-separated in bit order
--   headline_mode and its anomaly_flag / expected / threshold / robust_z /
--   n_hist         the mode CAPA_OBS.headline_bit picks
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capa_anom_day AS
SELECT a.dbid, a.con_dbid, a.kind, a.series, a.ts,
       MAX(CASE WHEN a.anomaly_flag IS NOT NULL THEN 1 ELSE 0 END)   AS anomaly,
       LISTAGG(CASE WHEN a.anomaly_flag IS NOT NULL THEN a.baseline_mode END, ',')
         WITHIN GROUP (ORDER BY a.mode_bit)                         AS anomaly_modes,
       MAX(CASE WHEN a.is_headline = 1 THEN a.baseline_mode END)     AS headline_mode,
       MAX(CASE WHEN a.is_headline = 1 THEN a.anomaly_flag  END)     AS anomaly_flag,
       MAX(CASE WHEN a.is_headline = 1 THEN a.expected      END)     AS expected,
       MAX(CASE WHEN a.is_headline = 1 THEN a.threshold     END)     AS threshold,
       MAX(CASE WHEN a.is_headline = 1 THEN a.robust_z      END)     AS robust_z,
       MAX(CASE WHEN a.is_headline = 1 THEN a.n_hist        END)     AS n_hist
FROM   capa_anom a
WHERE  a.grain = 'DAY'
GROUP  BY a.dbid, a.con_dbid, a.kind, a.series, a.ts;

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
-- M10.5: gap-flagged AND incomplete days are dropped from BOTH windows -- a
-- 36 h average is not a day, and letting it into a 7-day median is exactly
-- how a maintenance window turns into a fake "level shift". An incomplete day
-- (is_complete = 'N': covered_sec below complete_day_pct) is a partial
-- sample, e.g. a restart day; CAPA_ANOM's history and the CPU trend fit
-- (ddl/30) already read complete days only, so the shift windows use the
-- same rule instead of a looser one that could flag seven partial days.
--
-- newest_day / is_current (as on every CAPF view): newest_day is the newest
-- source day of the DBID (not of the con_dbid), is_current = 'Y' when the
-- series' last_day is within stale_days of it. CAPR_FRESHNESS is per dbid, so
-- a PDB whose time model stopped (unplugged, dropped) while the CDB goes on
-- raises no DATA_STALE; is_current = 'N' is what stops its last shift from
-- staying an OPEN CPU_SHIFT alert until AWR retention purges the rows.
--
-- Metrics: BUSY_PCT and BUSY_P95 (host, per CAPD_CPU_DAILY) and DB_CPU_PCT
-- (per container, per CAPD_DBTIME_DAILY). BUSY_PEAK is deliberately left out:
-- it is already a same-window average of BUSY_PCT's busiest hours, so it
-- shifts with them and would only duplicate the alert.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capa_cpu_shift AS
WITH src AS (
        SELECT dbid, con_dbid, 'BUSY_PCT' AS metric, day_dt, busy_pct AS val
        FROM   capd_cpu_daily
        WHERE  busy_pct IS NOT NULL AND gap_flag = 'N' AND is_complete = 'Y'
        UNION ALL
        SELECT dbid, con_dbid, 'BUSY_P95' AS metric, day_dt, busy_p95 AS val
        FROM   capd_cpu_daily
        WHERE  busy_p95 IS NOT NULL AND gap_flag = 'N' AND is_complete = 'Y'
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_PCT' AS metric, day_dt, db_cpu_pct AS val
        FROM   capd_dbtime_daily
        WHERE  db_cpu_pct IS NOT NULL AND gap_flag = 'N' AND is_complete = 'Y'
     ),
     lastd AS (
        SELECT dbid, con_dbid, metric, MAX(day_dt) AS last_day
        FROM   src
        GROUP  BY dbid, con_dbid, metric
     ),
     nd AS (
        SELECT dbid, MAX(day_dt) AS newest_day
        FROM   src
        GROUP  BY dbid
     ),
     -- Tag every day with the window it belongs to: R = recent, B = baseline,
     -- NULL = older than both and irrelevant here.
     w AS (
        SELECT s.dbid, s.con_dbid, s.metric, s.day_dt, s.val, l.last_day,
               CASE WHEN s.day_dt > l.last_day - cfg.shift_days THEN 'R'
                    WHEN s.day_dt > l.last_day - cfg.shift_days - cfg.shift_baseline_days THEN 'B'
               END AS win
        FROM   src s
        JOIN   lastd l
          ON   l.dbid = s.dbid AND l.con_dbid = s.con_dbid AND l.metric = s.metric
        CROSS  JOIN cap_cfg cfg
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
     -- pass -- the same two-pass shape CAPA_ANOM uses). LEFT JOIN so a
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
                                     + GREATEST(NVL(m.base_mad_sigma, 0), cfg.cpu_min_mad_pct)
                          THEN 1 END) AS n_above,
               COUNT(CASE WHEN r.val < m.base_med
                                     - GREATEST(NVL(m.base_mad_sigma, 0), cfg.cpu_min_mad_pct)
                          THEN 1 END) AS n_below
        FROM   m2 m
        CROSS  JOIN cap_cfg cfg
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
       cfg.shift_baseline_days                                     AS base_days,
       a.recent_med,
       a.base_med,
       a.recent_med - a.base_med                                   AS shift_pct,
       a.base_mad_sigma,
       a.n_recent,
       a.n_base,
       a.n_above,
       a.n_below,
       cfg.shift_min_pct                                           AS threshold_pct,
       a.base_med + GREATEST(NVL(a.base_mad_sigma, 0), cfg.cpu_min_mad_pct) AS day_thresh_hi,
       a.base_med - GREATEST(NVL(a.base_mad_sigma, 0), cfg.cpu_min_mad_pct) AS day_thresh_lo,
       'PCT'                                                       AS unit,
       CASE
           WHEN a.n_recent >= cfg.shift_days AND a.n_base >= cfg.shift_days
            AND (a.recent_med - a.base_med) >  cfg.shift_min_pct
            AND a.n_above >= cfg.shift_days                        THEN 'UP'
           WHEN a.n_recent >= cfg.shift_days AND a.n_base >= cfg.shift_days
            AND (a.base_med - a.recent_med) >  cfg.shift_min_pct
            AND a.n_below >= cfg.shift_days                        THEN 'DOWN'
           ELSE NULL
       END                                                         AS shift_flag,
       n.newest_day,
       CASE WHEN a.last_day >= n.newest_day - cfg.stale_days
            THEN 'Y' ELSE 'N' END                                  AS is_current
FROM   m3 a
JOIN   nd n ON n.dbid = a.dbid
CROSS  JOIN cap_cfg cfg;
