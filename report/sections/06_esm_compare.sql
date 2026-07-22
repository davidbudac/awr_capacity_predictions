--
-- 06_esm_compare.sql -- Tier 2 (ESM) vs Tier 1 (REGR) side by side.
-- Consumes CAPF_COMPARE. ESM columns are populated only where a model exists
-- and the horizon is within Oracle's ESM cap (~1/4 of series length); +180/365
-- are REGR-only by design. Reached only when show_esm != 'N'.
--
PROMPT
PROMPT == 6. TIER 2 (ESM) vs TIER 1 (REGR) ==
PROMPT    &esm_ok OML ESM model(s) trained (OK). If 0: run  EXEC cap_forecast_ml.train_all
PROMPT    ESM reaches +30 only (19c hard horizon cap) and only for fresh models;
PROMPT    +90/180/365 are REGR-only.
PROMPT
PROMPT  6a. Tablespaces (GB):

COLUMN con_dbid   FORMAT 99999999999 HEADING 'CON_DBID'
COLUMN series_key FORMAT A16          HEADING 'TABLESPACE'
COLUMN h          FORMAT 9990          HEADING 'HORIZON'
COLUMN regr       FORMAT 99990.00      HEADING 'REGR_GB'
COLUMN esm        FORMAT 99990.00      HEADING 'ESM_GB'
COLUMN esm_lo     FORMAT 99990.00      HEADING 'ESM_LO'
COLUMN esm_hi     FORMAT 99990.00      HEADING 'ESM_HI'

SELECT con_dbid, series_key, horizon_days AS h,
       MAX(CASE WHEN engine='REGR' THEN value END)       / 1073741824 AS regr,
       MAX(CASE WHEN engine='ESM'  THEN value END)       / 1073741824 AS esm,
       MAX(CASE WHEN engine='ESM'  THEN lower_bound END) / 1073741824 AS esm_lo,
       MAX(CASE WHEN engine='ESM'  THEN upper_bound END) / 1073741824 AS esm_hi
FROM   capf_compare
WHERE  series_kind = 'TBSPC'
GROUP  BY dbid, con_dbid, series_key, horizon_days
ORDER  BY con_dbid, series_key, horizon_days;

PROMPT
PROMPT  6b. CPU (busy% / DB CPU sec):

COLUMN series_key FORMAT A12          HEADING 'METRIC'
COLUMN regr       FORMAT 99999990.00  HEADING 'REGR'
COLUMN esm        FORMAT 99999990.00  HEADING 'ESM'
COLUMN esm_lo     FORMAT 99999990.00  HEADING 'ESM_LO'
COLUMN esm_hi     FORMAT 99999990.00  HEADING 'ESM_HI'

SELECT con_dbid, series_key, horizon_days AS h,
       MAX(CASE WHEN engine='REGR' THEN value END)       AS regr,
       MAX(CASE WHEN engine='ESM'  THEN value END)       AS esm,
       MAX(CASE WHEN engine='ESM'  THEN lower_bound END) AS esm_lo,
       MAX(CASE WHEN engine='ESM'  THEN upper_bound END) AS esm_hi
FROM   capf_compare
WHERE  series_kind = 'CPU'
GROUP  BY dbid, con_dbid, series_key, horizon_days
ORDER  BY con_dbid, series_key, horizon_days;
