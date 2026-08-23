--
-- 05_cpu_anomalies.sql -- host busy% anomalies vs same-weekday baseline.
-- Consumes CAPA_CPU_ANOM. Threshold = k * max(MAD, cpu_min_mad_pct floor).
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

SELECT NVL(cn.db_pdb, TO_CHAR(a.con_dbid)) AS db_pdb,
       TO_CHAR(a.day_dt,'YYYY-MM-DD') AS day_dt,
       a.busy_pct,
       a.median_pct,
       a.threshold_pct,
       a.robust_z AS z,
       a.anomaly_flag
FROM   capa_cpu_anom a
LEFT   JOIN capr_container cn
  ON   cn.dbid = a.dbid AND cn.con_dbid = a.con_dbid
WHERE  a.anomaly_flag IS NOT NULL
  AND  a.day_dt > (SELECT MAX(day_dt) FROM capd_cpu_daily) - &anomaly_days
ORDER  BY a.day_dt DESC, a.con_dbid;
