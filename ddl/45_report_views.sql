--
-- ddl/45_report_views.sql -- CAPR_* integration/report layer (M7.2 + M8.1).
-- =====================================================================
-- Read-only views sitting on top of the CAPF_/CAPA_ analytics, meant for
-- consumers OUTSIDE the bundled reports as much as inside them:
--
--   CAPR_CONTAINER -- (dbid, con_dbid) -> human label. Wraps the CAPV_CONTAINER
--                     seam view and computes db_pdb, the single display string
--                     every report section prints instead of a raw con_dbid:
--                       * root / non-CDB row  -> just the database name
--                       * PDB row             -> DBNAME/PDBNAME
--                       * name unknown        -> the raw con_dbid as text
--                     Defining the label ONCE here keeps text and HTML reports
--                     from drifting.
--   CAPR_ANOMALIES -- every flagged anomaly event (one row per observation
--                     and baseline mode, plus CPU level shifts) with its
--                     severity, message and alert eligibility. Also a point
--                     feed for external dashboards.
--   CAPR_ALERTS    -- one row per current issue, pollable by OEM metric
--                     extensions / Zabbix / Nagios / a scheduler job:
--                       severity   CRIT | WARN | INFO  (sev_rank 1|2|3)
--                       kind       TBSPC_FULL | TBSPC_NEARFULL | TBSPC_ANOM |
--                                  CPU_SAT | DBCPU_SAT | CPU_ANOM | DBCPU_ANOM |
--                                  CPU_SHIFT | SERIES_LIMIT | SERIES_NEARLIMIT |
--                                  SERIES_ANOM
--                     plus keys (dbid, con_dbid, db_pdb, series_key), the
--                     observation day, the metric value vs its threshold, a
--                     ready-to-page plain-text message, the baseline_mode of
--                     an anomaly kind and a unique alert_key.
--   CAPR_SERIES_POINTS / CAPR_HOURLY_POINTS / CAPR_FIT -- point feeds for
--                     external dashboards (grafana/API.md, elk/), at the
--                     bottom of this file; CAPR_FORECAST_POINTS is in ddl/55.
--
-- Thresholds all come from CAP_CONFIG (dtf_warn/dtf_crit, nearfull_*_pct,
-- cpu_sat_pct, anomaly_report_days -- the alert window for anomaly kinds,
-- distinct from the report's own anomaly_days DEFINE). Read-only like
-- everything else in the suite.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPR_CONTAINER
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_container AS
SELECT c.dbid,
       c.con_dbid,
       c.db_name,
       c.con_name,
       CASE
           WHEN c.db_name IS NULL THEN TO_CHAR(c.con_dbid)
           -- root (con_dbid = dbid, e.g. CDB$ROOT) and non-CDB: db name only
           WHEN c.con_dbid = c.dbid OR c.con_name IS NULL THEN c.db_name
           ELSE c.db_name || '/' || c.con_name
       END AS db_pdb
FROM   capv_container c;

-- --------------------------------------------------------------------
-- CAPR_ANOMALIES -- one row per flagged event over the whole history (no
-- window): every flagged CAPA_ANOM row (one per observation AND baseline
-- mode) plus the current CPU_SHIFT of each series. The single home of an
-- anomaly's severity, message and alert eligibility; CAPR_ALERTS reads its
-- anomaly rows FROM here.
--   anomaly_kind  TBSPC_GROWTH | CPU_BUSY (host BUSY_PCT) | DBCPU_BUSY
--                 (container DB_CPU_PCT) | SERIES_LEVEL | SERIES_GROWTH |
--                 CPU_SHIFT
--   value         the SCORED value (TBSPC: the growth rate in bytes/day;
--                 raw_value is the day's raw delta); expected = the baseline
--                 median; threshold = the allowed DEVIATION (mad_k *
--                 eff_sigma), so the crossed bound is expected +/- threshold.
--   alerting      'Y' when the family's alert_modes bitmask enables this
--                 baseline mode AND the day is inside anomaly_report_days of
--                 the kind's last collected day (CPU_SHIFT: always 'Y').
--   sev           WARN for an alerting HIGH / UP, else INFO.
--   obs_day       TRUNC(ts) (hour rows too); CPU_SHIFT: the last day of its
--                 recent window, while ts is the window's first day.
--   pct_vs_expected / pct_vs_avg  the move as a % of the baseline median /
--                 of the long-run train_days mean; NULL when that baseline is
--                 not positive.
--   doc_key       the stable id input for exporters (unique).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_anomalies AS
WITH lastd AS (
        SELECT kind, MAX(ts) AS last_day
        FROM   capa_obs
        WHERE  grain = 'DAY'
        GROUP  BY kind
     ),
     pt AS (
        SELECT a.*,
               CASE WHEN a.alerting_mode = 'Y'
                     AND TRUNC(a.ts) > l.last_day - cfg.anomaly_report_days
                    THEN 'Y' ELSE 'N' END                                     AS alerting,
               DECODE(a.dow, 0, 'Mon', 1, 'Tue', 2, 'Wed', 3, 'Thu',
                             4, 'Fri', 5, 'Sat', 'Sun')                        AS dy,
               cfg.mad_window_days, cfg.train_days
        FROM   capa_anom a
        CROSS  JOIN cap_cfg cfg
        JOIN   lastd l ON l.kind = a.kind
        WHERE  a.anomaly_flag IS NOT NULL
     ),
     fmt AS (
        SELECT p.*,
               CASE p.unit
                   WHEN 'BYTES_PER_DAY' THEN TO_CHAR(p.expected / 1048576, 'FM999999990.0') || ' MiB/day'
                   WHEN 'PCT'           THEN TO_CHAR(p.expected, 'FM9999990.0') || '%'
                   WHEN 'COUNT'         THEN TO_CHAR(p.expected, 'FM99999999990')
                   ELSE                      TO_CHAR(p.expected, 'FM9999990.00') || ' GiB/day'
               END                                                            AS expected_txt,
               CASE p.anomaly_kind
                   WHEN 'TBSPC_GROWTH' THEN
                       'Tablespace ' || p.series
                       || CASE WHEN p.anomaly_flag = 'HIGH' THEN ' grew '
                               WHEN p.raw_value < 0         THEN ' shrank '
                               ELSE ' grew less than usual: ' END
                       || TO_CHAR(ABS(p.raw_value) / 1073741824, 'FM99999990.00') || ' GiB'
                   WHEN 'SERIES_GROWTH' THEN
                       p.series
                       || CASE WHEN p.anomaly_flag = 'HIGH' THEN ' grew '
                               WHEN p.raw_value < 0         THEN ' shrank '
                               ELSE ' grew less than usual: ' END
                       || TO_CHAR(ABS(p.raw_value), 'FM99999990.00') || ' GiB'
                   WHEN 'CPU_BUSY'   THEN 'Host CPU ' || TO_CHAR(p.value, 'FM990.0') || '% busy'
                   WHEN 'DBCPU_BUSY' THEN 'DB CPU ' || TO_CHAR(p.value, 'FM990.0') || '% of host CPUs'
                   ELSE p.series || ' at '
                        || CASE p.unit WHEN 'COUNT' THEN TO_CHAR(p.value, 'FM99999999990')
                                       ELSE TO_CHAR(p.value, 'FM9999990.00') || ' GiB/day' END
               END                                                            AS subject,
               CASE p.baseline_mode
                   WHEN 'TRAILING' THEN 'over the last ' || TO_CHAR(p.mad_window_days, 'FM9990') || ' days'
                   WHEN 'SAME_DOW' THEN 'for that weekday'
                   ELSE 'for ' || p.dy || ' ' || TO_CHAR(p.ts, 'HH24') || ':00'
               END                                                            AS phrase
        FROM   pt p
     ),
     ev AS (
        SELECT f.dbid, f.con_dbid, f.ts, f.kind, f.series, f.anomaly_kind, f.anomaly_flag,
               f.value, f.expected, f.threshold, f.robust_z AS z,
               CAST(NULL AS NUMBER) AS shift_pct, LOWER(f.unit) AS unit,
               CASE WHEN f.alerting = 'Y' AND f.anomaly_flag = 'HIGH' THEN 'WARN' ELSE 'INFO' END AS sev,
               f.subject || ' on '
                 || TO_CHAR(f.ts, CASE f.grain WHEN 'HOUR' THEN 'YYYY-MM-DD HH24:MI' ELSE 'YYYY-MM-DD' END)
                 || ' vs usual ' || f.expected_txt || ' ' || f.phrase
                 || ', robust z ' || NVL(TO_CHAR(f.robust_z, 'FMS999999990.0'), 'off-scale')
                 || CASE WHEN f.pct_vs_expected IS NOT NULL
                         THEN ' (' || TO_CHAR(f.pct_vs_expected, 'FMS999999999990') || '% vs median)' END
                 || CASE WHEN f.kind = 'TBSPC' AND f.pct_vs_avg IS NOT NULL
                         THEN ', ' || TO_CHAR(f.pct_vs_avg, 'FMS999999999990') || '% vs '
                              || TO_CHAR(f.train_days, 'FM9990') || '-day avg rate' END   AS message,
               TRUNC(f.ts) AS obs_day,
               CASE WHEN f.kind = 'TBSPC' THEN f.value END AS rate_bpd,
               f.pct_vs_expected, f.pct_vs_avg,
               f.baseline_mode, f.grain, f.n_hist, f.alerting, f.alert_kind, f.raw_value
        FROM   fmt f
        UNION ALL
        SELECT s.dbid, s.con_dbid, s.last_day - s.recent_days + 1, 'CPU', s.metric,
               'CPU_SHIFT', s.shift_flag,
               s.recent_med, s.base_med, s.threshold_pct, NULL,
               s.shift_pct, LOWER(TRIM(s.unit)),
               CASE s.shift_flag WHEN 'UP' THEN 'WARN' ELSE 'INFO' END,
               s.metric || ' shifted ' || s.shift_flag || ' '
                 || TO_CHAR(s.shift_pct, 'FMS9999990.0') || ' pts: last '
                 || TO_CHAR(s.recent_days, 'FM9999990') || ' days median '
                 || TO_CHAR(s.recent_med, 'FM99999990.0') || '% vs prior '
                 || TO_CHAR(s.base_days, 'FM9999990') || ' days '
                 || TO_CHAR(s.base_med, 'FM99999990.0') || '%',
               s.last_day, NULL,
               CASE WHEN s.base_med > 0 THEN 100 * s.shift_pct / s.base_med END, NULL,
               NULL, 'DAY', s.n_base, 'Y', 'CPU_SHIFT', s.recent_med
        FROM   capa_cpu_shift s
        WHERE  s.shift_flag IN ('UP', 'DOWN')
     )
SELECT e.dbid,
       e.con_dbid,
       NVL(c.db_pdb, TO_CHAR(e.con_dbid))  AS db,
       c.db_name,
       c.con_name,
       e.ts,
       e.kind,
       e.series,
       e.anomaly_kind,
       e.anomaly_flag,
       e.value,
       e.expected,
       e.threshold,
       e.z,
       e.shift_pct,
       e.unit,
       e.sev,
       CASE e.sev WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END AS sev_rank,
       e.message,
       e.obs_day,
       e.rate_bpd,
       e.pct_vs_expected,
       e.pct_vs_avg,
       e.baseline_mode,
       e.grain,
       e.n_hist,
       e.alerting,
       e.alert_kind,
       e.raw_value,
       'anom|' || e.dbid || '|' || e.con_dbid || '|' || e.anomaly_kind || '|' || e.series
         || '|' || NVL(e.baseline_mode, '-') || '|'
         || TO_CHAR(CASE WHEN e.anomaly_kind = 'CPU_SHIFT' THEN e.obs_day ELSE e.ts END,
                    'YYYY-MM-DD"T"HH24')                                       AS doc_key
FROM   ev e
LEFT   JOIN capr_container c
  ON   c.dbid = e.dbid AND c.con_dbid = e.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_ALERTS
-- Every branch is hand-auditable against the view it reads:
--   TBSPC_FULL     capf_tbspc_forecast: quality=OK, days_to_full <= dtf_warn.
--   TBSPC_NEARFULL capf_tbspc_forecast: pct_used >= nearfull_warn_pct,
--                  REGARDLESS of fit quality (M7.1: a 97%-full tablespace with
--                  an unreliable fit must still surface).
--   CPU_SAT        capf_cpu_trend BUSY_P95 (or BUSY_PCT when cpu_sat_on_p95=0):
--                  quality=OK, days_to_sat <= dtf_warn.
--   DBCPU_SAT      capf_cpu_trend DB_CPU_PCT (per container, M10.2): same rule.
--   TBSPC_ANOM / CPU_ANOM / DBCPU_ANOM / SERIES_ANOM
--                  CAPR_ANOMALIES rows with alerting = 'Y': the baseline
--                  mode is enabled by alert_modes_<family> and the day lies
--                  within the last anomaly_report_days (HIGH -> WARN, LOW ->
--                  INFO). One row per (series, day, baseline_mode).
--   CPU_SHIFT      capa_cpu_shift (M10.3): a flagged sustained level shift.
--                  UP -> WARN, DOWN -> INFO. No day window applies -- the
--                  view already holds only the CURRENT state of each series.
--   SERIES_LIMIT   capf_series_forecast (M11): quality=OK, days_to_limit
--                  <= dtf_warn -- the fixed-ceiling series reaching
--                  series_sat_pct% of its limit.
--   SERIES_NEARLIMIT capf_series_forecast: pct_of_limit >= nearfull_warn_pct
--                  now, at ANY fit quality (the M7.1 rule, applied to
--                  processes / sessions / total DB size).
-- value/threshold carry the number that crossed and the limit it crossed
-- (units in the unit column), so a poller can alarm without parsing message.
-- baseline_mode is NULL for every non-anomaly kind; alert_key =
-- dbid|con_dbid|kind|series_key|YYYY-MM-DD|mode ('-' when none) is unique.
-- db_pdb resolves through CAPR_CONTAINER; unknown containers degrade to the
-- raw con_dbid string.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_alerts AS
WITH alerts AS (
        -- ---- TBSPC_FULL: confident forecast inside the warning window ----
        SELECT CASE WHEN f.days_to_full <= cfg.dtf_crit THEN 'CRIT' ELSE 'WARN' END AS severity,
               'TBSPC_FULL'            AS kind,
               f.dbid, f.con_dbid,
               f.tablespace_name       AS series_key,
               f.last_day              AS day_dt,
               f.days_to_full          AS value,
               CASE WHEN f.days_to_full <= cfg.dtf_crit
                    THEN cfg.dtf_crit ELSE cfg.dtf_warn END AS threshold,
               'DAYS'                  AS unit,
               'Tablespace ' || f.tablespace_name || ' forecast full in '
                 || TO_CHAR(f.days_to_full, 'FM9999990') || ' days ('
                 || TO_CHAR(f.pct_used, 'FM990.0') || '% used, '
                 || TO_CHAR(f.slope_bpd / 1048576, 'FM99999990.0') || ' MiB/day)' AS message,
               CAST(NULL AS VARCHAR2(12)) AS baseline_mode
        FROM   capf_tbspc_forecast f CROSS JOIN cap_cfg cfg
        WHERE  f.quality = 'OK'
          AND  f.days_to_full IS NOT NULL
          AND  f.days_to_full <= cfg.dtf_warn
        UNION ALL
        -- ---- TBSPC_NEARFULL: nearly full RIGHT NOW, any fit quality ----
        SELECT CASE WHEN f.pct_used >= cfg.nearfull_crit_pct THEN 'CRIT' ELSE 'WARN' END,
               'TBSPC_NEARFULL',
               f.dbid, f.con_dbid,
               f.tablespace_name,
               f.last_day,
               f.pct_used,
               CASE WHEN f.pct_used >= cfg.nearfull_crit_pct THEN cfg.nearfull_crit_pct ELSE cfg.nearfull_warn_pct END,
               'PCT',
               'Tablespace ' || f.tablespace_name || ' is '
                 || TO_CHAR(f.pct_used, 'FM990.0') || '% full now ('
                 || TO_CHAR(f.cur_used / 1073741824, 'FM99999990.00') || ' of '
                 || TO_CHAR(f.limit_bytes / 1073741824, 'FM99999990.00')
                 || ' GiB; forecast quality ' || f.quality || ')',
               NULL
        FROM   capf_tbspc_forecast f CROSS JOIN cap_cfg cfg
        WHERE  f.pct_used >= cfg.nearfull_warn_pct
        UNION ALL
        -- ---- CPU_SAT: host CPU forecast to reach saturation ----
        SELECT CASE WHEN t.days_to_sat <= cfg.dtf_crit THEN 'CRIT' ELSE 'WARN' END,
               'CPU_SAT',
               t.dbid, t.con_dbid,
               t.metric,
               t.last_day,
               t.days_to_sat,
               CASE WHEN t.days_to_sat <= cfg.dtf_crit THEN cfg.dtf_crit ELSE cfg.dtf_warn END,
               'DAYS',
               'Host CPU ' || CASE t.metric WHEN 'BUSY_P95' THEN '(busy-hour p95) ' ELSE '(daily avg) ' END
                 || 'forecast to reach ' || TO_CHAR(cfg.cpu_sat_pct, 'FM990')
                 || '% busy in ' || TO_CHAR(t.days_to_sat, 'FM9999990')
                 || ' days (now ' || TO_CHAR(t.cur_val, 'FM990.0') || '% busy)',
               NULL
        FROM   capf_cpu_trend t CROSS JOIN cap_cfg cfg
        -- which host-busy trend drives CPU_SAT (M10.1): p95 of the day's
        -- snapshot intervals (default) or the daily average
        WHERE  t.metric = CASE WHEN cfg.cpu_sat_on_p95 = 0 THEN 'BUSY_PCT' ELSE 'BUSY_P95' END
          AND  t.quality = 'OK'
          AND  t.days_to_sat IS NOT NULL
          AND  t.days_to_sat <= cfg.dtf_warn
        UNION ALL
        -- ---- DBCPU_SAT: a container's DB CPU forecast to consume the
        -- saturation share of the host's cores (M10.2, per PDB) ----
        SELECT CASE WHEN t.days_to_sat <= cfg.dtf_crit THEN 'CRIT' ELSE 'WARN' END,
               'DBCPU_SAT',
               t.dbid, t.con_dbid,
               t.metric,
               t.last_day,
               t.days_to_sat,
               CASE WHEN t.days_to_sat <= cfg.dtf_crit THEN cfg.dtf_crit ELSE cfg.dtf_warn END,
               'DAYS',
               'DB CPU forecast to reach ' || TO_CHAR(cfg.cpu_sat_pct, 'FM990')
                 || '% of host core capacity in ' || TO_CHAR(t.days_to_sat, 'FM9999990')
                 || ' days (now ' || TO_CHAR(t.cur_val, 'FM990.0') || '%)',
               NULL
        FROM   capf_cpu_trend t CROSS JOIN cap_cfg cfg
        WHERE  t.metric = 'DB_CPU_PCT'
          AND  t.quality = 'OK'
          AND  t.days_to_sat IS NOT NULL
          AND  t.days_to_sat <= cfg.dtf_warn
        UNION ALL
        -- ---- CPU_SHIFT: a sustained step in a CPU series (M10.3). Not a
        -- forecast and not an outlier -- the level the machine runs at TODAY
        -- differs from the level it ran at a month ago, which is a capacity
        -- fact even when no single day ever looked odd. UP is a WARN (someone
        -- added load); DOWN is INFO (load left -- worth knowing, not paging).
        SELECT CASE WHEN s.shift_flag = 'UP' THEN 'WARN' ELSE 'INFO' END,
               'CPU_SHIFT',
               s.dbid, s.con_dbid,
               s.metric,
               s.last_day,
               s.shift_pct,
               s.threshold_pct,
               'PCT',
               CASE s.metric WHEN 'DB_CPU_PCT' THEN 'DB CPU' ELSE 'Host CPU' END
                 || ' (' || s.metric || ') shifted '
                 || TO_CHAR(s.shift_pct, 'FMS9999990.0') || ' pts: last '
                 || TO_CHAR(s.recent_days, 'FM9999990') || ' days median '
                 || TO_CHAR(s.recent_med, 'FM99999990.0') || '% vs prior '
                 || TO_CHAR(s.base_days, 'FM9999990') || ' days '
                 || TO_CHAR(s.base_med, 'FM99999990.0') || '%',
               NULL
        FROM   capa_cpu_shift s CROSS JOIN cap_cfg cfg
        WHERE  s.shift_flag IS NOT NULL
        UNION ALL
        -- ---- SERIES_LIMIT (M11): a fixed-ceiling series (PROCESSES /
        -- SESSIONS / DB_SIZE_GB) is forecast to reach series_sat_pct% of its
        -- ceiling inside the warning window. Same OK-quality gate and same
        -- dtf_warn/dtf_crit thresholds as TBSPC_FULL / CPU_SAT, so a poller
        -- treats all three identically. REDO_GB_DAY has no ceiling, so it can
        -- never appear here.
        SELECT CASE WHEN s.days_to_limit <= cfg.dtf_crit THEN 'CRIT' ELSE 'WARN' END,
               'SERIES_LIMIT',
               s.dbid, s.con_dbid,
               s.series,
               s.last_day,
               s.days_to_limit,
               CASE WHEN s.days_to_limit <= cfg.dtf_crit THEN cfg.dtf_crit ELSE cfg.dtf_warn END,
               'DAYS',
               s.series || ' forecast to reach ' || TO_CHAR(cfg.series_sat_pct, 'FM990')
                 || '% of its limit (' || RTRIM(TO_CHAR(s.cur_limit, 'FM99999999990.99'), '.')
                 || ' ' || s.unit || ') in ' || TO_CHAR(s.days_to_limit, 'FM9999990')
                 || ' days (now ' || RTRIM(TO_CHAR(s.cur_val, 'FM99999999990.99'), '.')
                 || ', ' || TO_CHAR(s.pct_of_limit, 'FM990.0') || '% of limit)',
               NULL
        FROM   capf_series_forecast s CROSS JOIN cap_cfg cfg
        WHERE  s.quality = 'OK'
          AND  s.days_to_limit IS NOT NULL
          AND  s.days_to_limit <= cfg.dtf_warn
        UNION ALL
        -- ---- SERIES_NEARLIMIT (M11): already close to the ceiling RIGHT NOW,
        -- at ANY fit quality -- the M7.1 rule applied to the new series. A
        -- session count sitting at 95% of `sessions` is an outage waiting for
        -- a busy Monday whether or not its trend is fittable.
        SELECT CASE WHEN s.pct_of_limit >= cfg.nearfull_crit_pct THEN 'CRIT' ELSE 'WARN' END,
               'SERIES_NEARLIMIT',
               s.dbid, s.con_dbid,
               s.series,
               s.last_day,
               s.pct_of_limit,
               CASE WHEN s.pct_of_limit >= cfg.nearfull_crit_pct THEN cfg.nearfull_crit_pct ELSE cfg.nearfull_warn_pct END,
               'PCT',
               s.series || ' is at ' || TO_CHAR(s.pct_of_limit, 'FM990.0')
                 || '% of its limit now (' || RTRIM(TO_CHAR(s.cur_val, 'FM99999999990.99'), '.')
                 || ' of ' || RTRIM(TO_CHAR(s.cur_limit, 'FM99999999990.99'), '.') || ' ' || s.unit
                 || '; forecast quality ' || s.quality || ')',
               NULL
        FROM   capf_series_forecast s CROSS JOIN cap_cfg cfg
        WHERE  s.pct_of_limit >= cfg.nearfull_warn_pct
        UNION ALL
        -- ---- TBSPC_ANOM / CPU_ANOM / DBCPU_ANOM / SERIES_ANOM (M15): the
        -- alerting rows of CAPR_ANOMALIES, one per (series, day, baseline
        -- mode). An HOUR_OF_WEEK day carries its worst hour (largest |z|,
        -- earliest on a tie) and says how many hours flagged; it is a WARN
        -- when any of them is. threshold = the bound crossed.
        SELECT CASE WHEN x.day_rank = 2 THEN 'WARN' ELSE 'INFO' END,
               x.alert_kind,
               x.dbid, x.con_dbid,
               x.series,
               x.obs_day,
               x.value,
               x.expected + SIGN(x.value - x.expected) * x.threshold,
               CASE x.unit WHEN 'bytes_per_day' THEN 'BYTES' WHEN 'pct' THEN 'PCT'
                           WHEN 'count' THEN 'COUNT' ELSE 'GIB' END,
               x.message || CASE WHEN x.n_events > 1
                                 THEN '; ' || x.n_events || ' hours flagged that day' END,
               x.baseline_mode
        FROM  (SELECT a.*,
                      ROW_NUMBER() OVER (PARTITION BY a.alert_kind, a.dbid, a.con_dbid, a.series,
                                                      a.baseline_mode, a.obs_day
                                         ORDER BY ABS(a.z) DESC NULLS LAST, a.ts) AS rn,
                      COUNT(*)        OVER (PARTITION BY a.alert_kind, a.dbid, a.con_dbid, a.series,
                                                     a.baseline_mode, a.obs_day)  AS n_events,
                      MIN(a.sev_rank) OVER (PARTITION BY a.alert_kind, a.dbid, a.con_dbid, a.series,
                                                     a.baseline_mode, a.obs_day)  AS day_rank
               FROM   capr_anomalies a
               WHERE  a.alerting = 'Y' AND a.anomaly_kind <> 'CPU_SHIFT') x
        WHERE  x.rn = 1
     )
SELECT a.severity,
       CASE a.severity WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END AS sev_rank,
       a.kind,
       a.dbid,
       a.con_dbid,
       NVL(c.db_pdb, TO_CHAR(a.con_dbid)) AS db_pdb,
       a.series_key,
       a.day_dt,
       a.value,
       a.threshold,
       a.unit,
       a.message,
       a.baseline_mode,
       a.dbid || '|' || a.con_dbid || '|' || a.kind || '|' || a.series_key || '|'
         || TO_CHAR(a.day_dt, 'YYYY-MM-DD') || '|' || NVL(a.baseline_mode, '-') AS alert_key
FROM   alerts a
LEFT   JOIN capr_container c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid;

-- ====================================================================
-- M8.2 -- one CAPR_ view per report section, so report/report.sql (via
-- report/sections/*.sql) and report/report_html.sql only FORMAT: every
-- derived number, display label, severity marker and unit conversion is
-- computed HERE, once, and both drivers read the same rows. That removes
-- the duplicated-SQL drift risk between the text and HTML reports.
--
-- Conventions shared by all of them:
--   * db_pdb is already resolved through CAPR_CONTAINER (raw con_dbid as
--     the fallback), so no driver ever repeats that LEFT JOIN.
--   * Severity markers use the same CAP_CONFIG knobs as CAPR_ALERTS.
--   * Ranking views expose rank_* (ROW_NUMBER) so a driver applies its
--     top_n with a plain WHERE instead of its own ORDER BY + FETCH FIRST.
--   * Anomaly views expose days_ago (max collected day minus the row's
--     day), so the reports' anomaly_days window is a plain WHERE too.
--   * Sections whose numbers need Tier 2 (CAPF_COMPARE / CAPF_BACKTEST,
--     created in ddl/50_ml.sql AFTER this file) live in
--     ddl/55_report_views_ml.sql instead.
-- ====================================================================

-- --------------------------------------------------------------------
-- CAPR_TBSPC_DAYS_TO_FULL -- report section 1 (both halves).
--   1a "by days-to-full"  : WHERE days_to_full IS NOT NULL
--                             AND rank_dtf <= top_n  ORDER BY rank_dtf
--   1b "near-full now"    : WHERE pct_used IS NOT NULL
--                             AND rank_nearfull <= top_n  ORDER BY rank_nearfull
-- sev_dtf keys off dtf_crit/dtf_warn (days), sev_nearfull off
-- nearfull_crit_pct/nearfull_warn_pct (percent used) -- M7.1: the near-full
-- ranking is deliberately independent of fit quality.
-- GiB / MiB-per-day conversions are numeric columns (not strings) so a
-- consumer can still compare and threshold them.
-- limit_below_used / is_current pass straight through from
-- CAPF_TBSPC_FORECAST ('Y'/'N'); nothing here filters on them. So do the
-- CYCLIC columns (cycle_n always, the rest only on CYCLIC rows), with the
-- peak in GiB and the peak slope in MiB/day like cur_gb / slope_mb. And the
-- sizing ask: need_gib_30 / _90 / _180 (GiB to add so the worst case stays
-- under the ceiling through +h) and add_by_day (the worst-case fill date).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_tbspc_days_to_full AS
SELECT f.dbid,
       f.con_dbid,
       NVL(c.db_pdb, TO_CHAR(f.con_dbid))  AS db_pdb,
       f.tablespace_name,
       f.pct_used,
       f.cur_used    / 1024 / 1024 / 1024  AS cur_gb,
       f.limit_bytes / 1024 / 1024 / 1024  AS limit_gb,
       f.limit_source,
       f.slope_bpd   / 1024 / 1024         AS slope_mb,
       f.days_to_full,
       f.days_to_full_lo                   AS dtf_worst,
       f.days_to_full_hi                   AS dtf_best,
       CASE WHEN f.days_to_full <= cfg.dtf_crit THEN 'CRIT'
            WHEN f.days_to_full <= cfg.dtf_warn THEN 'WARN'
            ELSE 'ok'  END                 AS sev_dtf,
       CASE WHEN f.pct_used >= cfg.nearfull_crit_pct THEN 'CRIT'
            WHEN f.pct_used >= cfg.nearfull_warn_pct THEN 'WARN'
            ELSE 'ok'  END                 AS sev_nearfull,
       f.quality,
       f.r2,
       f.accel_ratio                       AS accel,
       ROW_NUMBER() OVER (ORDER BY f.days_to_full NULLS LAST,
                                   f.con_dbid, f.tablespace_name)  AS rank_dtf,
       ROW_NUMBER() OVER (ORDER BY f.pct_used DESC NULLS LAST,
                                   f.con_dbid, f.tablespace_name)  AS rank_nearfull,
       f.limit_below_used,
       f.is_current,
       f.cycle_n,
       f.cycle_days,
       f.cycle_peak_bytes / 1024 / 1024 / 1024 AS cycle_peak_gb,
       f.cycle_peak_pct,
       f.peak_slope_bpd   / 1024 / 1024        AS peak_slope_mb,
       f.need_gib_30,
       f.need_gib_90,
       f.need_gib_180,
       f.add_by_day
FROM   capf_tbspc_forecast f
CROSS  JOIN cap_cfg cfg
LEFT   JOIN capr_container c
  ON   c.dbid = f.dbid AND c.con_dbid = f.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_TBSPC_ANOMALIES -- report section 3. Every FLAGGED (day, baseline
-- mode) of a tablespace (no window applied here); a driver bounds it with
-- WHERE days_ago < anomaly_days and orders a day's verdicts by mode_rank.
-- days_ago is measured from MAX(day_dt) over ALL of CAPD_TBSPC_DAILY, so
-- "last N days" means the last N collected days.
-- day_str is the pre-formatted YYYY-MM-DD the reports print; day_dt stays
-- a DATE for consumers that want to compare it. thr_mb is the allowed
-- deviation (mad_k * eff_sigma), z = dev / eff_sigma.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_tbspc_anomalies AS
SELECT a.dbid,
       a.con_dbid,
       NVL(c.db_pdb, TO_CHAR(a.con_dbid))      AS db_pdb,
       a.series                                AS tablespace_name,
       a.ts                                    AS day_dt,
       TO_CHAR(a.ts, 'YYYY-MM-DD')             AS day_str,
       (SELECT MAX(day_dt) FROM capd_tbspc_daily) - a.ts AS days_ago,
       a.day_gap                               AS gap,
       a.raw_value / 1048576                   AS delta_mb,
       a.value     / 1048576                   AS rate_mb,
       a.expected  / 1048576                   AS med_mb,
       a.threshold / 1048576                   AS thr_mb,
       a.robust_z                              AS z,
       a.avg_value / 1048576                   AS avg_mb,
       a.avg_days,
       a.pct_vs_expected                       AS pct_vs_med,
       a.pct_vs_avg,
       a.anomaly_flag,
       a.baseline_mode,
       DECODE(a.baseline_mode, 'TRAILING', 'TRL', 'DOW')  AS mode_short,
       DECODE(a.baseline_mode, 'TRAILING', 1, 2)          AS mode_rank,
       a.n_hist
FROM   capa_anom a
LEFT   JOIN capr_container c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid
WHERE  a.kind = 'TBSPC'
  AND  a.anomaly_flag IS NOT NULL;

-- --------------------------------------------------------------------
-- CAPR_CPU_TREND -- report section 4. One row per (container, metric):
-- BUSY_PCT / BUSY_P95 / BUSY_PEAK / DB_CPU_SEC / DB_CPU_PCT / DB_CPU_P95.
-- sat_worst / sat_best are the M9.1 days-to-saturation range (lo = worst
-- case / soonest; hi NULL = might never saturate). slope_sig, deseasoned,
-- anchor_value, recent_p95_med and hot_now pass straight through from
-- CAPF_CPU_TREND (recent_p95_med / hot_now on BUSY_P95 and DB_CPU_P95 only).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_cpu_trend AS
SELECT t.dbid,
       t.con_dbid,
       NVL(c.db_pdb, TO_CHAR(t.con_dbid))  AS db_pdb,
       t.metric,
       t.last_day,
       t.train_n,
       t.cur_val,
       t.slope_per_day,
       t.r2,
       t.days_to_sat,
       t.days_to_sat_lo                    AS sat_worst,
       t.days_to_sat_hi                    AS sat_best,
       t.quality,
       t.is_current,
       t.slope_sig,
       t.deseasoned,
       t.anchor_value,
       t.recent_p95_med,
       t.hot_now
FROM   capf_cpu_trend t
LEFT   JOIN capr_container c
  ON   c.dbid = t.dbid AND c.con_dbid = t.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_CPU_ANOMALIES -- report section 5. Every flagged CPU point: host
-- BUSY_PCT and per-container DB_CPU_PCT, at day grain (TRAILING, SAME_DOW)
-- and hour grain (HOUR_OF_WEEK). Key (dbid, con_dbid, metric,
-- baseline_mode, ts). day_dt = TRUNC(ts); ts_str is 'YYYY-MM-DD' for a day
-- row and 'YYYY-MM-DD Dy HH24:MI' (NLS-proof weekday) for an hour row.
-- days_ago is measured from the last collected CPU day. threshold_pct is
-- the allowed deviation in points.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_cpu_anomalies AS
SELECT a.dbid,
       a.con_dbid,
       NVL(c.db_pdb, TO_CHAR(a.con_dbid))    AS db_pdb,
       TRUNC(a.ts)                           AS day_dt,
       TO_CHAR(a.ts, 'YYYY-MM-DD')           AS day_str,
       (SELECT MAX(ts) FROM capa_obs WHERE kind = 'CPU' AND grain = 'DAY') - TRUNC(a.ts) AS days_ago,
       a.value                               AS value_pct,
       a.expected                            AS median_pct,
       a.threshold                           AS threshold_pct,
       a.robust_z                            AS z,
       a.pct_vs_expected                     AS pct_vs_med,
       a.anomaly_flag,
       a.series                              AS metric,
       a.baseline_mode,
       DECODE(a.baseline_mode, 'TRAILING', 'TRL', 'SAME_DOW', 'DOW', 'HOW') AS mode_short,
       DECODE(a.baseline_mode, 'TRAILING', 1, 'SAME_DOW', 2, 3)             AS mode_rank,
       a.grain,
       a.ts,
       CASE a.grain
           WHEN 'HOUR' THEN TO_CHAR(a.ts, 'YYYY-MM-DD') || ' '
                            || DECODE(a.dow, 0, 'Mon', 1, 'Tue', 2, 'Wed', 3, 'Thu',
                                             4, 'Fri', 5, 'Sat', 'Sun')
                            || ' ' || TO_CHAR(a.ts, 'HH24:MI')
           ELSE TO_CHAR(a.ts, 'YYYY-MM-DD')
       END                                   AS ts_str,
       a.n_hist
FROM   capa_anom a
LEFT   JOIN capr_container c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid
WHERE  a.kind = 'CPU'
  AND  a.anomaly_flag IS NOT NULL;

-- --------------------------------------------------------------------
-- CAPR_CPU_SHIFTS -- report section 5's second block (M10.3). Flagged rows
-- only (shift_flag IS NOT NULL), db_pdb resolved, and the window sizes and
-- both medians carried through so the section can print the whole claim on
-- one line without re-reading CAP_CONFIG. Ordered by the biggest absolute
-- move first via rank_shift, so a driver bounds it with a plain WHERE.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_cpu_shifts AS
SELECT s.dbid,
       s.con_dbid,
       NVL(c.db_pdb, TO_CHAR(s.con_dbid))    AS db_pdb,
       s.metric,
       s.last_day,
       TO_CHAR(s.last_day, 'YYYY-MM-DD')     AS day_str,
       s.recent_days,
       s.base_days,
       s.recent_med,
       s.base_med,
       s.shift_pct,
       s.base_mad_sigma,
       s.n_recent,
       s.n_base,
       s.n_above,
       s.n_below,
       s.threshold_pct,
       s.shift_flag,
       CASE WHEN s.shift_flag = 'UP' THEN 'WARN' ELSE 'INFO' END AS sev,
       ROW_NUMBER() OVER (ORDER BY ABS(s.shift_pct) DESC NULLS LAST,
                                   s.con_dbid, s.metric)         AS rank_shift
FROM   capa_cpu_shift s
LEFT   JOIN capr_container c
  ON   c.dbid = s.dbid AND c.con_dbid = s.con_dbid
WHERE  s.shift_flag IS NOT NULL;

-- --------------------------------------------------------------------
-- CAPR_SERIES (M11) -- report section 7: the fixed-ceiling series
-- (PROCESSES / SESSIONS / REDO_GB_DAY / DB_SIZE_GB / ASM_DG:+<group> /
-- TEMP_PEAK:<ts> / UNDO_PEAK:<ts>), one row per (container, series). Same contract as the other CAPR_ views: db_pdb is
-- already resolved, every severity marker is computed here, and rank_series
-- lets a driver bound the list with a plain WHERE.
--   sev keys off days_to_limit (dtf_crit/dtf_warn) when the fit is OK, and
--   otherwise off pct_of_limit (nearfull_crit_pct/nearfull_warn_pct) -- the
--   two CAPR_ALERTS branches, collapsed into one column for display.
--   limit_worst / limit_best are the M9.1 days-to-limit range (lo = worst
--   case / soonest; best empty = might never get there).
-- Series with no ceiling (REDO_GB_DAY) simply carry NULL limit columns and
-- an 'ok' severity: they are a trend, not a countdown. REDO_GB_DAY rows pass
-- fra_size_gb / fra_days_at_cur through (the days of redo the FRA holds at
-- today's rate), NULL on every other series.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_series AS
SELECT s.dbid,
       s.con_dbid,
       NVL(c.db_pdb, TO_CHAR(s.con_dbid))  AS db_pdb,
       s.series,
       s.unit,
       s.last_day,
       s.train_n,
       s.cur_val,
       s.cur_limit,
       s.pct_of_limit,
       s.sat_value,
       s.slope_per_day,
       s.r2,
       s.proj_30,
       s.proj_90,
       s.days_to_limit,
       s.days_to_limit_lo                  AS limit_worst,
       s.days_to_limit_hi                  AS limit_best,
       CASE WHEN s.quality = 'OK' AND s.days_to_limit <= cfg.dtf_crit THEN 'CRIT'
            WHEN s.quality = 'OK' AND s.days_to_limit <= cfg.dtf_warn THEN 'WARN'
            WHEN s.pct_of_limit >= cfg.nearfull_crit_pct              THEN 'CRIT'
            WHEN s.pct_of_limit >= cfg.nearfull_warn_pct              THEN 'WARN'
            ELSE 'ok'
       END                                 AS sev,
       s.quality,
       -- Most urgent first: soonest days_to_limit, then fullest, then name.
       ROW_NUMBER() OVER (ORDER BY s.days_to_limit NULLS LAST,
                                   s.pct_of_limit DESC NULLS LAST,
                                   s.con_dbid, s.series) AS rank_series,
       s.is_current,
       s.fra_size_gb,
       s.fra_days_at_cur
FROM   capf_series_forecast s
CROSS  JOIN cap_cfg cfg
LEFT   JOIN capr_container c
  ON   c.dbid = s.dbid AND c.con_dbid = s.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_SERIES_ANOMALIES (M15) -- report section 7b: every flagged (day,
-- baseline mode) of an M11 series. PROCESSES / SESSIONS / REDO_GB_DAY are
-- scored on their level, DB_SIZE_GB on its daily growth (value GiB/day,
-- raw_value the GiB moved since the previous row). unit is CAPA_OBS's
-- (COUNT / GIB_PER_DAY). days_ago is measured from the last collected
-- CAPD_SERIES_DAILY day.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_series_anomalies AS
SELECT a.dbid,
       a.con_dbid,
       NVL(c.db_pdb, TO_CHAR(a.con_dbid))    AS db_pdb,
       a.series,
       a.unit,
       a.baseline_mode,
       DECODE(a.baseline_mode, 'TRAILING', 'TRL', 'DOW')  AS mode_short,
       DECODE(a.baseline_mode, 'TRAILING', 1, 2)          AS mode_rank,
       a.ts                                  AS day_dt,
       TO_CHAR(a.ts, 'YYYY-MM-DD')           AS day_str,
       (SELECT MAX(day_dt) FROM capd_series_daily) - a.ts AS days_ago,
       a.value,
       a.raw_value,
       a.expected,
       a.threshold,
       a.robust_z                            AS z,
       a.n_hist,
       a.pct_vs_expected                     AS pct_vs_med,
       a.anomaly_flag
FROM   capa_anom a
LEFT   JOIN capr_container c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid
WHERE  a.kind = 'SERIES'
  AND  a.anomaly_flag IS NOT NULL;

-- ====================================================================
-- Point feeds for external dashboards (grafana/API.md over ORDS, and
-- elk/export_capacity.sql). One row per charted point, every kind in one
-- shape, so a consumer filters on kind/series instead of knowing which
-- CAPD_/CAPF_/CAPA_ view holds what. Columns past the API contract (the
-- tbspc/cpu detail, db_name/con_name) are there for the ELK documents.
-- Booleans are NUMBER 1/0, NULL where the notion does not apply.
-- ====================================================================

-- --------------------------------------------------------------------
-- CAPR_SERIES_POINTS -- every observed daily point: TBSPC used bytes, the
-- CPU metrics that CAPF_CPU_TREND fits (BUSY_PCT/BUSY_P95/BUSY_PEAK from
-- OSSTAT, DB_CPU_PCT/DB_CPU_P95/DB_CPU_SEC from the time model) and the M11
-- series. Exactly one row per CAPD row: the anomaly verdict comes from
-- CAPA_ANOM_DAY (one row per observation by construction) and the hour
-- verdicts are rolled up to the day first.
--   anomaly            1 when any DAY baseline mode flagged the point or any
--                      HOUR_OF_WEEK hour of that day flagged; 0 on a scored
--                      series; NULL on a series nobody scores (BUSY_P95,
--                      BUSY_PEAK, DB_CPU_P95, DB_CPU_SEC).
--   anomaly_flag / z / expected / threshold
--                      the HEADLINE mode's numbers (CAPA_OBS.headline_bit:
--                      the lowest DAY mode the family alerts on, so TRAILING
--                      for tablespaces and SAME_DOW for CPU by default).
--   anomaly_modes      the DAY modes that flagged, comma-separated.
--   how_hours_flagged  HOUR_OF_WEEK hours flagged that day (CPU only).
--   doc_key            the stable id input for exporters (unique).
-- The cpu detail columns ride on the headline rows only (BUSY_PCT,
-- DB_CPU_PCT) so a sum over series does not count them twice.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_series_points AS
WITH hm AS (
        SELECT a.dbid, a.con_dbid, a.series, h.day_dt,
               COUNT(a.anomaly_flag) AS how_hours_flagged
        FROM   capa_anom a
        JOIN   capd_cpu_hourly h
          ON   h.dbid = a.dbid AND h.con_dbid = a.con_dbid
         AND   a.kind = 'CPU' AND h.metric = a.series AND h.hour_ts = a.ts
        WHERE  a.baseline_mode = 'HOUR_OF_WEEK'
        GROUP  BY a.dbid, a.con_dbid, a.series, h.day_dt
     )
SELECT p.dbid,
       p.con_dbid,
       NVL(c.db_pdb, TO_CHAR(p.con_dbid))  AS db,
       c.db_name,
       c.con_name,
       p.kind,
       p.series,
       p.ts,
       p.unit,
       p.value,
       p.limit_value,
       p.pct,
       p.gap,
       CASE WHEN d.anomaly = 1 OR p.how_hours_flagged > 0 THEN 1
            WHEN p.scored = 1                              THEN 0
       END                                 AS anomaly,
       d.anomaly_flag,
       d.robust_z                          AS z,
       d.expected,
       d.threshold,
       p.used_bytes,
       p.size_bytes,
       p.limit_bytes,
       p.limit_source,
       p.contents,
       p.delta_bytes,
       p.rate_bpd,
       p.busy_pct,
       p.busy_p95,
       p.busy_max,
       p.busy_peak_pct,
       p.host_busy_sec,
       p.num_cpus,
       p.num_cpu_cores,
       p.db_cpu_sec,
       p.db_time_sec,
       p.db_cpu_pct,
       p.db_cpu_p95_pct,
       p.db_cpu_per_core,
       d.anomaly_modes,
       p.how_hours_flagged,
       'obs|' || p.dbid || '|' || p.con_dbid || '|' || p.kind || '|' || p.series
         || '|' || TO_CHAR(p.ts, 'YYYY-MM-DD') AS doc_key
FROM  (
        SELECT t.dbid, t.con_dbid, 'TBSPC' AS kind, t.tablespace_name AS series, t.day_dt AS ts,
               'bytes'                                          AS unit,
               t.used_bytes                                     AS value,
               t.limit_bytes                                    AS limit_value,
               ROUND(100 * t.used_bytes / NULLIF(t.limit_bytes, 0), 2) AS pct,
               CAST(NULL AS NUMBER)                             AS gap,
               1                                                AS scored,
               CAST(NULL AS NUMBER)                             AS how_hours_flagged,
               t.used_bytes, t.size_bytes, t.limit_bytes, t.limit_source, t.contents,
               x.used_delta_bytes                               AS delta_bytes,
               x.used_rate_bpd                                  AS rate_bpd,
               CAST(NULL AS NUMBER) AS busy_pct,   CAST(NULL AS NUMBER) AS busy_p95,
               CAST(NULL AS NUMBER) AS busy_max,   CAST(NULL AS NUMBER) AS busy_peak_pct,
               CAST(NULL AS NUMBER) AS host_busy_sec,
               CAST(NULL AS NUMBER) AS num_cpus,   CAST(NULL AS NUMBER) AS num_cpu_cores,
               CAST(NULL AS NUMBER) AS db_cpu_sec, CAST(NULL AS NUMBER) AS db_time_sec,
               CAST(NULL AS NUMBER) AS db_cpu_pct, CAST(NULL AS NUMBER) AS db_cpu_p95_pct,
               CAST(NULL AS NUMBER) AS db_cpu_per_core
        FROM   capd_tbspc_daily t
        LEFT   JOIN capd_tbspc_delta x
          ON   x.dbid = t.dbid AND x.con_dbid = t.con_dbid
         AND   x.tablespace_name = t.tablespace_name AND x.day_dt = t.day_dt
        UNION ALL
        SELECT t.dbid, t.con_dbid, 'CPU', m.metric, t.day_dt,
               'pct', m.val, 100, m.val,
               CASE t.gap_flag WHEN 'Y' THEN 1 ELSE 0 END,
               CASE WHEN m.metric = 'BUSY_PCT' THEN 1 ELSE 0 END,
               CASE WHEN m.metric = 'BUSY_PCT' THEN NVL(h.how_hours_flagged, 0) END,
               NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               CASE WHEN m.metric = 'BUSY_PCT' THEN t.busy_pct      END,
               CASE WHEN m.metric = 'BUSY_PCT' THEN t.busy_p95      END,
               CASE WHEN m.metric = 'BUSY_PCT' THEN t.busy_max      END,
               CASE WHEN m.metric = 'BUSY_PCT' THEN t.busy_peak_pct END,
               CASE WHEN m.metric = 'BUSY_PCT' THEN t.host_busy_sec END,
               CASE WHEN m.metric = 'BUSY_PCT' THEN t.num_cpus      END,
               CASE WHEN m.metric = 'BUSY_PCT' THEN t.num_cpu_cores END,
               NULL, NULL, NULL, NULL, NULL
        FROM   capd_cpu_daily t
        CROSS  APPLY (SELECT 'BUSY_PCT'  AS metric, t.busy_pct      AS val FROM dual UNION ALL
                      SELECT 'BUSY_P95',            t.busy_p95             FROM dual UNION ALL
                      SELECT 'BUSY_PEAK',           t.busy_peak_pct        FROM dual) m
        LEFT   JOIN hm h
          ON   h.dbid = t.dbid AND h.con_dbid = t.con_dbid
         AND   h.series = m.metric AND h.day_dt = t.day_dt
        WHERE  m.val IS NOT NULL
        UNION ALL
        SELECT t.dbid, t.con_dbid, 'CPU', m.metric, t.day_dt,
               m.unit, m.val,
               CASE WHEN m.unit = 'pct' THEN 100 END,
               CASE WHEN m.unit = 'pct' THEN m.val END,
               CASE t.gap_flag WHEN 'Y' THEN 1 ELSE 0 END,
               CASE WHEN m.metric = 'DB_CPU_PCT' THEN 1 ELSE 0 END,
               CASE WHEN m.metric = 'DB_CPU_PCT' THEN NVL(h.how_hours_flagged, 0) END,
               NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               CASE WHEN m.metric = 'DB_CPU_PCT' THEN t.db_cpu_sec      END,
               CASE WHEN m.metric = 'DB_CPU_PCT' THEN t.db_time_sec     END,
               CASE WHEN m.metric = 'DB_CPU_PCT' THEN t.db_cpu_pct      END,
               CASE WHEN m.metric = 'DB_CPU_PCT' THEN t.db_cpu_p95_pct  END,
               CASE WHEN m.metric = 'DB_CPU_PCT' THEN t.db_cpu_per_core END
        FROM   capd_dbtime_daily t
        CROSS  APPLY (SELECT 'DB_CPU_PCT' AS metric, 'pct' AS unit, t.db_cpu_pct     AS val FROM dual UNION ALL
                      SELECT 'DB_CPU_P95',           'pct',         t.db_cpu_p95_pct        FROM dual UNION ALL
                      SELECT 'DB_CPU_SEC',           'sec',         t.db_cpu_sec            FROM dual) m
        LEFT   JOIN hm h
          ON   h.dbid = t.dbid AND h.con_dbid = t.con_dbid
         AND   h.series = m.metric AND h.day_dt = t.day_dt
        WHERE  m.val IS NOT NULL
        UNION ALL
        SELECT t.dbid, t.con_dbid, 'SERIES', t.series, t.day_dt,
               LOWER(t.unit), t.value, t.limit_value,
               ROUND(100 * t.value / NULLIF(t.limit_value, 0), 2),
               CASE t.gap_flag WHEN 'Y' THEN 1 ELSE 0 END,
               1, CAST(NULL AS NUMBER),
               NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL
        FROM   capd_series_daily t
      ) p
LEFT   JOIN capa_anom_day d
  ON   d.dbid = p.dbid AND d.con_dbid = p.con_dbid
 AND   d.kind = p.kind AND d.series = p.series AND d.ts = p.ts
LEFT   JOIN capr_container c
  ON   c.dbid = p.dbid AND c.con_dbid = p.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_HOURLY_POINTS (M15) -- one row per CAPD_CPU_HOURLY row: host
-- BUSY_PCT and per-container DB_CPU_PCT per END-hour bucket, with that
-- hour's HOUR_OF_WEEK verdict. ts is the DB wall clock (exporters stamp it
-- with a Z, a label, not an instant); dow is 0 = Monday (NLS-proof);
-- hour_of_day is the END hour. how_* are NULL when the hour was never
-- scored. doc_key is the stable id input for exporters (unique).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_hourly_points AS
SELECT h.dbid,
       h.con_dbid,
       NVL(c.db_pdb, TO_CHAR(h.con_dbid))                     AS db,
       c.db_name,
       c.con_name,
       'CPU'                                                  AS kind,
       h.metric                                               AS series,
       h.hour_ts                                              AS ts,
       h.day_dt,
       MOD(TRUNC(h.hour_ts) - DATE '2020-01-06', 7)           AS dow,
       TO_NUMBER(TO_CHAR(h.hour_ts, 'HH24'))                  AS hour_of_day,
       'pct'                                                  AS unit,
       h.value,
       CASE h.gap_flag WHEN 'Y' THEN 1 ELSE 0 END             AS gap,
       h.ivl_hours,
       h.n_intervals,
       CASE WHEN a.anomaly_flag IS NOT NULL THEN 1 ELSE 0 END AS anomaly,
       a.expected                                             AS how_expected,
       a.threshold                                            AS how_threshold,
       a.robust_z                                             AS how_z,
       a.anomaly_flag                                         AS how_flag,
       a.n_hist                                               AS how_n_hist,
       'obsh|' || h.dbid || '|' || h.con_dbid || '|' || h.metric || '|'
         || TO_CHAR(h.hour_ts, 'YYYY-MM-DD"T"HH24')           AS doc_key
FROM   capd_cpu_hourly h
LEFT   JOIN capa_anom a
  ON   a.dbid = h.dbid AND a.con_dbid = h.con_dbid AND a.kind = 'CPU'
 AND   a.series = h.metric AND a.baseline_mode = 'HOUR_OF_WEEK' AND a.ts = h.hour_ts
LEFT   JOIN capr_container c
  ON   c.dbid = h.dbid AND c.con_dbid = h.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_FIT -- the current fit, one row per (container, kind, series), with
-- days_to_full meaning days to the series' ceiling (TBSPC full, CPU
-- saturation, M11 limit). sev folds the report's own markers into
-- CRIT/WARN/OK: TBSPC from both CAPR_TBSPC_DAYS_TO_FULL markers, CPU from
-- its CAPR_ALERTS saturation row, SERIES from CAPR_SERIES.sev. CPU's
-- limit_value is the saturation threshold (cpu_sat_pct), not 100.
-- is_current (every kind) and limit_below_used (TBSPC only, NULL for CPU and
-- SERIES) are the CAPF_ 'Y'/'N' flags as NUMBER 1/0, appended last so the
-- explicit column lists of the existing consumers keep working. After them,
-- the same way: the TBSPC CYCLIC columns (cycle_n, cycle_days,
-- cycle_peak_pct, peak_slope_per_day in bytes/day), and the CPU flags
-- slope_sig (every CPU row) and hot_now (BUSY_P95 / DB_CPU_P95 only) as 1/0.
-- Then the TBSPC sizing ask (need_gib_30 / _90 / _180, add_by_day), NULL for
-- CPU and SERIES.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_fit AS
SELECT f.dbid,
       f.con_dbid,
       NVL(c.db_pdb, TO_CHAR(f.con_dbid))  AS db,
       c.db_name,
       c.con_name,
       f.kind,
       f.series,
       f.unit,
       f.method,
       f.value,
       f.limit_value,
       f.pct,
       f.slope_per_day,
       f.r2,
       f.quality,
       f.days_to_full,
       f.days_to_full_lo,
       f.days_to_full_hi,
       f.accel,
       f.train_n,
       f.sev,
       CASE f.sev WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END AS sev_rank,
       f.limit_source,
       f.last_day,
       f.is_current,
       f.limit_below_used,
       f.cycle_n,
       f.cycle_days,
       f.cycle_peak_pct,
       f.peak_slope_per_day,
       f.slope_sig,
       f.hot_now,
       f.need_gib_30,
       f.need_gib_90,
       f.need_gib_180,
       f.add_by_day
FROM  (
        SELECT t.dbid, t.con_dbid, 'TBSPC' AS kind, t.tablespace_name AS series,
               'bytes' AS unit, t.slope_method AS method,
               t.cur_used AS value, t.limit_bytes AS limit_value, t.pct_used AS pct,
               t.slope_bpd AS slope_per_day, t.r2, t.quality,
               t.days_to_full, t.days_to_full_lo, t.days_to_full_hi,
               t.accel_ratio AS accel, t.train_n,
               CASE WHEN 'CRIT' IN (r.sev_dtf, r.sev_nearfull) THEN 'CRIT'
                    WHEN 'WARN' IN (r.sev_dtf, r.sev_nearfull) THEN 'WARN'
                    ELSE 'OK' END AS sev,
               t.limit_source, t.last_day,
               CASE t.is_current WHEN 'Y' THEN 1 ELSE 0 END       AS is_current,
               CASE t.limit_below_used WHEN 'Y' THEN 1 ELSE 0 END AS limit_below_used,
               t.cycle_n, t.cycle_days, t.cycle_peak_pct,
               t.peak_slope_bpd                                   AS peak_slope_per_day,
               CAST(NULL AS NUMBER)                               AS slope_sig,
               CAST(NULL AS NUMBER)                               AS hot_now,
               t.need_gib_30, t.need_gib_90, t.need_gib_180, t.add_by_day
        FROM   capf_tbspc_forecast t
        LEFT   JOIN capr_tbspc_days_to_full r
          ON   r.dbid = t.dbid AND r.con_dbid = t.con_dbid
         AND   r.tablespace_name = t.tablespace_name
        UNION ALL
        SELECT t.dbid, t.con_dbid, 'CPU', t.metric,
               CASE t.metric WHEN 'DB_CPU_SEC' THEN 'sec' ELSE 'pct' END, t.slope_method,
               t.cur_val,
               CASE WHEN t.metric <> 'DB_CPU_SEC' THEN cfg.cpu_sat_pct END,
               CASE WHEN t.metric <> 'DB_CPU_SEC' THEN t.cur_val END,
               t.slope_per_day, t.r2, t.quality,
               t.days_to_sat, t.days_to_sat_lo, t.days_to_sat_hi,
               NULL, t.train_n,
               CASE al.sev_rank WHEN 1 THEN 'CRIT' WHEN 2 THEN 'WARN' ELSE 'OK' END,
               NULL, t.last_day,
               CASE t.is_current WHEN 'Y' THEN 1 ELSE 0 END, NULL,
               NULL, NULL, NULL, NULL,
               CASE t.slope_sig WHEN 'Y' THEN 1 ELSE 0 END,
               CASE t.hot_now WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END,
               NULL, NULL, NULL, CAST(NULL AS DATE)
        FROM   capf_cpu_trend t
        CROSS  JOIN cap_cfg cfg
        LEFT   JOIN (SELECT dbid, con_dbid, series_key, MIN(sev_rank) AS sev_rank
                     FROM   capr_alerts
                     WHERE  kind IN ('CPU_SAT', 'DBCPU_SAT')
                     GROUP  BY dbid, con_dbid, series_key) al
          ON   al.dbid = t.dbid AND al.con_dbid = t.con_dbid AND al.series_key = t.metric
        UNION ALL
        SELECT t.dbid, t.con_dbid, 'SERIES', t.series,
               LOWER(t.unit), NULL,
               t.cur_val, t.cur_limit, t.pct_of_limit,
               t.slope_per_day, t.r2, t.quality,
               t.days_to_limit, t.days_to_limit_lo, t.days_to_limit_hi,
               NULL, t.train_n,
               NVL(UPPER(r.sev), 'OK'),
               NULL, t.last_day,
               CASE t.is_current WHEN 'Y' THEN 1 ELSE 0 END, NULL,
               NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, CAST(NULL AS DATE)
        FROM   capf_series_forecast t
        LEFT   JOIN capr_series r
          ON   r.dbid = t.dbid AND r.con_dbid = t.con_dbid AND r.series = t.series
      ) f
LEFT   JOIN capr_container c
  ON   c.dbid = f.dbid AND c.con_dbid = f.con_dbid;
