--
-- ddl/55_report_views_ml.sql -- CAPR_* report views that need Tier 2 (M8.2).
-- =====================================================================
-- The rest of the CAPR_* report layer lives in ddl/45_report_views.sql. These
-- three views are split out ONLY because they read CAPF_COMPARE /
-- CAPF_BACKTEST, which ddl/50_ml.sql creates AFTER 45 -- so install.sql loads
-- this file last (see its [55] step). Same contract as the others: every
-- derived number, label and unit conversion is computed here so
-- report/report.sql and report/report_html.sql only format.
--
--   CAPR_TBSPC_FORECAST -- section 2 body: per-tablespace REGR projections in
--                          GiB with the +180 prediction band, R2, quality and
--                          the Tier 2 ESM +30 point (with its bounds). Also
--                          carries the raw bytes columns and rank_chart, so
--                          the HTML chart grid reads its geometry inputs from
--                          the same row the table prints.
--   CAPR_ESM_COMPARE    -- sections 6a/6b: one row per
--                          (container, series, horizon) with REGR vs ESM side
--                          by side, in raw units AND GiB (6a prints GiB,
--                          6b raw); filter on series_kind.
--   CAPR_BACKTEST       -- section 6c: the M9.4 holdout scorecard pivoted to
--                          one row per series, incl. the BETTER verdict.
--
-- Read-only, like everything else in the suite.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPR_TBSPC_FORECAST
-- The ESM +30 point comes from a single LEFT JOIN onto the ESM/TBSPC/+30
-- slice of CAPF_COMPARE (at most one row per series -- CAPF_COMPARE's ESM
-- branch is already unique on that key), rather than a scalar subquery per
-- column, so the pipelined ESM source is walked once.
-- rank_chart reproduces the HTML chart grid's own ordering
-- (days_to_full NULLS LAST, then name) so that driver can cap at top_n with
-- a plain WHERE.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_tbspc_forecast AS
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
       ROW_NUMBER() OVER (ORDER BY f.days_to_full NULLS LAST,
                                   f.tablespace_name)  AS rank_chart
FROM   capf_tbspc_forecast f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
LEFT   JOIN (SELECT dbid, con_dbid, series_key, value, lower_bound, upper_bound
             FROM   capf_compare
             WHERE  engine = 'ESM' AND series_kind = 'TBSPC' AND horizon_days = 30) e
  ON   e.dbid = f.dbid AND e.con_dbid = f.con_dbid
 AND   e.series_key = f.tablespace_name;

-- --------------------------------------------------------------------
-- CAPR_ESM_COMPARE -- sections 6a (series_kind='TBSPC', GiB columns) and
-- 6b (series_kind='CPU', raw columns). ESM columns are populated only where
-- a fresh model exists and the horizon is inside Oracle's ESM cap (+30 on
-- 19c); +90/180/365 are REGR-only by design.
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
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.upper_bound END) / 1073741824 AS esm_hi_gb
FROM   capf_compare f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
GROUP  BY f.dbid, f.con_dbid, f.series_kind, f.series_key, f.horizon_days;

-- --------------------------------------------------------------------
-- CAPR_BACKTEST -- section 6c. CAPF_BACKTEST is one row per (series, engine);
-- this pivots it to one row per series with REGR and ESM side by side plus
-- the BETTER verdict (NULL when either engine has no score, e.g. before
-- EXEC cap_forecast_ml.train_backtest). cutoff_day is pre-formatted -- MIN()
-- because the two engines record the same cutoff from different sources.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_backtest AS
SELECT f.dbid,
       f.con_dbid,
       NVL(MAX(cn.db_pdb), TO_CHAR(f.con_dbid))            AS db_pdb,
       f.series_kind,
       f.series_key,
       TO_CHAR(MIN(f.cutoff_day), 'YYYY-MM-DD')            AS cutoff_day,
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
       END                                                  AS better
FROM   capf_backtest f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
GROUP  BY f.dbid, f.con_dbid, f.series_kind, f.series_key;
