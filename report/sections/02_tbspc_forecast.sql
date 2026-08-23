--
-- 02_tbspc_forecast.sql -- per-tablespace REGR projections + ESM (when trained).
-- Consumes CAPF_TBSPC_FORECAST + CAPF_COMPARE (ESM point predictions).
--
PROMPT
PROMPT == 2. TABLESPACE FORECAST (GB): current / +30 / +90 / +180, plus ESM +30 ==
PROMPT    QUALITY: OK | LOW_CONFIDENCE (R2<gate) | FLAT (no growth) | INSUFFICIENT_HISTORY.
PROMPT    ESM (Tier 2) only reaches +30 on 19c (hard horizon cap); +90/180 are REGR.

COLUMN db_pdb          FORMAT A20         HEADING 'DB/PDB'
COLUMN tablespace_name FORMAT A16         HEADING 'TABLESPACE'
COLUMN n               FORMAT 9990         HEADING 'TRAIN_N'
COLUMN cur_gb          FORMAT 99990.00     HEADING 'CUR_GB'
COLUMN p30             FORMAT 99990.00     HEADING '+30_GB'
COLUMN p90             FORMAT 99990.00     HEADING '+90_GB'
COLUMN p180            FORMAT 99990.00     HEADING '+180_GB'
COLUMN r2              FORMAT 90.999        HEADING 'R2'
COLUMN quality         FORMAT A20          HEADING 'QUALITY'
COLUMN esm30           FORMAT 99990.00     HEADING 'ESM+30'

SELECT NVL(cn.db_pdb, TO_CHAR(f.con_dbid)) AS db_pdb,
       f.tablespace_name,
       f.train_n                          AS n,
       f.cur_used       / 1073741824 AS cur_gb,
       f.proj_30_bytes  / 1073741824 AS p30,
       f.proj_90_bytes  / 1073741824 AS p90,
       f.proj_180_bytes / 1073741824 AS p180,
       f.r2,
       f.quality,
       (SELECT c.value / 1073741824 FROM capf_compare c
         WHERE c.engine='ESM' AND c.series_kind='TBSPC'
           AND c.dbid=f.dbid AND c.con_dbid=f.con_dbid AND c.series_key=f.tablespace_name
           AND c.horizon_days=30)          AS esm30
FROM   capf_tbspc_forecast f
LEFT   JOIN capr_container cn
  ON   cn.dbid = f.dbid AND cn.con_dbid = f.con_dbid
ORDER  BY f.con_dbid, f.tablespace_name;
