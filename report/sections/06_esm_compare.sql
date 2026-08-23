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

COLUMN db_pdb     FORMAT A20          HEADING 'DB/PDB'
COLUMN series_key FORMAT A16          HEADING 'TABLESPACE'
COLUMN h          FORMAT 9990          HEADING 'HORIZON'
COLUMN regr       FORMAT 99990.00      HEADING 'REGR_GB'
COLUMN esm        FORMAT 99990.00      HEADING 'ESM_GB'
COLUMN esm_lo     FORMAT 99990.00      HEADING 'ESM_LO'
COLUMN esm_hi     FORMAT 99990.00      HEADING 'ESM_HI'

SELECT NVL(MAX(cn.db_pdb), TO_CHAR(f.con_dbid)) AS db_pdb,
       f.series_key, f.horizon_days AS h,
       MAX(CASE WHEN f.engine='REGR' THEN f.value END)       / 1073741824 AS regr,
       MAX(CASE WHEN f.engine='ESM'  THEN f.value END)       / 1073741824 AS esm,
       MAX(CASE WHEN f.engine='ESM'  THEN f.lower_bound END) / 1073741824 AS esm_lo,
       MAX(CASE WHEN f.engine='ESM'  THEN f.upper_bound END) / 1073741824 AS esm_hi
FROM   capf_compare f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
WHERE  f.series_kind = 'TBSPC'
GROUP  BY f.dbid, f.con_dbid, f.series_key, f.horizon_days
ORDER  BY f.con_dbid, f.series_key, f.horizon_days;

PROMPT
PROMPT  6b. CPU (busy% / DB CPU sec):

COLUMN series_key FORMAT A12          HEADING 'METRIC'
COLUMN regr       FORMAT 99999990.00  HEADING 'REGR'
COLUMN esm        FORMAT 99999990.00  HEADING 'ESM'
COLUMN esm_lo     FORMAT 99999990.00  HEADING 'ESM_LO'
COLUMN esm_hi     FORMAT 99999990.00  HEADING 'ESM_HI'

SELECT NVL(MAX(cn.db_pdb), TO_CHAR(f.con_dbid)) AS db_pdb,
       f.series_key, f.horizon_days AS h,
       MAX(CASE WHEN f.engine='REGR' THEN f.value END)       AS regr,
       MAX(CASE WHEN f.engine='ESM'  THEN f.value END)       AS esm,
       MAX(CASE WHEN f.engine='ESM'  THEN f.lower_bound END) AS esm_lo,
       MAX(CASE WHEN f.engine='ESM'  THEN f.upper_bound END) AS esm_hi
FROM   capf_compare f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
WHERE  f.series_kind = 'CPU'
GROUP  BY f.dbid, f.con_dbid, f.series_key, f.horizon_days
ORDER  BY f.con_dbid, f.series_key, f.horizon_days;
