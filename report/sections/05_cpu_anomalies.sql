--
-- 05_cpu_anomalies.sql -- CPU anomalies vs trailing / same-weekday /
-- hour-of-week baselines (5a) and sustained level shifts (5b, M10.3).
-- FORMAT ONLY (M8.2): CAPR_CPU_ANOMALIES (flagged rows, DB/PDB label,
-- days_ago and the ts_str label precomputed) and CAPR_CPU_SHIFTS (flagged
-- rows, rank_shift precomputed). Threshold = k * max(MAD, sigma floor) for
-- 5a, shift_min_pct points for 5b.
--
PROMPT
PROMPT == 5. CPU ANOMALIES vs trailing / same-weekday / hour-of-week baselines (last &anomaly_days days) ==
PROMPT    METRIC BUSY_PCT = host busy%, DB_CPU_PCT = a container's DB CPU as % of host cores.
PROMPT    MODE TRL = the trailing &mad_w days, DOW = the same weekday over the last &dow_w weeks
PROMPT    (both per day), HOW = the same weekday and hour over those weeks (per hour, WHEN
PROMPT    shows the END hour). FLAG when |value% - median%| exceeds THRESHOLD (k*MAD, floored).
PROMPT    N_HIST = baseline points behind the median. VS_MED% = value vs that median, as a percentage (+25 = 25% more)

COLUMN db_pdb       FORMAT A20          HEADING 'DB/PDB'
COLUMN metric       FORMAT A10          HEADING 'METRIC'
COLUMN mode_short   FORMAT A4           HEADING 'MODE'
COLUMN ts_str       FORMAT A20          HEADING 'WHEN'
COLUMN value_pct    FORMAT 9990.00      HEADING 'VALUE%'
COLUMN median_pct   FORMAT 9990.00      HEADING 'MEDIAN%'
COLUMN threshold_pct FORMAT 9990.00     HEADING 'THRESH%'
COLUMN z            FORMAT 99990.0      HEADING 'ROBUST_Z'
COLUMN n_hist       FORMAT 9990         HEADING 'N_HIST'
COLUMN pct_vs_med   FORMAT S9999990     HEADING 'VS_MED%'
COLUMN anomaly_flag FORMAT A5           HEADING 'FLAG'

SELECT db_pdb,
       metric,
       mode_short,
       ts_str,
       value_pct,
       median_pct,
       threshold_pct,
       z,
       n_hist,
       pct_vs_med,
       anomaly_flag
FROM   capr_cpu_anomalies
WHERE  days_ago < &anomaly_days
-- days_ago ASC is exactly day_dt DESC (days_ago = last collected day - day_dt)
ORDER  BY days_ago, con_dbid, metric, mode_rank, ts;

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
