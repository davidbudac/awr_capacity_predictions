--
-- 03_tbspc_anomalies.sql -- tablespace growth anomalies, last &anomaly_days days.
-- Consumes CAPA_TBSPC_ANOM. Every row is hand-auditable: delta vs median vs
-- the k*MAD (floored) threshold, plus the robust z.
--
PROMPT
PROMPT == 3. TABLESPACE GROWTH ANOMALIES (last &anomaly_days days) ==
PROMPT    Anomaly on the per-day growth RATE (delta/gap): FLAG when
PROMPT    |rate - median_rate| exceeds THRESHOLD = max(k*MAD, 100MiB/day floor).
PROMPT    GAP = days since previous sample (>1 across an AWR gap).

COLUMN db_pdb          FORMAT A20         HEADING 'DB/PDB'
COLUMN tablespace_name FORMAT A16         HEADING 'TABLESPACE'
COLUMN day_dt          FORMAT A10          HEADING 'DAY'
COLUMN gap             FORMAT 990          HEADING 'GAP'
COLUMN delta_mb        FORMAT 9999990.0    HEADING 'DELTA_MB'
COLUMN rate_mb         FORMAT 9999990.0    HEADING 'RATE_MB/D'
COLUMN med_mb          FORMAT 9999990.0    HEADING 'MED_MB/D'
COLUMN thr_mb          FORMAT 9999990.0    HEADING 'THR_MB/D'
COLUMN z               FORMAT 99990.0      HEADING 'ROBUST_Z'
COLUMN anomaly_flag    FORMAT A5           HEADING 'FLAG'

SELECT NVL(cn.db_pdb, TO_CHAR(a.con_dbid)) AS db_pdb,
       a.tablespace_name,
       TO_CHAR(a.day_dt,'YYYY-MM-DD')   AS day_dt,
       a.day_gap                    AS gap,
       a.used_delta_bytes / 1048576 AS delta_mb,
       a.used_rate_bpd    / 1048576 AS rate_mb,
       a.median_rate_bpd  / 1048576 AS med_mb,
       a.threshold_bpd    / 1048576 AS thr_mb,
       a.robust_z                   AS z,
       a.anomaly_flag
FROM   capa_tbspc_anom a
LEFT   JOIN capr_container cn
  ON   cn.dbid = a.dbid AND cn.con_dbid = a.con_dbid
WHERE  a.anomaly_flag IS NOT NULL
  AND  a.day_dt > (SELECT MAX(day_dt) FROM capd_tbspc_daily) - &anomaly_days
ORDER  BY a.day_dt DESC, a.con_dbid, a.tablespace_name;
