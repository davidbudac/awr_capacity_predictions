--
-- 05_cpu_anomalies.sql -- host busy% anomalies vs same-weekday baseline (5a)
-- and sustained level shifts (5b, M10.3).
-- FORMAT ONLY (M8.2): CAPR_CPU_ANOMALIES (flagged rows, DB/PDB label and
-- days_ago precomputed) and CAPR_CPU_SHIFTS (flagged rows, rank_shift
-- precomputed). Threshold = k * max(MAD, cpu_min_mad_pct floor) for 5a,
-- shift_min_pct points for 5b.
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

PROMPT
PROMPT == 5b. CPU LEVEL SHIFTS (sustained step, not a one-day outlier) ==
PROMPT    Recent-window median vs the baseline median before it. Flagged only when
PROMPT    the gap exceeds THRESH points AND every day of the recent window sits
PROMPT    above (UP) or below (DOWN) the baseline median +/- its MAD sigma.

COLUMN db_pdb      FORMAT A20      HEADING 'DB/PDB'
COLUMN metric      FORMAT A11      HEADING 'METRIC'
COLUMN win         FORMAT A9       HEADING 'WINDOWS'
COLUMN recent_med  FORMAT 9990.0   HEADING 'RECENT%'
COLUMN base_med    FORMAT 9990.0   HEADING 'BASE%'
COLUMN shift_pct   FORMAT S9990.0  HEADING 'SHIFT_PTS'
COLUMN thr_pts     FORMAT 9990.0   HEADING 'THRESH'
COLUMN conf        FORMAT A7       HEADING 'N_OF_M'
COLUMN shift_flag  FORMAT A5       HEADING 'FLAG'

SELECT db_pdb,
       metric,
       TO_CHAR(recent_days, 'FM990') || 'v' || TO_CHAR(base_days, 'FM990') AS win,
       recent_med,
       base_med,
       shift_pct,
       threshold_pct AS thr_pts,
       TO_CHAR(GREATEST(n_above, n_below), 'FM990') || '/'
         || TO_CHAR(n_recent, 'FM990')                                     AS conf,
       shift_flag
FROM   capr_cpu_shifts
ORDER  BY rank_shift;
