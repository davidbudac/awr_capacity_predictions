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
--                                  CPU_SAT | CPU_ANOM
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
--   CPU_SAT        capf_cpu_trend BUSY_PCT: quality=OK, days_to_sat <= dtf_warn.
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
               MAX(CASE WHEN cfg_name = 'anomaly_report_days' THEN cfg_value END) AS anom_days
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
               'Host CPU forecast to reach ' || TO_CHAR(cfg.cpu_sat, 'FM990')
                 || '% busy in ' || TO_CHAR(t.days_to_sat, 'FM9999990')
                 || ' days (now ' || TO_CHAR(t.cur_val, 'FM990.0') || '% busy)'
        FROM   capf_cpu_trend t CROSS JOIN cfg
        WHERE  t.metric = 'BUSY_PCT'
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
