--
-- 01_days_to_full_snap.sql -- section 1 when the source is SNAPSHOT.
-- FORMAT ONLY: the tablespace rows of CAPR_FIT_HISTORY for the newest OK
-- refresh run (&cap_snap_run, CAPR_RUNS.last_ok_run_id), i.e. CAPR_FIT as
-- the refresh saw it. CAP_FIT_HIST keeps CAPR_FIT's columns, so the gate and
-- the separate days-to-full / near-full severities of the live section are
-- not there: SEV is CAPR_FIT.sev, the worst severity of the tablespace over
-- both kinds. The ordering mirrors CAPR_TBSPC_DAYS_TO_FULL's rank_dtf and
-- rank_nearfull.
--
PROMPT
PROMPT == 1a. TABLESPACES BY DAYS-TO-FULL (any quality; top &top_n; refresh run &cap_snap_run) ==
PROMPT     Snapshot of CAPR_FIT. SEV = the worst severity CAPR_ALERTS raised for the
PROMPT     tablespace in that run (TBSPC_FULL or TBSPC_NEARFULL). WORST/BEST: the
PROMPT     days-to-full range from the 95% CI on the slope (BEST empty = might never
PROMPT     fill). Trust the estimate per QUALITY (only OK is reliable). The live run
PROMPT     of this report adds the gate, the cycle and the sizing columns.

COLUMN db_pdb          FORMAT A20           HEADING 'DB/PDB'
COLUMN tablespace_name FORMAT A18           HEADING 'TABLESPACE'
COLUMN pct_used        FORMAT 990.0         HEADING 'PCT_USED'
COLUMN cur_gb          FORMAT 99990.00      HEADING 'CUR_GIB'
COLUMN limit_gb        FORMAT 99990.00      HEADING 'LIMIT_GIB'
COLUMN slope_mb        FORMAT 999990.000    HEADING 'MIB/DAY'
COLUMN days_to_full    FORMAT 99999990      HEADING 'DAYS_FULL'
COLUMN dtf_worst       FORMAT 99999990      HEADING 'WORST'
COLUMN dtf_best        FORMAT 99999990      HEADING 'BEST'
COLUMN sev             FORMAT A4            HEADING 'SEV'
COLUMN quality         FORMAT A20           HEADING 'QUALITY'
COLUMN accel           FORMAT 990.00        HEADING 'ACCEL'
COLUMN need_gib_90     FORMAT 9999990.00    HEADING 'NEED_90_GIB'

SELECT db_pdb, tablespace_name, pct_used, cur_gb, limit_gb, slope_mb,
       days_to_full, dtf_worst, dtf_best, sev, quality, accel, need_gib_90
FROM  (SELECT h.db                          AS db_pdb,
              h.series                      AS tablespace_name,
              h.pct                         AS pct_used,
              h.value       / 1073741824    AS cur_gb,
              h.limit_value / 1073741824    AS limit_gb,
              h.slope_per_day / 1048576     AS slope_mb,
              h.days_to_full,
              h.days_to_full_lo             AS dtf_worst,
              h.days_to_full_hi             AS dtf_best,
              h.sev,
              h.quality,
              h.accel,
              h.need_gib_90,
              ROW_NUMBER() OVER (ORDER BY CASE WHEN h.days_to_full IS NOT NULL THEN 0
                                               WHEN h.quality = 'CYCLIC'      THEN 1
                                               ELSE 2 END,
                                          h.days_to_full, h.con_dbid, h.series) AS s_rank
       FROM   capr_fit_history h
       WHERE  h.run_id = &cap_snap_run
         AND  h.kind = 'TBSPC'
         AND  (&cap_sdbid IS NULL OR h.dbid = &cap_sdbid)
         AND  (&cap_scon  IS NULL OR h.con_dbid = &cap_scon))
WHERE  (days_to_full IS NOT NULL OR quality = 'CYCLIC')
  AND  s_rank <= &top_n
ORDER  BY s_rank;

PROMPT
PROMPT == 1b. NEAR-FULL NOW (by PCT_USED, independent of fit quality; top &top_n; refresh run &cap_snap_run) ==

SELECT db_pdb, tablespace_name, pct_used, cur_gb, limit_gb, days_to_full, sev, quality
FROM  (SELECT h.db                          AS db_pdb,
              h.series                      AS tablespace_name,
              h.pct                         AS pct_used,
              h.value       / 1073741824    AS cur_gb,
              h.limit_value / 1073741824    AS limit_gb,
              h.days_to_full,
              h.sev,
              h.quality,
              ROW_NUMBER() OVER (ORDER BY h.pct DESC NULLS LAST, h.con_dbid, h.series) AS s_rank
       FROM   capr_fit_history h
       WHERE  h.run_id = &cap_snap_run
         AND  h.kind = 'TBSPC'
         AND  (&cap_sdbid IS NULL OR h.dbid = &cap_sdbid)
         AND  (&cap_scon  IS NULL OR h.con_dbid = &cap_scon))
WHERE  pct_used IS NOT NULL
  AND  s_rank <= &top_n
ORDER  BY s_rank;
