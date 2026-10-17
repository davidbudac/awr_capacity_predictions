--
-- ddl/55_report_views_ml.sql -- CAPR_* report views that need Tier 2 (M8.2).
-- =====================================================================
-- The rest of the CAPR_* report layer lives in ddl/45_report_views.sql. These
-- views are split out ONLY because they read CAPF_COMPARE /
-- CAPF_BACKTEST, which ddl/50_ml.sql creates AFTER 45 -- so install.sql loads
-- this file last (see its [55] step). Same contract as the others: every
-- derived number, label and unit conversion is computed here so
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
--   CAPR_BACKTEST       -- section 6c: the M9.4 holdout scorecard pivoted to
--                          one row per series, incl. the BETTER verdict and
--                          (M10.4) the ESM model-type pick + its rationale.
--   CAPR_FORECAST_POINTS -- REGR anchors + the ESM point as chartable
--                          rows, for grafana/API.md and elk/.
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
CREATE OR REPLACE VIEW capr_tbspc_forecast AS
WITH f AS (
        -- M7.4 reportability, decided once here so section 2 (this view) and
        -- section 6a (CAPR_ESM_COMPARE, which joins this one) bound the same
        -- set of tablespaces. A row is worth printing when it is GROWING, or
        -- already NEAR-FULL, or simply BIG (>= report_min_gb GiB) -- which
        -- leaves out exactly the small, flat, half-empty tablespaces that turn
        -- a 500-tablespace database into 500 lines of noise. cur_used IS NULL
        -- reports as 'Y': the bound must never hide a row we cannot judge.
        SELECT t.*,
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
       -- rank_report: reportable rows first, then growing ones, then the
       -- biggest -- so  WHERE is_reportable='Y' AND rank_report <= top_n
       -- keeps the top_n rows that matter and a non-reportable row can never
       -- consume a slot ahead of a reportable one.
       ROW_NUMBER() OVER (ORDER BY CASE WHEN f.is_reportable = 'Y' THEN 0 ELSE 1 END,
                                   CASE WHEN NVL(f.slope_bpd, 0) > 0 THEN 0 ELSE 1 END,
                                   f.cur_used DESC NULLS LAST,
                                   f.con_dbid, f.tablespace_name)  AS rank_report,
       ROW_NUMBER() OVER (ORDER BY f.days_to_full NULLS LAST,
                                   f.tablespace_name)  AS rank_chart,
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
       -- M7.4: section 6a applies the SAME bound as section 2, INHERITED from
       -- CAPR_TBSPC_FORECAST rather than recomputed, so the two sections can
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
LEFT   JOIN capr_tbspc_forecast tf
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
-- horizon 0 (the actual current value) and +30/+90 (+180/+365 for TBSPC)
-- with their M9.1 bands, plus the ESM point. The CAPF_ projections are
-- anchored on that current value, so horizon 0 and the REGR horizons sit on
-- one straight line. ts = last observed day +
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
               CASE WHEN t.metric <> 'DB_CPU_SEC' THEN 100 END,
               CASE WHEN t.metric <> 'DB_CPU_SEC' THEN h.val END, t.quality
        FROM   capf_cpu_trend t
        CROSS  APPLY (SELECT 0 AS h, t.cur_val AS val, CAST(NULL AS NUMBER) AS lo, CAST(NULL AS NUMBER) AS hi FROM dual UNION ALL
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
               SELECT dbid, con_dbid, 'CPU', metric, last_day,
                      CASE WHEN metric <> 'DB_CPU_SEC' THEN 100 END, quality
               FROM   capf_cpu_trend) f
          ON   f.dbid = t.dbid AND f.con_dbid = t.con_dbid
         AND   f.series_kind = t.series_kind AND f.series_key = t.series_key
        WHERE  t.engine = 'ESM'
          AND  t.value IS NOT NULL
      ) p
LEFT   JOIN capr_container c
  ON   c.dbid = p.dbid AND c.con_dbid = p.con_dbid;
