--
-- 04_cpu_trend.sql -- host busy% and DB CPU seconds trend + days-to-saturation.
-- Consumes CAPF_CPU_TREND.
--
PROMPT
PROMPT == 4. CPU TREND (host busy% and DB CPU sec/day) ==
PROMPT    DAYS_SAT = projected days until host busy% reaches &cpu_sat% (BUSY_PCT only).

COLUMN con_dbid   FORMAT 99999999999 HEADING 'CON_DBID'
COLUMN metric     FORMAT A12          HEADING 'METRIC'
COLUMN n          FORMAT 9990          HEADING 'TRAIN_N'
COLUMN cur_val    FORMAT 99999990.00  HEADING 'CURRENT'
COLUMN slope_day  FORMAT 9999990.0000 HEADING 'SLOPE/DAY'
COLUMN r2         FORMAT 90.999         HEADING 'R2'
COLUMN days_sat   FORMAT 99999990      HEADING 'DAYS_SAT'
COLUMN quality    FORMAT A20           HEADING 'QUALITY'

SELECT con_dbid,
       metric,
       train_n        AS n,
       cur_val,
       slope_per_day  AS slope_day,
       r2,
       days_to_sat    AS days_sat,
       quality
FROM   capf_cpu_trend
ORDER  BY con_dbid, metric;
