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
--
-- M7.4: both carry is_reportable ('Y'/'N') + rank_report, so both report
-- drivers bound sections 2 and 6a with the identical
--   WHERE is_reportable = 'Y' AND rank_report <= &top_n
-- while the views themselves still expose every row to other consumers.
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
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'report_min_gb'     THEN cfg_value END) AS report_min_gb,
               MAX(CASE WHEN cfg_name = 'nearfull_warn_pct' THEN cfg_value END) AS nf_warn
        FROM   cap_config
     ),
     f AS (
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
                    WHEN NVL(t.pct_used, 0) >= cfg.nf_warn            THEN 'Y'
                    ELSE 'N'
               END                                                    AS is_reportable
        FROM   capf_tbspc_forecast t CROSS JOIN cfg
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
                                   f.tablespace_name)  AS rank_chart
FROM   f
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
       MAX(CASE WHEN f.engine = 'ESM'  THEN f.upper_bound END) / 1073741824 AS esm_hi_gb,
       -- M7.4: section 6a applies the SAME bound as section 2, INHERITED from
       -- CAPR_TBSPC_FORECAST rather than recomputed, so the two sections can
       -- never disagree about which tablespaces are worth printing. CPU rows
       -- (6b) are always reportable with rank_report 0, so the identical
       -- WHERE is_reportable='Y' AND rank_report <= top_n never drops them.
       CASE WHEN f.series_kind = 'TBSPC'
            THEN NVL(MAX(tf.is_reportable), 'Y') ELSE 'Y' END  AS is_reportable,
       CASE WHEN f.series_kind = 'TBSPC'
            THEN NVL(MAX(tf.rank_report), 0)     ELSE 0   END  AS rank_report
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
