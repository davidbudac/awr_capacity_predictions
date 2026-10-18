--
-- 07_series.sql -- fixed-ceiling series: processes/sessions, redo, DB size (M11),
-- ASM diskgroups, TEMP / UNDO peaks.
-- FORMAT ONLY (M8.2 convention): every number, label and severity marker comes
-- from CAPR_SERIES (7) and CAPR_SERIES_ANOMALIES (7b), the views the HTML
-- report reads.
--
-- Unlike a tablespace, these series each have (or lack) a single hard ceiling
-- that is not a tablespace's own: the `processes` / `sessions` init parameters,
-- the summed tablespace ceilings, a diskgroup's size, a TEMP / UNDO
-- tablespace's size, or -- for redo -- no ceiling at all. They are
-- listed together because the arithmetic is identical: fit a line, ask when it
-- reaches SAT% of the limit.
--
PROMPT
PROMPT == 7. FIXED-CEILING SERIES (processes / sessions / redo / DB size / ASM / TEMP / UNDO) ==
PROMPT     PROCESSES, SESSIONS  peak concurrency (AWR max_utilization, a
PROMPT                          high-water mark since instance startup) against
PROMPT                          the init parameter. RAC: summed over instances,
PROMPT                          and INST_PCT is the worst instance's percent of
PROMPT                          its own limit (SERIES_NEARLIMIT judges the larger).
PROMPT     REDO_GB_DAY          redo written per day, GiB. No ceiling -- it is a
PROMPT                          trend for FRA / archive-destination sizing.
PROMPT                          FRA_DAYS = days of redo db_recovery_file_dest_size
PROMPT                          holds at the current rate (an upper bound).
PROMPT     DB_SIZE_GB           total permanent-tablespace bytes used, vs the sum
PROMPT                          of the same tablespaces' ceilings.
PROMPT     ASM_DG:+<group>      ASM diskgroup GiB used (raw, before mirroring) vs
PROMPT                          its total, at the day's last snapshot.
PROMPT     TEMP_PEAK:<ts>       the day's highest sampled GiB used of a TEMP or
PROMPT     UNDO_PEAK:<ts>       UNDO tablespace vs its maxsize (else size).
PROMPT     DAYS_LIM = projected days until the series reaches SAT (the
PROMPT     series_sat_pct% of LIMIT shown), empty when there is no ceiling or no
PROMPT     growth. WORST/BEST bound it with the 95% CI on the slope
PROMPT     (BEST empty = might never get there). Trust it per QUALITY.

COLUMN db_pdb       FORMAT A20           HEADING 'DB/PDB'
COLUMN series       FORMAT A20           HEADING 'SERIES'
COLUMN unit         FORMAT A11           HEADING 'UNIT'
COLUMN n            FORMAT 9990          HEADING 'TRAIN_N'
COLUMN cur_val      FORMAT 99999990.00   HEADING 'CURRENT'
COLUMN cur_limit    FORMAT 99999990.00   HEADING 'LIMIT'
COLUMN sat_value    FORMAT 99999990.00   HEADING 'SAT'
COLUMN pct_of_limit FORMAT 990.0         HEADING 'PCT_LIM'
COLUMN worst_inst_pct FORMAT 990.0       HEADING 'INST_PCT'
COLUMN slope_day    FORMAT 9999990.0000  HEADING 'SLOPE/DAY'
COLUMN r2           FORMAT 90.999        HEADING 'R2'
COLUMN days_lim     FORMAT 99999990      HEADING 'DAYS_LIM'
COLUMN limit_worst  FORMAT 99999990      HEADING 'WORST'
COLUMN limit_best   FORMAT 99999990      HEADING 'BEST'
COLUMN sev          FORMAT A4            HEADING 'SEV'
COLUMN quality      FORMAT A20           HEADING 'QUALITY'
COLUMN fra_days     FORMAT 9999990.0     HEADING 'FRA_DAYS'

SELECT db_pdb,
       series,
       unit,
       train_n       AS n,
       cur_val,
       cur_limit,
       sat_value,
       pct_of_limit,
       worst_inst_pct,
       slope_per_day AS slope_day,
       r2,
       days_to_limit AS days_lim,
       limit_worst,
       limit_best,
       sev,
       quality,
       fra_days_at_cur AS fra_days
FROM   capr_series
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY rank_series;

PROMPT
PROMPT == 7b. SERIES ANOMALIES (last &anomaly_days days) ==
PROMPT    PROCESSES / SESSIONS / REDO_GB_DAY are scored on their daily level, DB_SIZE_GB on its
PROMPT    daily growth (GiB/day). MODE TRL = the trailing &mad_w days, DOW = the same weekday
PROMPT    over the last &dow_w weeks. FLAG when |value - median| exceeds THRESHOLD (k*MAD,
PROMPT    floored); N_HIST = baseline days behind the median. One row per flagging mode.

COLUMN db_pdb       FORMAT A20           HEADING 'DB/PDB'
COLUMN series       FORMAT A12           HEADING 'SERIES'
COLUMN unit         FORMAT A11           HEADING 'UNIT'
COLUMN day_dt       FORMAT A10           HEADING 'DAY'
COLUMN mode_short   FORMAT A4            HEADING 'MODE'
COLUMN value        FORMAT 99999990.00   HEADING 'VALUE'
COLUMN expected     FORMAT 99999990.00   HEADING 'MEDIAN'
COLUMN threshold    FORMAT 99999990.00   HEADING 'THRESHOLD'
COLUMN z            FORMAT 99990.0       HEADING 'ROBUST_Z'
COLUMN n_hist       FORMAT 9990          HEADING 'N_HIST'
COLUMN pct_vs_med   FORMAT S9999990      HEADING 'VS_MED%'
COLUMN anomaly_flag FORMAT A5            HEADING 'FLAG'

SELECT db_pdb,
       series,
       unit,
       day_str AS day_dt,
       mode_short,
       value,
       expected,
       threshold,
       z,
       n_hist,
       pct_vs_med,
       anomaly_flag
FROM   capr_series_anomalies
WHERE  days_ago < &anomaly_days
  AND  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY days_ago, con_dbid, series, mode_rank;
