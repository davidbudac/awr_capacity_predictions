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
--   CAPR_ALERTS    -- one row per current issue, pollable by OEM metric
--                     extensions / Zabbix / Nagios / a scheduler job:
--                       severity   CRIT | WARN | INFO  (sev_rank 1|2|3)
--                       kind       TBSPC_FULL | TBSPC_NEARFULL | TBSPC_ANOM |
--                                  CPU_SAT | DBCPU_SAT | CPU_ANOM
--                     plus keys (dbid, con_dbid, db_pdb, series_key), the
--                     observation day, the metric value vs its threshold, and
--                     a ready-to-page plain-text message.
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
-- CAPR_ALERTS
-- Every branch is hand-auditable against the view it reads:
--   TBSPC_FULL     capf_tbspc_forecast: quality=OK, days_to_full <= dtf_warn.
--   TBSPC_NEARFULL capf_tbspc_forecast: pct_used >= nearfull_warn_pct,
--                  REGARDLESS of fit quality (M7.1: a 97%-full tablespace with
--                  an unreliable fit must still surface).
--   CPU_SAT        capf_cpu_trend BUSY_P95 (or BUSY_PCT when cpu_sat_on_p95=0):
--                  quality=OK, days_to_sat <= dtf_warn.
--   DBCPU_SAT      capf_cpu_trend DB_CPU_PCT (per container, M10.2): same rule.
--   TBSPC_ANOM     capa_tbspc_anom flagged within the last anomaly_report_days
--                  (HIGH growth -> WARN, LOW/shrink -> INFO).
--   CPU_ANOM       capa_cpu_anom, same window/severity mapping.
-- value/threshold carry the number that crossed and the limit it crossed
-- (units in the unit column), so a poller can alarm without parsing message.
-- db_pdb resolves through CAPR_CONTAINER; unknown containers degrade to the
-- raw con_dbid string.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_alerts AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'dtf_warn'            THEN cfg_value END) AS dtf_warn,
               MAX(CASE WHEN cfg_name = 'dtf_crit'            THEN cfg_value END) AS dtf_crit,
               MAX(CASE WHEN cfg_name = 'nearfull_warn_pct'   THEN cfg_value END) AS nf_warn,
               MAX(CASE WHEN cfg_name = 'nearfull_crit_pct'   THEN cfg_value END) AS nf_crit,
               MAX(CASE WHEN cfg_name = 'cpu_sat_pct'         THEN cfg_value END) AS cpu_sat,
               MAX(CASE WHEN cfg_name = 'anomaly_report_days' THEN cfg_value END) AS anom_days,
               -- which host-busy trend drives CPU_SAT (M10.1): p95 of the
               -- day's snapshot intervals (default) or the daily average
               CASE WHEN MAX(CASE WHEN cfg_name = 'cpu_sat_on_p95' THEN cfg_value END) = 0
                    THEN 'BUSY_PCT' ELSE 'BUSY_P95' END                       AS cpu_sat_metric
        FROM   cap_config
     ),
     alerts AS (
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
                 || TO_CHAR(f.slope_bpd / 1048576, 'FM99999990.0') || ' MiB/day)' AS message
        FROM   capf_tbspc_forecast f CROSS JOIN cfg
        WHERE  f.quality = 'OK'
          AND  f.days_to_full IS NOT NULL
          AND  f.days_to_full <= cfg.dtf_warn
        UNION ALL
        -- ---- TBSPC_NEARFULL: nearly full RIGHT NOW, any fit quality ----
        SELECT CASE WHEN f.pct_used >= cfg.nf_crit THEN 'CRIT' ELSE 'WARN' END,
               'TBSPC_NEARFULL',
               f.dbid, f.con_dbid,
               f.tablespace_name,
               f.last_day,
               f.pct_used,
               CASE WHEN f.pct_used >= cfg.nf_crit THEN cfg.nf_crit ELSE cfg.nf_warn END,
               'PCT',
               'Tablespace ' || f.tablespace_name || ' is '
                 || TO_CHAR(f.pct_used, 'FM990.0') || '% full now ('
                 || TO_CHAR(f.cur_used / 1073741824, 'FM99999990.00') || ' of '
                 || TO_CHAR(f.limit_bytes / 1073741824, 'FM99999990.00')
                 || ' GiB; forecast quality ' || f.quality || ')'
        FROM   capf_tbspc_forecast f CROSS JOIN cfg
        WHERE  f.pct_used >= cfg.nf_warn
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
                 || 'forecast to reach ' || TO_CHAR(cfg.cpu_sat, 'FM990')
                 || '% busy in ' || TO_CHAR(t.days_to_sat, 'FM9999990')
                 || ' days (now ' || TO_CHAR(t.cur_val, 'FM990.0') || '% busy)'
        FROM   capf_cpu_trend t CROSS JOIN cfg
        WHERE  t.metric = cfg.cpu_sat_metric
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
               'DB CPU forecast to reach ' || TO_CHAR(cfg.cpu_sat, 'FM990')
                 || '% of host core capacity in ' || TO_CHAR(t.days_to_sat, 'FM9999990')
                 || ' days (now ' || TO_CHAR(t.cur_val, 'FM990.0') || '%)'
        FROM   capf_cpu_trend t CROSS JOIN cfg
        WHERE  t.metric = 'DB_CPU_PCT'
          AND  t.quality = 'OK'
          AND  t.days_to_sat IS NOT NULL
          AND  t.days_to_sat <= cfg.dtf_warn
        UNION ALL
        -- ---- TBSPC_ANOM: flagged growth-rate days in the alert window ----
        SELECT CASE WHEN a.anomaly_flag = 'HIGH' THEN 'WARN' ELSE 'INFO' END,
               'TBSPC_ANOM',
               a.dbid, a.con_dbid,
               a.tablespace_name,
               a.day_dt,
               a.used_delta_bytes,
               a.threshold_bpd,
               'BYTES',
               'Tablespace ' || a.tablespace_name
                 || CASE WHEN a.anomaly_flag = 'HIGH' THEN ' grew ' ELSE ' shrank ' END
                 || TO_CHAR(ABS(a.used_delta_bytes) / 1073741824, 'FM99999990.00')
                 || ' GiB on ' || TO_CHAR(a.day_dt, 'YYYY-MM-DD')
                 -- robust_z is NULL when the baseline MAD is 0 (a spike off a
                 -- perfectly steady series) -- exactly when the jump is most
                 -- clear-cut, so say that instead of printing an empty number.
                 || ' (robust z '
                 || NVL(TO_CHAR(a.robust_z, 'FM99990.0'), 'off-scale, flat baseline') || ')'
        FROM   capa_tbspc_anom a CROSS JOIN cfg
        WHERE  a.anomaly_flag IS NOT NULL
          AND  a.day_dt > (SELECT MAX(day_dt) FROM capd_tbspc_daily) - cfg.anom_days
        UNION ALL
        -- ---- CPU_ANOM: flagged busy% days in the alert window ----
        SELECT CASE WHEN a.anomaly_flag = 'HIGH' THEN 'WARN' ELSE 'INFO' END,
               'CPU_ANOM',
               a.dbid, a.con_dbid,
               'BUSY_PCT',
               a.day_dt,
               a.busy_pct,
               a.median_pct + CASE WHEN a.anomaly_flag = 'HIGH'
                                   THEN a.threshold_pct ELSE -a.threshold_pct END,
               'PCT',
               'Host CPU ' || TO_CHAR(a.busy_pct, 'FM990.0') || '% busy on '
                 || TO_CHAR(a.day_dt, 'YYYY-MM-DD') || ' vs usual '
                 || TO_CHAR(a.median_pct, 'FM990.0') || '% for that weekday'
        FROM   capa_cpu_anom a CROSS JOIN cfg
        WHERE  a.anomaly_flag IS NOT NULL
          AND  a.day_dt > (SELECT MAX(day_dt) FROM capd_cpu_daily) - cfg.anom_days
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
       a.message
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
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_tbspc_days_to_full AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'dtf_warn'          THEN cfg_value END) AS dtf_warn,
               MAX(CASE WHEN cfg_name = 'dtf_crit'          THEN cfg_value END) AS dtf_crit,
               MAX(CASE WHEN cfg_name = 'nearfull_warn_pct' THEN cfg_value END) AS nf_warn,
               MAX(CASE WHEN cfg_name = 'nearfull_crit_pct' THEN cfg_value END) AS nf_crit
        FROM   cap_config
     )
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
       CASE WHEN f.pct_used >= cfg.nf_crit THEN 'CRIT'
            WHEN f.pct_used >= cfg.nf_warn THEN 'WARN'
            ELSE 'ok'  END                 AS sev_nearfull,
       f.quality,
       f.r2,
       f.accel_ratio                       AS accel,
       ROW_NUMBER() OVER (ORDER BY f.days_to_full NULLS LAST,
                                   f.con_dbid, f.tablespace_name)  AS rank_dtf,
       ROW_NUMBER() OVER (ORDER BY f.pct_used DESC NULLS LAST,
                                   f.con_dbid, f.tablespace_name)  AS rank_nearfull
FROM   capf_tbspc_forecast f
CROSS  JOIN cfg
LEFT   JOIN capr_container c
  ON   c.dbid = f.dbid AND c.con_dbid = f.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_TBSPC_ANOMALIES -- report section 3. Every FLAGGED day (no window
-- applied here); a driver bounds it with  WHERE days_ago < anomaly_days.
-- days_ago is measured from MAX(day_dt) over ALL of CAPD_TBSPC_DAILY --
-- the same reference the report used before, so "last N days" means the
-- last N collected days, not the last N days before an anomaly.
-- day_str is the pre-formatted YYYY-MM-DD the reports print; day_dt stays
-- a DATE for consumers that want to compare it.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_tbspc_anomalies AS
SELECT a.dbid,
       a.con_dbid,
       NVL(c.db_pdb, TO_CHAR(a.con_dbid))      AS db_pdb,
       a.tablespace_name,
       a.day_dt,
       TO_CHAR(a.day_dt, 'YYYY-MM-DD')         AS day_str,
       (SELECT MAX(day_dt) FROM capd_tbspc_daily) - a.day_dt AS days_ago,
       a.day_gap                               AS gap,
       a.used_delta_bytes / 1048576            AS delta_mb,
       a.used_rate_bpd    / 1048576            AS rate_mb,
       a.median_rate_bpd  / 1048576            AS med_mb,
       a.threshold_bpd    / 1048576            AS thr_mb,
       a.robust_z                              AS z,
       a.anomaly_flag
FROM   capa_tbspc_anom a
LEFT   JOIN capr_container c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid
WHERE  a.anomaly_flag IS NOT NULL;

-- --------------------------------------------------------------------
-- CAPR_CPU_TREND -- report section 4. One row per (container, metric):
-- BUSY_PCT / BUSY_P95 / BUSY_PEAK / DB_CPU_SEC / DB_CPU_PCT / DB_CPU_P95.
-- sat_worst / sat_best are the M9.1 days-to-saturation range (lo = worst
-- case / soonest; hi NULL = might never saturate).
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
       t.quality
FROM   capf_cpu_trend t
LEFT   JOIN capr_container c
  ON   c.dbid = t.dbid AND c.con_dbid = t.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_CPU_ANOMALIES -- report section 5. Same shape/contract as
-- CAPR_TBSPC_ANOMALIES: flagged rows only, days_ago measured from
-- MAX(day_dt) over CAPD_CPU_DAILY.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_cpu_anomalies AS
SELECT a.dbid,
       a.con_dbid,
       NVL(c.db_pdb, TO_CHAR(a.con_dbid))    AS db_pdb,
       a.day_dt,
       TO_CHAR(a.day_dt, 'YYYY-MM-DD')       AS day_str,
       (SELECT MAX(day_dt) FROM capd_cpu_daily) - a.day_dt AS days_ago,
       a.busy_pct,
       a.median_pct,
       a.threshold_pct,
       a.robust_z                            AS z,
       a.anomaly_flag
FROM   capa_cpu_anom a
LEFT   JOIN capr_container c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid
WHERE  a.anomaly_flag IS NOT NULL;
