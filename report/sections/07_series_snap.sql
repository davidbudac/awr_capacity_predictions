--
-- 07_series_snap.sql -- section 7 when the source is SNAPSHOT.
-- FORMAT ONLY: the SERIES rows of CAPR_FIT_HISTORY for the newest OK
-- refresh run (&cap_snap_run). CAPR_FIT names the days-to-limit column
-- days_to_full and has no saturation value or FRA days; the live section has
-- them. Series anomalies (7b) stay live: they are not snapshotted.
--
PROMPT
PROMPT == 7. FIXED-CEILING SERIES (refresh run &cap_snap_run) ==
PROMPT     Snapshot of CAPR_FIT. DAYS_LIM = projected days until the series reaches
PROMPT     series_sat_pct of LIMIT, WORST/BEST its 95% range. Trust it per QUALITY.

COLUMN db_pdb       FORMAT A20           HEADING 'DB/PDB'
COLUMN series       FORMAT A20           HEADING 'SERIES'
COLUMN unit         FORMAT A11           HEADING 'UNIT'
COLUMN n            FORMAT 9990          HEADING 'TRAIN_N'
COLUMN cur_val      FORMAT 99999990.00   HEADING 'CURRENT'
COLUMN cur_limit    FORMAT 99999990.00   HEADING 'LIMIT'
COLUMN pct_of_limit FORMAT 990.0         HEADING 'PCT_LIM'
COLUMN slope_day    FORMAT 9999990.0000  HEADING 'SLOPE/DAY'
COLUMN r2           FORMAT 90.999        HEADING 'R2'
COLUMN days_lim     FORMAT 99999990      HEADING 'DAYS_LIM'
COLUMN limit_worst  FORMAT 99999990      HEADING 'WORST'
COLUMN limit_best   FORMAT 99999990      HEADING 'BEST'
COLUMN sev          FORMAT A4            HEADING 'SEV'
COLUMN quality      FORMAT A20           HEADING 'QUALITY'

SELECT h.db                AS db_pdb,
       h.series,
       h.unit,
       h.train_n           AS n,
       h.value             AS cur_val,
       h.limit_value       AS cur_limit,
       h.pct               AS pct_of_limit,
       h.slope_per_day     AS slope_day,
       h.r2,
       h.days_to_full      AS days_lim,
       h.days_to_full_lo   AS limit_worst,
       h.days_to_full_hi   AS limit_best,
       h.sev,
       h.quality
FROM   capr_fit_history h
WHERE  h.run_id = &cap_snap_run
  AND  h.kind = 'SERIES'
  AND  (&cap_sdbid IS NULL OR h.dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR h.con_dbid = &cap_scon)
ORDER  BY h.days_to_full NULLS LAST, h.pct DESC NULLS LAST, h.con_dbid, h.series;

PROMPT
PROMPT == 7b. SERIES ANOMALIES (last &anomaly_days days, live) ==

COLUMN series       FORMAT A12           HEADING 'SERIES'
COLUMN day_dt       FORMAT A10           HEADING 'DAY'
COLUMN mode_short   FORMAT A4            HEADING 'MODE'
COLUMN value        FORMAT 99999990.00   HEADING 'VALUE'
COLUMN expected     FORMAT 99999990.00   HEADING 'MEDIAN'
COLUMN threshold    FORMAT 99999990.00   HEADING 'THRESHOLD'
COLUMN z            FORMAT 99990.0       HEADING 'ROBUST_Z'
COLUMN n_hist       FORMAT 9990          HEADING 'N_HIST'
COLUMN pct_vs_med   FORMAT S9999990      HEADING 'VS_MED%'
COLUMN anomaly_flag FORMAT A5            HEADING 'FLAG'

SELECT db_pdb, series, unit, day_str AS day_dt, mode_short, value, expected, threshold,
       z, n_hist, pct_vs_med, anomaly_flag
FROM   capr_series_anomalies
WHERE  days_ago < &anomaly_days
  AND  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY days_ago, con_dbid, series, mode_rank;
