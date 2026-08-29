--
-- 06_esm_compare.sql -- Tier 2 (ESM) vs Tier 1 (REGR) side by side.
-- FORMAT ONLY (M8.2): 6a/6b read CAPR_ESM_COMPARE (pivoted REGR-vs-ESM, in
-- GiB and raw units) and 6c reads CAPR_BACKTEST (pivoted holdout scorecard
-- with the BETTER verdict) -- both in ddl/55_report_views_ml.sql, both shared
-- with report_html.sql. ESM columns are populated only where a model exists
-- and the horizon is within Oracle's ESM cap (+30 on 19c); +180/365 are
-- REGR-only by design. Reached only when show_esm != 'N'.
--
-- M7.4: 6a applies the same is_reportable / rank_report bound as section 2 --
-- inherited by CAPR_ESM_COMPARE from CAPR_TBSPC_FORECAST, so the two sections
-- always show the same tablespaces (4 horizons each, hence 4x the rows). 6b's
-- CPU rows carry is_reportable='Y', rank_report=0 and are never bounded.
--
PROMPT
PROMPT == 6. TIER 2 (ESM) vs TIER 1 (REGR) ==
PROMPT    &esm_ok OML ESM model(s) trained (OK). If 0: run  EXEC cap_forecast_ml.train_all
PROMPT    ESM reaches +30 only (19c hard horizon cap) and only for fresh models;
PROMPT    +90/180/365 are REGR-only.
PROMPT
PROMPT  6a. Tablespaces (GiB) -- the same &ts_shown of &ts_total tablespace(s) as
PROMPT      section 2 (growing, near-full, or >= &min_gb GiB used, top &top_n):

COLUMN db_pdb     FORMAT A20          HEADING 'DB/PDB'
COLUMN series_key FORMAT A16          HEADING 'TABLESPACE'
COLUMN h          FORMAT 9990          HEADING 'HORIZON'
COLUMN regr       FORMAT 99990.00      HEADING 'REGR_GIB'
COLUMN esm        FORMAT 99990.00      HEADING 'ESM_GIB'
COLUMN esm_lo     FORMAT 99990.00      HEADING 'ESM_LO'
COLUMN esm_hi     FORMAT 99990.00      HEADING 'ESM_HI'

SELECT db_pdb,
       series_key,
       horizon_days AS h,
       regr_gb   AS regr,
       esm_gb    AS esm,
       esm_lo_gb AS esm_lo,
       esm_hi_gb AS esm_hi
FROM   capr_esm_compare
WHERE  series_kind = 'TBSPC'
  AND  is_reportable = 'Y'
  AND  rank_report <= &top_n
ORDER  BY rank_report, horizon_days;

PROMPT
PROMPT  6b. CPU (busy% / DB CPU sec):

COLUMN series_key FORMAT A12          HEADING 'METRIC'
COLUMN regr       FORMAT 99999990.00  HEADING 'REGR'
COLUMN esm        FORMAT 99999990.00  HEADING 'ESM'
COLUMN esm_lo     FORMAT 99999990.00  HEADING 'ESM_LO'
COLUMN esm_hi     FORMAT 99999990.00  HEADING 'ESM_HI'

SELECT db_pdb,
       series_key,
       horizon_days AS h,
       regr,
       esm,
       esm_lo,
       esm_hi
FROM   capr_esm_compare
WHERE  series_kind = 'CPU'
ORDER  BY con_dbid, series_key, horizon_days;

PROMPT
PROMPT  6c. Backtest -- which engine was right over the held-out window (M9.4):
PROMPT      Each engine forecast the last holdout window from data BEFORE it;
PROMPT      MAPE% = mean abs error vs actuals, BIAS% >0 = over-forecast. ESM
PROMPT      columns fill after  EXEC cap_forecast_ml.train_backtest  (ESM may
PROMPT      cover fewer days than REGR: 19c 30-step cap and rows/4 floor).

COLUMN series_kind FORMAT A6           HEADING 'KIND'
COLUMN series_key  FORMAT A16          HEADING 'SERIES'
COLUMN cutoff_day  FORMAT A10          HEADING 'CUTOFF'
COLUMN regr_mape   FORMAT 99990.00     HEADING 'REGR_MAPE%'
COLUMN regr_bias   FORMAT S99990.00    HEADING 'REGR_BIAS%'
COLUMN esm_mape    FORMAT 99990.00     HEADING 'ESM_MAPE%'
COLUMN esm_bias    FORMAT S99990.00    HEADING 'ESM_BIAS%'
COLUMN better      FORMAT A6           HEADING 'BETTER'

SELECT db_pdb,
       series_kind,
       series_key,
       cutoff_day,
       regr_mape,
       regr_bias,
       esm_mape,
       esm_bias,
       better
FROM   capr_backtest
ORDER  BY con_dbid, series_kind, series_key;
