--
-- 05_cpu_anomalies.sql -- host busy% anomalies vs same-weekday baseline.
-- Consumes CAPA_CPU_ANOM. Threshold = k * max(MAD, cpu_min_mad_pct floor).
--
PROMPT
PROMPT == 5. CPU BUSY% ANOMALIES vs same-weekday baseline (last &anomaly_days days) ==
PROMPT    FLAG when |busy% - median%| exceeds THRESHOLD (k*MAD, floored).

COLUMN con_dbid     FORMAT 99999999999 HEADING 'CON_DBID'
COLUMN day_dt       FORMAT A10          HEADING 'DAY'
COLUMN busy_pct     FORMAT 9990.00      HEADING 'BUSY%'
COLUMN median_pct   FORMAT 9990.00      HEADING 'MEDIAN%'
COLUMN threshold_pct FORMAT 9990.00     HEADING 'THRESH%'
COLUMN z            FORMAT 99990.0      HEADING 'ROBUST_Z'
COLUMN anomaly_flag FORMAT A5           HEADING 'FLAG'

SELECT con_dbid,
       TO_CHAR(day_dt,'YYYY-MM-DD') AS day_dt,
       busy_pct,
       median_pct,
       threshold_pct,
       robust_z AS z,
       anomaly_flag
FROM   capa_cpu_anom
WHERE  anomaly_flag IS NOT NULL
  AND  day_dt > (SELECT MAX(day_dt) FROM capd_cpu_daily) - &anomaly_days
ORDER  BY day_dt DESC, con_dbid;
