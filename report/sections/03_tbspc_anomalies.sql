--
-- 03_tbspc_anomalies.sql -- tablespace growth anomalies, last &anomaly_days days.
-- FORMAT ONLY (M8.2): CAPR_TBSPC_ANOMALIES holds every flagged row with the
-- MiB conversions and the DB/PDB label already applied; days_ago (measured
-- from the last collected day) turns the report window into a plain WHERE.
-- Every row stays hand-auditable: delta vs median vs the k*MAD (floored)
-- threshold, plus the robust z. One row per (day, baseline mode) that flagged.
--
PROMPT
PROMPT == 3. TABLESPACE GROWTH ANOMALIES (last &anomaly_days days) ==
PROMPT    Anomaly on the per-day growth RATE (delta/gap), judged against two baselines (MODE):
PROMPT    TRL = the trailing &mad_w days, DOW = the same weekday over the last &dow_w weeks.
PROMPT    FLAG when |rate - median_rate| exceeds THRESHOLD = max(k*MAD, abs_floor_bytes).
PROMPT    N_HIST = baseline days behind the median. One row per flagging mode.
PROMPT    GAP = days since previous sample (>1 across an AWR gap).
PROMPT    VS_MED% / VS_AVG% = growth rate vs the baseline median / the train_days average, as a percentage (+25 = 25% more)

COLUMN db_pdb          FORMAT A20         HEADING 'DB/PDB'
COLUMN tablespace_name FORMAT A16         HEADING 'TABLESPACE'
COLUMN day_dt          FORMAT A10          HEADING 'DAY'
COLUMN mode_short      FORMAT A4           HEADING 'MODE'
COLUMN gap             FORMAT 990          HEADING 'GAP'
COLUMN delta_mb        FORMAT 9999990.0    HEADING 'DELTA_MIB'
COLUMN rate_mb         FORMAT 9999990.0    HEADING 'RATE_MIB/D'
COLUMN med_mb          FORMAT 9999990.0    HEADING 'MED_MIB/D'
COLUMN thr_mb          FORMAT 9999990.0    HEADING 'THR_MIB/D'
COLUMN z               FORMAT 99990.0      HEADING 'ROBUST_Z'
COLUMN n_hist          FORMAT 9990         HEADING 'N_HIST'
COLUMN pct_vs_med      FORMAT S9999990     HEADING 'VS_MED%'
COLUMN pct_vs_avg      FORMAT S9999990     HEADING 'VS_AVG%'
COLUMN anomaly_flag    FORMAT A5           HEADING 'FLAG'

SELECT db_pdb,
       tablespace_name,
       day_str AS day_dt,
       mode_short,
       gap,
       delta_mb,
       rate_mb,
       med_mb,
       thr_mb,
       z,
       n_hist,
       pct_vs_med,
       pct_vs_avg,
       anomaly_flag
FROM   capr_tbspc_anomalies
WHERE  days_ago < &anomaly_days
-- days_ago ASC is exactly day_dt DESC (days_ago = last collected day - day_dt)
ORDER  BY days_ago, con_dbid, tablespace_name, mode_rank;
