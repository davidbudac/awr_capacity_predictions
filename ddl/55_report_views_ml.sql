--
-- ddl/55_report_views_ml.sql -- CAPR_* report views that need Tier 2 (M8.2).
-- =====================================================================
-- The rest of the CAPR_* report layer lives in ddl/45_report_views.sql. These
-- views are split out ONLY because they read CAPF_COMPARE / CAPF_BACKTEST /
-- CAPF_ESM_HEALTH_SUMMARY and CAP_ML_MODEL, which ddl/50_ml.sql creates AFTER
-- 45 -- so install.sql loads this file last (see its [55] step). Same
-- contract as the others: every derived number, label and unit conversion
-- is computed here so
-- report/report.sql and report/report_html.sql only format.
--
--   CAPR_TBSPC_FORECAST -- section 2 body: per-tablespace REGR projections in
--                          GiB with the +180 prediction band, R2, quality and
--                          the Tier 2 ESM point (with its bounds) from
--                          CAPF_COMPARE's 30-day bucket. Also
--                          carries the raw bytes columns and rank_chart, so
--                          the HTML chart grid reads its geometry inputs from
--                          the same row the table prints.
--   CAPR_ESM_COMPARE    -- sections 6a/6b: one row per
--                          (container, series, horizon) with REGR vs ESM side
--                          by side, in raw units AND GiB (6a prints GiB,
--                          6b raw); filter on series_kind.
--
-- M7.4: both carry is_reportable ('Y'/'N') + rank_report, so both report
-- drivers bound sections 2 and 6a with the identical
--   WHERE is_reportable = 'Y' AND rank_report <= &top_n
-- while the views themselves still expose every row to other consumers.
--   CAPR_TBSPC_RANK     -- that reportability and the two ranks, decided once
--                          over CAPF_TBSPC_FORECAST; both views above read it.
--   CAPR_BACKTEST       -- section 6c: the M9.4 holdout scorecard pivoted to
--                          one row per series, incl. the BETTER verdict and
--                          (M10.4) the ESM model-type pick + its rationale.
--   CAPR_FORECAST_POINTS -- REGR anchors + the ESM point as chartable
--                          rows, for grafana/API.md and elk/.
--   CAPR_ALERTS         -- the pollable alert surface (bottom of this file):
--                          here because its MODEL_HEALTH kind reads the
--                          Tier 2 health view.
--
-- Read-only, like everything else in the suite.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPR_TBSPC_FORECAST
-- The ESM point comes from a single LEFT JOIN onto the ESM/TBSPC/+30
-- slice of CAPF_COMPARE (at most one row per series -- CAPF_COMPARE's ESM
-- branch is already unique on that key), rather than a scalar subquery per
-- column, so the pipelined ESM source is walked once. esm30 / esm30_lo /
-- esm30_hi keep their names but hold the model's furthest step, which is
-- esm_horizon_days (<= 30) after trained_through; esm_age_days is the model
-- age. Both are appended last so positional consumers keep their columns.
-- rank_chart reproduces the HTML chart grid's own ordering
-- (days_to_full NULLS LAST, then name) so that driver can cap at top_n with
-- a plain WHERE.
-- --------------------------------------------------------------------
-- --------------------------------------------------------------------
-- CAPR_TBSPC_RANK -- M7.4 reportability and the section ranks, one row per
-- CAPF_TBSPC_FORECAST row. Decided once here so section 2
-- (CAPR_TBSPC_FORECAST) and section 6a (CAPR_ESM_COMPARE) bound the same set
-- of tablespaces, and so 6a needs no second walk of CAPF_COMPARE through
-- CAPR_TBSPC_FORECAST. A row is worth printing when it is GROWING, or
-- already NEAR-FULL, or simply BIG (>= report_min_gb GiB) -- which leaves out
-- exactly the small, flat, half-empty tablespaces that turn a 500-tablespace
-- database into 500 lines of noise. cur_used IS NULL reports as 'Y': the
-- bound must never hide a row we cannot judge.
--   rank_report  reportable rows first, then growing ones, then the biggest
--                -- so WHERE is_reportable='Y' AND rank_report <= top_n
--                keeps the top_n rows that matter and a non-reportable row
--                can never consume a slot ahead of a reportable one.
--   rank_chart   the HTML chart grid's order: days_to_full NULLS LAST, name.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_tbspc_rank AS
WITH f AS (
        SELECT t.dbid, t.con_dbid, t.tablespace_name, t.cur_used, t.slope_bpd, t.days_to_full,
               CASE WHEN t.cur_used IS NULL                           THEN 'Y'
                    WHEN NVL(t.slope_bpd, 0) > 0                      THEN 'Y'
                    WHEN t.cur_used >= cfg.report_min_gb * 1073741824 THEN 'Y'
                    WHEN NVL(t.pct_used, 0) >= cfg.nearfull_warn_pct  THEN 'Y'
                    ELSE 'N'
               END                                                    AS is_reportable
        FROM   capf_tbspc_forecast t CROSS JOIN cap_cfg cfg
     )
SELECT f.dbid,
       f.con_dbid,
       f.tablespace_name,
       f.is_reportable,
       ROW_NUMBER() OVER (ORDER BY CASE WHEN f.is_reportable = 'Y' THEN 0 ELSE 1 END,
                                   CASE WHEN NVL(f.slope_bpd, 0) > 0 THEN 0 ELSE 1 END,
                                   f.cur_used DESC NULLS LAST,
                                   f.con_dbid, f.tablespace_name)  AS rank_report,
       ROW_NUMBER() OVER (ORDER BY f.days_to_full NULLS LAST,
                                   f.tablespace_name)  AS rank_chart
FROM   f;

CREATE OR REPLACE VIEW capr_tbspc_forecast AS
WITH f AS (
        SELECT t.*, r.is_reportable, r.rank_report, r.rank_chart
        FROM   capf_tbspc_forecast t
        JOIN   capr_tbspc_rank r
          ON   r.dbid = t.dbid AND r.con_dbid = t.con_dbid AND r.tablespace_name = t.tablespace_name
     )
SELECT f.dbid,
       f.con_dbid,
       NVL(cn.db_pdb, TO_CHAR(f.con_dbid)) AS db_pdb,
       f.tablespace_name,
       f.train_n,
       f.quality,
       f.r2,
       f.days_to_full,
       -- raw bytes, for chart geometry and for consumers that want no rounding
       f.cur_used                          AS cur_bytes,
       f.limit_bytes,
       f.limit_source,
       f.slope_bpd,
       -- display columns (GiB)
       f.cur_used       / 1073741824       AS cur_gb,
       f.limit_bytes    / 1073741824       AS limit_gb,
       f.proj_30_bytes  / 1073741824       AS p30,
       f.proj_90_bytes  / 1073741824       AS p90,
       f.proj_180_bytes / 1073741824       AS p180,
       f.proj_180_lo    / 1073741824       AS p180_lo,
       f.proj_180_hi    / 1073741824       AS p180_hi,
       e.value          / 1073741824       AS esm30,
       e.lower_bound    / 1073741824       AS esm30_lo,
       e.upper_bound    / 1073741824       AS esm30_hi,
       f.is_reportable,
       f.rank_report,
       f.rank_chart,
       e.esm_horizon_days,
       e.model_age_days                    AS esm_age_days
FROM   f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
LEFT   JOIN (SELECT dbid, con_dbid, series_key, value, lower_bound, upper_bound,
                    esm_horizon_days, model_age_days
             FROM   capf_compare
             WHERE  engine = 'ESM' AND series_kind = 'TBSPC' AND horizon_days = 30) e
  ON   e.dbid = f.dbid AND e.con_dbid = f.con_dbid
 AND   e.series_key = f.tablespace_name;

-- --------------------------------------------------------------------
-- CAPR_ESM_COMPARE -- sections 6a (series_kind='TBSPC', GiB columns) and
-- 6b (series_kind='CPU', raw columns). ESM columns are populated only where
-- a model no older than esm_max_age_days exists, in the 30-day bucket
-- (Oracle's ESM cap is +30 on 19c); +90/180/365 are REGR-only by design.
-- M10.4 adds esm_model_type / esm_model: which candidate (EXSM_HOLT or
-- EXSM_ADDWINTERS/7) the production model for that series was trained with.
-- esm_horizon_days / esm_age_days: the step the ESM value sits at and the
-- model's age (CAPF_COMPARE). esm_at is the printable step, '+22', set only
-- when it differs from the row's horizon_days.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_esm_compare AS
SELECT f.dbid,
       f.con_dbid,
       NVL(MAX(cn.db_pdb), TO_CHAR(f.con_dbid))              AS db_pdb,
       f.series_kind,
       f.series_key,
       f.horizon_days,
       MAX(CASE WHEN f.engine = 'REGR' THEN f.value END)       AS regr,
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.value END)       AS esm,
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.lower_bound END) AS esm_lo,
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.upper_bound END) AS esm_hi,
       MAX(CASE WHEN f.engine = 'REGR' THEN f.value END)       / 1073741824 AS regr_gb,
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.value END)       / 1073741824 AS esm_gb,
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.lower_bound END) / 1073741824 AS esm_lo_gb,
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.upper_bound END) / 1073741824 AS esm_hi_gb,
       -- M10.4: which ESM candidate produced this row, full name and a 4-char
       -- form the narrow text report can afford. NULL where no ESM point.
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.model_type END)  AS esm_model_type,
       CASE MAX(CASE WHEN f.engine = 'ESM' THEN f.model_type END)
            WHEN 'EXSM_ADDWINTERS' THEN 'ADDW'
            WHEN 'EXSM_HOLT'       THEN 'HOLT'
       END                                                     AS esm_model,
       -- M7.4: section 6a applies the SAME bound as section 2, read from
       -- CAPR_TBSPC_RANK as CAPR_TBSPC_FORECAST does, so the two sections can
       -- never disagree about which tablespaces are worth printing. CPU rows
       -- (6b) are always reportable with rank_report 0, so the identical
       -- WHERE is_reportable='Y' AND rank_report <= top_n never drops them.
       CASE WHEN f.series_kind = 'TBSPC'
            THEN NVL(MAX(tf.is_reportable), 'Y') ELSE 'Y' END  AS is_reportable,
       CASE WHEN f.series_kind = 'TBSPC'
            THEN NVL(MAX(tf.rank_report), 0)     ELSE 0   END  AS rank_report,
       MAX(CASE WHEN f.engine = 'ESM' THEN f.esm_horizon_days END) AS esm_horizon_days,
       MAX(CASE WHEN f.engine = 'ESM' THEN f.model_age_days END)   AS esm_age_days,
       CASE WHEN MAX(CASE WHEN f.engine = 'ESM' THEN f.esm_horizon_days END) <> f.horizon_days
            THEN '+' || MAX(CASE WHEN f.engine = 'ESM' THEN f.esm_horizon_days END)
       END                                                     AS esm_at
FROM   capf_compare f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
LEFT   JOIN capr_tbspc_rank tf
  ON   f.series_kind = 'TBSPC'
 AND   tf.dbid = f.dbid AND tf.con_dbid = f.con_dbid
 AND   tf.tablespace_name = f.series_key
GROUP  BY f.dbid, f.con_dbid, f.series_kind, f.series_key, f.horizon_days;

-- --------------------------------------------------------------------
-- CAPR_BACKTEST -- section 6c. CAPF_BACKTEST is one row per (series, engine);
-- this pivots it to one row per series with REGR and ESM side by side plus
-- the BETTER verdict (NULL when either engine has no score, e.g. before
-- EXEC cap_forecast_ml.train_backtest). cutoff_day is pre-formatted -- MIN()
-- because the two engines record the same cutoff from different sources.
-- esm_cutoff_day is the ESM twin's own cutoff: it differs from cutoff_day when
-- the twins are older than the data (train_all with p_backtest => FALSE).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_backtest AS
SELECT f.dbid,
       f.con_dbid,
       NVL(MAX(cn.db_pdb), TO_CHAR(f.con_dbid))            AS db_pdb,
       f.series_kind,
       f.series_key,
       TO_CHAR(MIN(f.cutoff_day), 'YYYY-MM-DD')            AS cutoff_day,
       -- M10.4 selection: the production model's type, how it was decided, and
       -- the two candidate MAPEs that decided it.
       NVL(MAX(p.model_type), MAX(f.model_type))           AS esm_model_type,
       MAX(p.chosen_by)                                    AS chosen_by,
       MAX(p.mape_holt)                                    AS mape_holt,
       MAX(p.mape_addw)                                    AS mape_addw,
       -- esm_pick: one narrow column that says WHICH and WHY, e.g.
       --   ADDW H=2.90 W=1.20     (AUTO: Holt 2.90% vs AddWinters 1.20% MAPE)
       --   HOLT tie H=0.07 W=0.06 (AUTO: within esm_auto_tie_pct, Holt kept)
       --   HOLT (config)          (pinned by esm_tbspc_model)
       CASE
            WHEN MAX(p.model_type) IS NULL THEN NULL
            WHEN MAX(p.chosen_by) IN ('AUTO_BACKTEST', 'AUTO_TIE')
              THEN CASE MAX(p.model_type) WHEN 'EXSM_ADDWINTERS' THEN 'ADDW' ELSE 'HOLT' END
                   || CASE WHEN MAX(p.chosen_by) = 'AUTO_TIE' THEN ' tie' END
                   || ' H=' || NVL(TO_CHAR(ROUND(MAX(p.mape_holt), 2), 'FM99990.00'), '-')
                   || ' W=' || NVL(TO_CHAR(ROUND(MAX(p.mape_addw), 2), 'FM99990.00'), '-')
            ELSE CASE MAX(p.model_type) WHEN 'EXSM_ADDWINTERS' THEN 'ADDW' ELSE 'HOLT' END
                 || ' (' || LOWER(NVL(MAX(p.chosen_by), 'default')) || ')'
       END                                                 AS esm_pick,
       MAX(CASE WHEN f.engine = 'REGR' THEN f.mape_pct END) AS regr_mape,
       MAX(CASE WHEN f.engine = 'REGR' THEN f.bias_pct END) AS regr_bias,
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.mape_pct END) AS esm_mape,
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.bias_pct END) AS esm_bias,
       CASE WHEN MAX(CASE WHEN f.engine = 'REGR' THEN f.mape_pct END) IS NULL
              OR MAX(CASE WHEN f.engine = 'ESM'  THEN f.mape_pct END) IS NULL
            THEN NULL
            WHEN MAX(CASE WHEN f.engine = 'ESM'  THEN f.mape_pct END)
               < MAX(CASE WHEN f.engine = 'REGR' THEN f.mape_pct END)
            THEN 'ESM'
            ELSE 'REGR'
       END                                                  AS better,
       TO_CHAR(MAX(CASE WHEN f.engine = 'ESM' THEN f.cutoff_day END),
               'YYYY-MM-DD')                                AS esm_cutoff_day
FROM   capf_backtest f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
-- M10.4: the production model's registry row carries the recorded decision.
-- series_key is unique per container across kinds (tablespace names vs the two
-- fixed CPU metric strings), so dbid/con_dbid/series_key identifies it.
LEFT   JOIN cap_ml_model p
  ON   p.purpose = 'FORECAST'
 AND   p.dbid = f.dbid AND p.con_dbid = f.con_dbid
 AND   p.series_key = f.series_key
GROUP  BY f.dbid, f.con_dbid, f.series_kind, f.series_key;

-- --------------------------------------------------------------------
-- CAPR_FORECAST_POINTS -- the projected points to chart after the observed
-- series (grafana/API.md, elk/export_capacity.sql): the REGR points at
-- horizon 0 (the anchor every projection starts from: the current value,
-- or for CPU the smoothed anchor_value) and +30/+90 (+180/+365 for TBSPC)
-- with their M9.1 bands, plus the ESM point. horizon 0 and the REGR horizons
-- therefore sit on one straight line. CPU percent rows carry the saturation
-- line cpu_sat_pct as limit_value (as CAPR_FIT) and pct = 100 * value /
-- cpu_sat_pct; DB_CPU_SEC has neither. ts = last observed day +
-- horizon on every row. CAPF_COMPARE folds DB CPU into kind CPU under
-- DB_CPU_SEC. The ESM value sits at trained_through + esm_horizon_days, so
-- its horizon here is esm_horizon_days - model_age_days (22 for a fresh
-- model on 90 rows, less as the model ages).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_forecast_points AS
SELECT p.dbid,
       p.con_dbid,
       NVL(c.db_pdb, TO_CHAR(p.con_dbid))  AS db,
       c.db_name,
       c.con_name,
       p.ts,
       p.kind,
       p.series,
       p.unit,
       p.method,
       p.horizon_days,
       p.value,
       p.lo,
       p.hi,
       p.limit_value,
       p.pct,
       p.quality
FROM  (
        SELECT t.dbid, t.con_dbid, t.last_day + h.h AS ts, 'TBSPC' AS kind,
               t.tablespace_name AS series, 'bytes' AS unit, 'REGR' AS method,
               h.h AS horizon_days, h.val AS value, h.lo, h.hi,
               t.limit_bytes AS limit_value,
               ROUND(100 * h.val / NULLIF(t.limit_bytes, 0), 2) AS pct, t.quality
        FROM   capf_tbspc_forecast t
        CROSS  APPLY (SELECT 0 AS h, t.cur_used AS val, CAST(NULL AS NUMBER) AS lo, CAST(NULL AS NUMBER) AS hi FROM dual UNION ALL
                      SELECT 30,  t.proj_30_bytes,  t.proj_30_lo,  t.proj_30_hi  FROM dual UNION ALL
                      SELECT 90,  t.proj_90_bytes,  t.proj_90_lo,  t.proj_90_hi  FROM dual UNION ALL
                      SELECT 180, t.proj_180_bytes, t.proj_180_lo, t.proj_180_hi FROM dual UNION ALL
                      SELECT 365, t.proj_365_bytes, t.proj_365_lo, t.proj_365_hi FROM dual) h
        WHERE  t.quality <> 'INSUFFICIENT_HISTORY'
          AND  h.val IS NOT NULL
        UNION ALL
        SELECT t.dbid, t.con_dbid, t.last_day + h.h, 'CPU',
               t.metric, CASE t.metric WHEN 'DB_CPU_SEC' THEN 'sec' ELSE 'pct' END, 'REGR',
               h.h, h.val, h.lo, h.hi,
               CASE WHEN t.metric <> 'DB_CPU_SEC' THEN cfg.cpu_sat_pct END,
               CASE WHEN t.metric <> 'DB_CPU_SEC'
                    THEN ROUND(100 * h.val / NULLIF(cfg.cpu_sat_pct, 0), 2) END, t.quality
        FROM   capf_cpu_trend t
        CROSS  JOIN cap_cfg cfg
        CROSS  APPLY (SELECT 0 AS h, t.anchor_value AS val, CAST(NULL AS NUMBER) AS lo, CAST(NULL AS NUMBER) AS hi FROM dual UNION ALL
                      SELECT 30, t.proj_30, t.proj_30_lo, t.proj_30_hi FROM dual UNION ALL
                      SELECT 90, t.proj_90, t.proj_90_lo, t.proj_90_hi FROM dual) h
        WHERE  t.quality <> 'INSUFFICIENT_HISTORY'
          AND  h.val IS NOT NULL
        UNION ALL
        SELECT t.dbid, t.con_dbid, t.last_day + h.h, 'SERIES',
               t.series, LOWER(t.unit), 'REGR',
               h.h, h.val, h.lo, h.hi,
               t.cur_limit, ROUND(100 * h.val / NULLIF(t.cur_limit, 0), 2), t.quality
        FROM   capf_series_forecast t
        CROSS  APPLY (SELECT 0 AS h, t.cur_val AS val, CAST(NULL AS NUMBER) AS lo, CAST(NULL AS NUMBER) AS hi FROM dual UNION ALL
                      SELECT 30, t.proj_30, t.proj_30_lo, t.proj_30_hi FROM dual UNION ALL
                      SELECT 90, t.proj_90, t.proj_90_lo, t.proj_90_hi FROM dual) h
        WHERE  t.quality <> 'INSUFFICIENT_HISTORY'
          AND  h.val IS NOT NULL
        UNION ALL
        SELECT t.dbid, t.con_dbid, f.last_day + (t.esm_horizon_days - t.model_age_days),
               t.series_kind, t.series_key,
               CASE WHEN t.series_kind = 'TBSPC' THEN 'bytes'
                    WHEN t.series_key = 'DB_CPU_SEC' THEN 'sec' ELSE 'pct' END,
               'ESM',
               t.esm_horizon_days - t.model_age_days, t.value, t.lower_bound, t.upper_bound,
               f.limit_val, ROUND(100 * t.value / NULLIF(f.limit_val, 0), 2), f.quality
        FROM   capf_compare t
        JOIN  (SELECT dbid, con_dbid, 'TBSPC' AS series_kind, tablespace_name AS series_key,
                      last_day, limit_bytes AS limit_val, quality
               FROM   capf_tbspc_forecast
               UNION ALL
               SELECT t.dbid, t.con_dbid, 'CPU', t.metric, t.last_day,
                      CASE WHEN t.metric <> 'DB_CPU_SEC' THEN cfg.cpu_sat_pct END, t.quality
               FROM   capf_cpu_trend t CROSS JOIN cap_cfg cfg) f
          ON   f.dbid = t.dbid AND f.con_dbid = t.con_dbid
         AND   f.series_kind = t.series_kind AND f.series_key = t.series_key
        WHERE  t.engine = 'ESM'
          AND  t.value IS NOT NULL
      ) p
LEFT   JOIN capr_container c
  ON   c.dbid = p.dbid AND c.con_dbid = p.con_dbid;

-- --------------------------------------------------------------------
-- CAPR_ALERTS -- one row per current issue, pollable by OEM metric
-- extensions / Zabbix / Nagios / a scheduler job (cap_report_spool).
--   severity   CRIT | WARN | INFO  (sev_rank 1 | 2 | 3)
--   kind       forecast kinds (every non-OK CAPR_SEVERITY row; the rules
--              and their gates are documented there):
--                TBSPC_FULL       days_to_full <= dtf_warn on an OK fit, or a
--                                 CYCLIC tablespace's peak line inside it
--                TBSPC_NEARFULL   pct_used >= nearfull_warn_pct, any quality
--                CPU_SAT          host BUSY_P95 (BUSY_PCT when
--                                 cpu_sat_on_p95 = 0) days_to_sat <= dtf_warn
--                DBCPU_SAT        a container's DB_CPU_PCT, same rule
--                CPU_HOT          host BUSY_P95 recent_p95_med >= cpu_sat_pct
--                                 now (CAPF_CPU_TREND.hot_now), any quality,
--                                 WARN only
--                DBCPU_HOT        a container's DB_CPU_P95, same rule
--                SERIES_LIMIT     days_to_limit <= dtf_warn on an OK fit
--                SERIES_NEARLIMIT pct_of_limit >= nearfull_warn_pct
--              Every forecast kind needs is_current = 'Y'; per-tablespace
--              thresholds come from CAP_TBSPC_OVERRIDE.
--              CPU_SHIFT (M10.3) a flagged sustained level shift, UP = WARN,
--              DOWN = INFO; capa_cpu_shift holds only the current state.
--              DATA_STALE   the dbid's newest AWR snapshot is stale_hours or
--              more old (CAPR_FRESHNESS, the one SYSDATE test), WARN. A dbid
--              data_stale_max_days or more old is retired: no alert, it shows
--              in CAPR_COVERAGE (ddl/60) instead.
--              MODEL_HEALTH Tier 2 FORECAST models per container: WARN when
--              any failed its last build, INFO when none failed but some are
--              stale. No registry rows, no row: a Tier 1 install stays silent.
--              TBSPC_ANOM / CPU_ANOM / DBCPU_ANOM / SERIES_ANOM: the alerting
--              CAPR_ANOMALIES rows (alert_modes_<family> enables the mode and
--              the day lies within anomaly_report_days), one row per EPISODE:
--              a run of consecutive flagged days of one (series,
--              baseline_mode). day_dt, value, threshold and alert_key are the
--              last day's; HIGH = WARN, LOW = INFO, the worst day wins. While
--              CAPA_CPU_SHIFT reports UP / DOWN for a CPU series, its flagged
--              days inside the shift's recent window are INFO and the message
--              ends ' (level shift active)': the CPU_SHIFT row is the one
--              alert for that step.
--   value, unit       the number that crossed (DAYS, PCT, HOURS, COUNT, BYTES,
--                     GIB)
--   threshold         the level it crossed: on the forecast kinds the CRIT
--                     threshold on a CRIT row and the WARN one otherwise; on
--                     an anomaly kind the bound crossed (expected +/- the
--                     allowed deviation)
--   alarm_threshold   the threshold that defines the WARN level, the same on
--                     every severity (dtf_warn for TBSPC_FULL, the bound for an
--                     anomaly, stale_hours for DATA_STALE, 1 model for
--                     MODEL_HEALTH)
--   direction         how value relates to alarm_threshold on an alert: LE
--                     (value <= it: the countdowns), GE (value >= it: levels,
--                     HIGH anomalies, DATA_STALE, MODEL_HEALTH), ABS
--                     (|value| > it: CPU_SHIFT); a LOW anomaly is LE
--   is_current        'Y' on every row today: forecast kinds require it,
--                     the others are dated events or current states
--   baseline_mode     the anomaly kinds' mode, NULL for every other kind
--   alert_key         dbid|con_dbid|kind|series_key|YYYY-MM-DD|mode ('-' when
--                     none): unique per ROW, so it changes with day_dt
--   state_key         kind|dbid|con_dbid|series_key|mode: stable across days,
--                     the key to track one issue from poll to poll
--   first_day, n_days, max_z
--                     anomaly kinds only (NULL elsewhere): the episode's first
--                     day, its length in days (day_dt - first_day + 1) and the
--                     robust z of its most extreme day (NULL = off-scale)
-- So a poller can key, de-duplicate and alarm without parsing message.
-- db_pdb resolves through CAPR_CONTAINER; unknown containers degrade to the
-- raw con_dbid string.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_alerts AS
WITH alerts AS (
        -- ---- forecast kinds: CAPR_SEVERITY reads each CAPF_ view once ----
        SELECT s.sev                   AS severity,
               s.kind,
               s.dbid, s.con_dbid,
               s.series_key,
               s.day_dt,
               s.value,
               s.threshold,
               s.unit,
               s.message,
               CAST(NULL AS VARCHAR2(12)) AS baseline_mode,
               s.direction,
               s.alarm_threshold,
               s.is_current,
               CAST(NULL AS DATE)   AS first_day,
               CAST(NULL AS NUMBER) AS n_days,
               CAST(NULL AS NUMBER) AS max_z
        FROM   capr_severity s
        WHERE  s.sev <> 'OK'
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
               NULL,
               'ABS',
               s.threshold_pct,
               'Y',
               NULL, NULL, NULL
        FROM   capa_cpu_shift s
        WHERE  s.shift_flag IS NOT NULL
        UNION ALL
        -- ---- DATA_STALE: the dead-man check. A stalled AWR otherwise reads
        -- as "no alerts" because every other test compares data with data.
        SELECT 'WARN',
               'DATA_STALE',
               f.dbid, f.dbid,
               'AWR_SNAPSHOT',
               f.newest_day,
               ROUND(f.age_hours, 1),
               f.stale_hours,
               'HOURS',
               'No AWR snapshot for ' || f.db_name || ' (dbid ' || TO_CHAR(f.dbid) || ') since '
                 || TO_CHAR(f.newest_snap, 'YYYY-MM-DD HH24:MI') || ', '
                 || TO_CHAR(f.age_hours, 'FM9999990.0') || ' hours ago (stale_hours '
                 || TO_CHAR(f.stale_hours) || '): its forecasts and alerts are frozen at that point',
               NULL,
               'GE',
               f.stale_hours,
               'Y',
               NULL, NULL, NULL
        FROM   capr_freshness f
        CROSS  JOIN cap_cfg cfg
        WHERE  f.is_stale = 'Y'
          AND  f.age_hours < cfg.data_stale_max_days * 24
        UNION ALL
        -- ---- MODEL_HEALTH: Tier 2 training that failed or went stale. The
        -- newest error comes straight from the registry (CAPF_ESM_HEALTH
        -- passes last_error / failed_at through unchanged).
        SELECT CASE WHEN h.n_failed > 0 THEN 'WARN' ELSE 'INFO' END,
               'MODEL_HEALTH',
               h.dbid, h.con_dbid,
               'ESM_MODELS',
               TRUNC(CASE WHEN h.n_failed > 0 THEN h.last_failed_at ELSE h.last_trained_at END),
               CASE WHEN h.n_failed > 0 THEN h.n_failed ELSE h.n_stale END,
               1,
               'COUNT',
               'Tier 2 ESM forecast models: ' || TO_CHAR(h.n_failed) || ' failed, '
                 || TO_CHAR(h.n_stale) || ' stale, ' || TO_CHAR(h.n_ok) || ' OK of '
                 || TO_CHAR(h.n_models)
                 || CASE WHEN e.last_error IS NOT NULL
                         THEN '; newest error: '
                              || SUBSTR(TRANSLATE(e.last_error, CHR(10) || CHR(13), '  '), 1, 120) END,
               NULL,
               'GE',
               1,
               'Y',
               NULL, NULL, NULL
        FROM   capf_esm_health_summary h
        LEFT   JOIN (SELECT dbid, con_dbid,
                            MAX(last_error) KEEP (DENSE_RANK LAST ORDER BY failed_at NULLS FIRST) AS last_error
                     FROM   cap_ml_model
                     WHERE  purpose = 'FORECAST' AND status = 'FAILED'
                     GROUP  BY dbid, con_dbid) e
          ON   e.dbid = h.dbid AND e.con_dbid = h.con_dbid
        WHERE  h.n_failed > 0 OR h.n_stale > 0
        UNION ALL
        -- ---- TBSPC_ANOM / CPU_ANOM / DBCPU_ANOM / SERIES_ANOM (M15): the
        -- alerting rows of CAPR_ANOMALIES. Three steps:
        --   d  one row per (series, baseline mode, day). An HOUR_OF_WEEK day
        --      carries its worst hour (largest |z|, earliest on a tie) and
        --      says how many hours flagged; it is HIGH-ranked when any is.
        --      The CPU_SHIFT rows of the same read give each CPU series its
        --      shift window (ts .. obs_day); a flagged day inside it is INFO.
        --   g  gaps and islands: obs_day minus its row number is constant
        --      along a run of consecutive days, so it numbers the episode.
        --   e  one row per episode, carrying its last day.
        SELECT CASE WHEN e.ep_rank = 2 THEN 'WARN' ELSE 'INFO' END,
               e.alert_kind,
               e.dbid, e.con_dbid,
               e.series,
               e.obs_day,
               e.value,
               e.expected + SIGN(e.value - e.expected) * e.threshold,
               CASE e.unit WHEN 'bytes_per_day' THEN 'BYTES' WHEN 'pct' THEN 'PCT'
                           WHEN 'count' THEN 'COUNT' ELSE 'GIB' END,
               CASE WHEN e.n_days > 1
                    THEN e.n_days || ' consecutive days, latest ' || TO_CHAR(e.obs_day, 'YYYY-MM-DD')
                         || ', peak robust z ' || NVL(TO_CHAR(e.max_z, 'FMS999999990.0'), 'off-scale')
                         || ': ' END
               || e.message
               || CASE WHEN e.n_events > 1
                       THEN '; ' || e.n_events || ' hours flagged that day' END
               || CASE WHEN e.ep_shift = 1 THEN ' (level shift active)' END,
               e.baseline_mode,
               CASE WHEN e.anomaly_flag = 'LOW' THEN 'LE' ELSE 'GE' END,
               e.expected + SIGN(e.value - e.expected) * e.threshold,
               'Y',
               e.first_day,
               e.n_days,
               e.max_z
        FROM  (SELECT g.*,
                      MIN(g.obs_day) OVER (PARTITION BY g.alert_kind, g.dbid, g.con_dbid, g.series,
                                                        g.baseline_mode, g.grp)           AS first_day,
                      COUNT(*)       OVER (PARTITION BY g.alert_kind, g.dbid, g.con_dbid, g.series,
                                                        g.baseline_mode, g.grp)           AS n_days,
                      MIN(g.day_sev) OVER (PARTITION BY g.alert_kind, g.dbid, g.con_dbid, g.series,
                                                        g.baseline_mode, g.grp)           AS ep_rank,
                      MAX(g.in_shift) OVER (PARTITION BY g.alert_kind, g.dbid, g.con_dbid, g.series,
                                                         g.baseline_mode, g.grp)          AS ep_shift,
                      CASE WHEN COUNT(g.z) OVER (PARTITION BY g.alert_kind, g.dbid, g.con_dbid, g.series,
                                                              g.baseline_mode, g.grp)
                              = COUNT(*)   OVER (PARTITION BY g.alert_kind, g.dbid, g.con_dbid, g.series,
                                                              g.baseline_mode, g.grp)
                           THEN MAX(g.z) KEEP (DENSE_RANK LAST ORDER BY ABS(g.z))
                                         OVER (PARTITION BY g.alert_kind, g.dbid, g.con_dbid, g.series,
                                                            g.baseline_mode, g.grp)
                      END                                                                 AS max_z,
                      ROW_NUMBER()   OVER (PARTITION BY g.alert_kind, g.dbid, g.con_dbid, g.series,
                                                        g.baseline_mode, g.grp
                                           ORDER BY g.obs_day DESC)                       AS ep_rn
               FROM  (SELECT d.*,
                             d.obs_day - ROW_NUMBER() OVER (PARTITION BY d.alert_kind, d.dbid, d.con_dbid,
                                                                         d.series, d.baseline_mode
                                                            ORDER BY d.obs_day)           AS grp,
                             CASE WHEN d.obs_day BETWEEN d.shift_from AND d.shift_to
                                  THEN 1 ELSE 0 END                                       AS in_shift,
                             CASE WHEN d.day_rank = 2
                                   AND NOT (d.obs_day BETWEEN NVL(d.shift_from, d.obs_day + 1)
                                                          AND NVL(d.shift_to, d.obs_day - 1))
                                  THEN 2 ELSE 3 END                                       AS day_sev
                      FROM  (SELECT a.*,
                                    ROW_NUMBER() OVER (PARTITION BY a.alert_kind, a.dbid, a.con_dbid, a.series,
                                                                    a.baseline_mode, a.obs_day
                                                       ORDER BY ABS(a.z) DESC NULLS LAST, a.ts) AS rn,
                                    COUNT(*)        OVER (PARTITION BY a.alert_kind, a.dbid, a.con_dbid, a.series,
                                                                   a.baseline_mode, a.obs_day)  AS n_events,
                                    MIN(a.sev_rank) OVER (PARTITION BY a.alert_kind, a.dbid, a.con_dbid, a.series,
                                                                   a.baseline_mode, a.obs_day)  AS day_rank,
                                    MAX(CASE WHEN a.anomaly_kind = 'CPU_SHIFT' THEN TRUNC(a.ts) END)
                                                    OVER (PARTITION BY a.dbid, a.con_dbid, a.kind, a.series) AS shift_from,
                                    MAX(CASE WHEN a.anomaly_kind = 'CPU_SHIFT' THEN a.obs_day END)
                                                    OVER (PARTITION BY a.dbid, a.con_dbid, a.kind, a.series) AS shift_to
                             FROM   capr_anomalies a
                             WHERE  a.alerting = 'Y') d
                      WHERE  d.rn = 1 AND d.anomaly_kind <> 'CPU_SHIFT') g
              ) e
        WHERE e.ep_rn = 1
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
         || TO_CHAR(a.day_dt, 'YYYY-MM-DD') || '|' || NVL(a.baseline_mode, '-') AS alert_key,
       a.kind || '|' || a.dbid || '|' || a.con_dbid || '|' || a.series_key || '|'
         || NVL(a.baseline_mode, '-')                                      AS state_key,
       a.direction,
       a.alarm_threshold,
       a.is_current,
       a.first_day,
       a.n_days,
       a.max_z
FROM   alerts a
LEFT   JOIN capr_container c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid;
