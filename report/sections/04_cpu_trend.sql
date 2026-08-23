--
-- 04_cpu_trend.sql -- host busy% and DB CPU seconds trend + days-to-saturation.
-- Consumes CAPF_CPU_TREND.
--
PROMPT
PROMPT == 4. CPU TREND (host busy% and DB CPU sec/day) ==
PROMPT    DAYS_SAT = projected days until host busy% reaches &cpu_sat% (BUSY_PCT only).
PROMPT    WORST/BEST: days-to-saturation range from the 95% CI on the slope
PROMPT    (BEST empty = might never saturate).

COLUMN db_pdb     FORMAT A20          HEADING 'DB/PDB'
COLUMN metric     FORMAT A12          HEADING 'METRIC'
COLUMN n          FORMAT 9990          HEADING 'TRAIN_N'
COLUMN cur_val    FORMAT 99999990.00  HEADING 'CURRENT'
COLUMN slope_day  FORMAT 9999990.0000 HEADING 'SLOPE/DAY'
COLUMN r2         FORMAT 90.999         HEADING 'R2'
COLUMN days_sat   FORMAT 99999990      HEADING 'DAYS_SAT'
COLUMN sat_worst  FORMAT 99999990      HEADING 'WORST'
COLUMN sat_best   FORMAT 99999990      HEADING 'BEST'
COLUMN quality    FORMAT A20           HEADING 'QUALITY'

SELECT NVL(cn.db_pdb, TO_CHAR(t.con_dbid)) AS db_pdb,
       t.metric,
       t.train_n        AS n,
       t.cur_val,
       t.slope_per_day  AS slope_day,
       t.r2,
       t.days_to_sat    AS days_sat,
       t.days_to_sat_lo AS sat_worst,
       t.days_to_sat_hi AS sat_best,
       t.quality
FROM   capf_cpu_trend t
LEFT   JOIN capr_container cn
  ON   cn.dbid = t.dbid AND cn.con_dbid = t.con_dbid
ORDER  BY t.con_dbid, t.metric;
