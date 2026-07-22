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
--                      role for a perfectly flat seasonal baseline.
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
        SELECT dbid, con_dbid, day_dt, busy_pct AS val
        FROM   capd_cpu_daily
        WHERE  busy_pct IS NOT NULL
     ),
     gen AS (
        SELECT LEVEL AS lv FROM dual CONNECT BY LEVEL <= (SELECT dow_weeks FROM cfg)
     ),
     hist AS (
        SELECT c.dbid, c.con_dbid, c.day_dt, c.val, h.val AS hval
        FROM   base c
        CROSS  JOIN gen g
        JOIN   base h
          ON   h.dbid = c.dbid AND h.con_dbid = c.con_dbid
         AND   h.day_dt = c.day_dt - 7 * g.lv
     ),
     med AS (
        SELECT dbid, con_dbid, day_dt, val,
               MEDIAN(hval) AS med, COUNT(hval) AS n_hist
        FROM   hist
        GROUP  BY dbid, con_dbid, day_dt, val
     ),
     madc AS (
        SELECT m.dbid, m.con_dbid, m.day_dt, m.val, m.med, m.n_hist,
               MEDIAN(ABS(h.hval - m.med)) * 1.4826 AS mad_sigma
        FROM   med m
        JOIN   hist h
          ON   h.dbid = m.dbid AND h.con_dbid = m.con_dbid AND h.day_dt = m.day_dt
        GROUP  BY m.dbid, m.con_dbid, m.day_dt, m.val, m.med, m.n_hist
     )
SELECT a.dbid,
       a.con_dbid,
       a.day_dt,
       a.val                                                        AS busy_pct,
       a.med                                                        AS median_pct,
       a.mad_sigma,
       a.n_hist,
       a.val - a.med                                                AS dev_pct,
       cfg.mad_k * GREATEST(a.mad_sigma, cfg.min_mad)               AS threshold_pct,
       (a.val - a.med) / NULLIF(GREATEST(a.mad_sigma, cfg.min_mad), 0) AS robust_z,
       CASE
           WHEN a.n_hist >= cfg.min_hist
            AND (a.val - a.med) >  cfg.mad_k * GREATEST(a.mad_sigma, cfg.min_mad) THEN 'HIGH'
           WHEN a.n_hist >= cfg.min_hist
            AND (a.med - a.val) >  cfg.mad_k * GREATEST(a.mad_sigma, cfg.min_mad) THEN 'LOW'
           ELSE NULL
       END                                                          AS anomaly_flag
FROM   madc a CROSS JOIN cfg;
