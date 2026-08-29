--
-- 04_cpu_trend.sql -- host busy% and DB CPU seconds trend + days-to-saturation.
-- FORMAT ONLY (M8.2): CAPR_CPU_TREND (DB/PDB label already resolved).
--
PROMPT
PROMPT == 4. CPU TREND (host busy% avg / p95 / peak window, DB CPU sec and % of cores) ==
PROMPT    BUSY_PCT = daily average; BUSY_P95 / BUSY_PEAK = the busy hour (p95 of the
PROMPT    day's snapshot intervals / peak-window busy%) -- what actually saturates.
PROMPT    DB_CPU_PCT / DB_CPU_P95 = this container's DB CPU as % of host core capacity.
PROMPT    DAYS_SAT = projected days until the metric reaches &cpu_sat% (all but DB_CPU_SEC).
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

SELECT db_pdb,
       metric,
       train_n       AS n,
       cur_val,
       slope_per_day AS slope_day,
       r2,
       days_to_sat   AS days_sat,
       sat_worst,
       sat_best,
       quality
FROM   capr_cpu_trend
ORDER  BY con_dbid, metric;
