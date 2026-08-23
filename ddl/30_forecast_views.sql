--
-- ddl/30_forecast_views.sql -- CAPF_* Tier 1 (pure-SQL linear) forecasts.
-- =====================================================================
-- Ordinary-least-squares linear fits via Oracle's built-in REGR_* aggregates,
-- so every projection is reproducible by hand from slope + intercept. All
-- tuning comes from CAP_CONFIG through a one-row `cfg` CTE.
--
--   CAPF_TBSPC_FORECAST -- per tablespace: bytes/day slope, R^2, +30/90/180/365
--                          day projections, days_to_full, recent-vs-full
--                          acceleration ratio, and a quality grade.
--   CAPF_CPU_TREND      -- per (host busy%, DB CPU sec) series: slope, R^2,
--                          projections, days_to_saturation, quality.
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
               REGR_COUNT(dd.used_bytes, dd.day_n)     AS n
        FROM   dd CROSS JOIN cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
        GROUP  BY dd.dbid, dd.con_dbid, dd.tablespace_name
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
       CASE WHEN f.slope > 0
            THEN FLOOR((c.limit_bytes - c.cur_used) / f.slope)
       END                                                AS days_to_full,
       r.recent_slope                                     AS recent_slope_bpd,
       CASE WHEN f.slope <> 0
            THEN r.recent_slope / f.slope
       END                                                AS accel_ratio,
       CASE WHEN f.n  < cfg.min_train_days     THEN 'INSUFFICIENT_HISTORY'
            WHEN f.slope = 0 OR f.r2 IS NULL   THEN 'FLAT'
            WHEN f.r2 < cfg.r2_gate            THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                                AS quality
FROM   fit f
JOIN   cur  c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid
             AND c.tablespace_name = f.tablespace_name
LEFT   JOIN rfit r ON r.dbid = f.dbid AND r.con_dbid = f.con_dbid
                  AND r.tablespace_name = f.tablespace_name
CROSS  JOIN cfg;

-- --------------------------------------------------------------------
-- CAPF_CPU_TREND -- one row per (dbid, con_dbid, metric) where metric is
-- BUSY_PCT (host CPU utilization, from CAPD_CPU_DAILY) or DB_CPU_SEC (DB CPU
-- seconds/day, from CAPD_DBTIME_DAILY). days_to_sat applies to BUSY_PCT only
-- (crossing cpu_sat_pct); it is NULL for DB_CPU_SEC (no fixed ceiling).
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
        SELECT dbid, con_dbid, 'BUSY_PCT'   AS metric, day_dt, busy_pct   AS val
        FROM   capd_cpu_daily    WHERE busy_pct   IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'DB_CPU_SEC' AS metric, day_dt, db_cpu_sec AS val
        FROM   capd_dbtime_daily WHERE db_cpu_sec IS NOT NULL
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
               REGR_COUNT(dd.val, dd.day_n)    AS n
        FROM   dd CROSS JOIN cfg
        WHERE  dd.day_dt > dd.last_day - cfg.train_days
        GROUP  BY dd.dbid, dd.con_dbid, dd.metric
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
       -- GREATEST(0,...): if current busy% already exceeds the saturation
       -- threshold, report 0 (saturated now) rather than a negative "days".
       CASE WHEN f.metric = 'BUSY_PCT' AND f.slope > 0
            THEN GREATEST(0, FLOOR((cfg.cpu_sat_pct - c.cur_val) / f.slope))
       END                                          AS days_to_sat,
       CASE WHEN f.n  < cfg.min_train_days     THEN 'INSUFFICIENT_HISTORY'
            WHEN f.slope = 0 OR f.r2 IS NULL   THEN 'FLAT'
            WHEN f.r2 < cfg.r2_gate            THEN 'LOW_CONFIDENCE'
            ELSE 'OK'
       END                                          AS quality
FROM   fit f
JOIN   cur c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid AND c.metric = f.metric
CROSS  JOIN cfg;
