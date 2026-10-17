--
-- 04_cpu_trend.sql -- host busy% and DB CPU seconds trend + days-to-saturation.
-- FORMAT ONLY (M8.2): CAPR_CPU_TREND (DB/PDB label already resolved).
--
PROMPT
PROMPT == 4. CPU TREND (host busy% avg / p95 / peak window, DB CPU sec and % of logical CPUs) ==
PROMPT    BUSY_PCT = daily average; BUSY_P95 / BUSY_PEAK = the busy hour (p95 of the
PROMPT    day's snapshot intervals / peak-window busy%) -- what actually saturates.
PROMPT    DB_CPU_PCT / DB_CPU_P95 = this container's DB CPU as % of the host's logical CPUs.
PROMPT    DAYS_SAT = projected days until the metric reaches &cpu_sat% (all but DB_CPU_SEC).
PROMPT    WORST/BEST: days-to-saturation range from the 95% CI on the slope
PROMPT    (BEST empty = might never saturate).
PROMPT    ANCHOR = median of the last shift_days complete days, where projections and
PROMPT    DAYS_SAT start. SIG = Y when the slope is outside its own 95% CI. HOT = Y when
PROMPT    the busy-hour metric (BUSY_P95 / DB_CPU_P95) is at or above &cpu_sat% now.
PROMPT    SEV = the severity CAPR_ALERTS raises for the metric (CPU_SAT / DBCPU_SAT on an OK
PROMPT    trend inside the warning window, CPU_HOT / DBCPU_HOT when HOT); GATE = why a
PROMPT    would-be CPU_SAT / DBCPU_SAT does not page (low-q, short = the trend is not OK).

COLUMN trend_cfg  FORMAT A110         HEADING 'TREND SETTINGS'
SELECT CASE WHEN cpu_deseason = 1
            THEN 'fit on weekday / weekend demeaned values (cpu_deseason = 1)'
            ELSE 'fit on raw daily values (cpu_deseason = 0)' END
       || '; OK = '
       || CASE WHEN cpu_quality_gate = 1
               THEN 'slope significant (cpu_quality_gate = 1)'
               ELSE 'R2 >= ' || TO_CHAR(r2_gate, 'FM0.00') || ' (cpu_quality_gate = 0)' END AS trend_cfg
FROM   cap_cfg;

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
COLUMN anchor     FORMAT 99999990.00  HEADING 'ANCHOR'
COLUMN sig        FORMAT A3            HEADING 'SIG'
COLUMN hot        FORMAT A3            HEADING 'HOT'
COLUMN sev        FORMAT A4            HEADING 'SEV'
COLUMN gate       FORMAT A8            HEADING 'GATE'

SELECT db_pdb,
       metric,
       train_n       AS n,
       cur_val,
       slope_per_day AS slope_day,
       r2,
       days_to_sat   AS days_sat,
       sat_worst,
       sat_best,
       quality,
       anchor_value  AS anchor,
       slope_sig     AS sig,
       hot_now       AS hot,
       sev,
       gate
FROM   capr_cpu_trend
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY con_dbid, metric;
