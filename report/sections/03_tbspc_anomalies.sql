--
-- 03_tbspc_anomalies.sql -- tablespace growth anomalies, last &anomaly_days days.
-- FORMAT ONLY (M8.2): CAPR_TBSPC_ANOMALIES holds every flagged row with the
-- MiB conversions and the DB/PDB label already applied; days_ago (measured
-- from the last collected day) turns the report window into a plain WHERE.
-- Every row stays hand-auditable: delta vs median vs the k*MAD (floored)
-- threshold, plus the robust z.
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

SELECT db_pdb,
       tablespace_name,
       day_str AS day_dt,
       gap,
       delta_mb,
       rate_mb,
       med_mb,
       thr_mb,
       z,
       anomaly_flag
FROM   capr_tbspc_anomalies
WHERE  days_ago < &anomaly_days
-- days_ago ASC is exactly day_dt DESC (days_ago = last collected day - day_dt)
ORDER  BY days_ago, con_dbid, tablespace_name;
