--
-- 05_cpu_anomalies.sql -- host busy% anomalies vs same-weekday baseline.
-- FORMAT ONLY (M8.2): CAPR_CPU_ANOMALIES (flagged rows, DB/PDB label and
-- days_ago precomputed). Threshold = k * max(MAD, cpu_min_mad_pct floor).
--
PROMPT
PROMPT == 5. CPU BUSY% ANOMALIES vs same-weekday baseline (last &anomaly_days days) ==
PROMPT    FLAG when |busy% - median%| exceeds THRESHOLD (k*MAD, floored).

COLUMN db_pdb       FORMAT A20          HEADING 'DB/PDB'
COLUMN day_dt       FORMAT A10          HEADING 'DAY'
COLUMN busy_pct     FORMAT 9990.00      HEADING 'BUSY%'
COLUMN median_pct   FORMAT 9990.00      HEADING 'MEDIAN%'
COLUMN threshold_pct FORMAT 9990.00     HEADING 'THRESH%'
COLUMN z            FORMAT 99990.0      HEADING 'ROBUST_Z'
COLUMN anomaly_flag FORMAT A5           HEADING 'FLAG'

SELECT db_pdb,
       day_str AS day_dt,
       busy_pct,
       median_pct,
       threshold_pct,
       z,
       anomaly_flag
FROM   capr_cpu_anomalies
WHERE  days_ago < &anomaly_days
-- days_ago ASC is exactly day_dt DESC (days_ago = last collected day - day_dt)
ORDER  BY days_ago, con_dbid;
