--
-- 00_at_a_glance.sql -- coverage, last refresh run, alert roll-up + list.
-- The alerts come from CAPR_ALERTS only (M7.3), so this block and the HTML
-- report's banner can never disagree: both read the same view. The anomaly
-- kinds use the CAP_CONFIG anomaly_report_days window (not this report's
-- &anomaly_days). The two lines above them come from CAPR_COVERAGE (one per
-- dbid) and CAPR_RUNS (the results layer, ddl/60).
-- Scope (&cap_sdbid / &cap_scon) filters every query. Source SNAPSHOT reads
-- the alerts from CAPR_ALERTS_LATEST (the OPEN, unacknowledged states of the
-- last refresh run) and prints that run's summary as the coverage line,
-- because CAPR_COVERAGE is not snapshotted. The UNION ALL branches carry a
-- constant predicate, so the optimizer never evaluates the other source.
--
PROMPT
PROMPT == 0. AT A GLANCE (from CAPR_ALERTS, or CAPR_ALERTS_LATEST when the source is SNAPSHOT) ==
PROMPT    One row per current issue. TBSPC_FULL/CPU_SAT/DBCPU_SAT/SERIES_LIMIT: confident
PROMPT    forecast inside the warning window. TBSPC_NEARFULL/SERIES_NEARLIMIT/CPU_HOT/DBCPU_HOT:
PROMPT    at the line RIGHT NOW, any forecast quality. *_ANOM: flagged days in the alert
PROMPT    window, a run of consecutive days as one row (INFO = shrink/LOW side, or a CPU
PROMPT    day inside an active level shift). CPU_SHIFT: a sustained level shift.
PROMPT    DATA_STALE (listed first): AWR snapshots stopped arriving, so everything else is
PROMPT    frozen. MODEL_HEALTH: Tier 2 training failed (WARN) or went stale (INFO).

COLUMN cov_line FORMAT A160 WORD_WRAPPED HEADING 'COVERAGE'
COLUMN run_line FORMAT A160 WORD_WRAPPED HEADING 'RESULTS LAYER'

SELECT summary AS cov_line
FROM   capr_coverage
WHERE  '&cap_src' = 'LIVE'
  AND  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR dbid IN (SELECT dbid FROM capr_container WHERE con_dbid = &cap_scon))
UNION  ALL
SELECT 'coverage as of ' || summary
FROM   capr_runs
WHERE  '&cap_src' = 'SNAPSHOT'
  AND  run_id = last_ok_run_id;

SELECT NVL(MAX(CASE WHEN is_last = 'Y'
                    THEN 'last ' || summary
                         || CASE WHEN stale_run = 'Y'
                                 THEN ' -- STALE: no OK refresh run in the last '
                                      || TO_CHAR(cfg.refresh_stale_hours) || ' h' END END),
           'no refresh run yet (live evaluation)') AS run_line
FROM   capr_runs
CROSS  JOIN cap_cfg cfg;

COLUMN crit_n  FORMAT 9990  HEADING 'CRIT'
COLUMN warn_n  FORMAT 9990  HEADING 'WARN'
COLUMN info_n  FORMAT 9990  HEADING 'INFO'

SELECT NVL(SUM(CASE WHEN severity = 'CRIT' THEN 1 END), 0) AS crit_n,
       NVL(SUM(CASE WHEN severity = 'WARN' THEN 1 END), 0) AS warn_n,
       NVL(SUM(CASE WHEN severity = 'INFO' THEN 1 END), 0) AS info_n
FROM  (SELECT severity, dbid, con_dbid FROM capr_alerts        WHERE '&cap_src' = 'LIVE'
       UNION ALL
       SELECT severity, dbid, con_dbid FROM capr_alerts_latest WHERE '&cap_src' = 'SNAPSHOT')
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon);

COLUMN severity FORMAT A4   HEADING 'SEV'
COLUMN kind     FORMAT A16  HEADING 'KIND'
COLUMN db_pdb   FORMAT A20  HEADING 'DB/PDB'
COLUMN message  FORMAT A140 WORD_WRAPPED HEADING 'MESSAGE'

SELECT severity,
       kind,
       db_pdb,
       message
FROM  (SELECT severity, sev_rank, kind, dbid, con_dbid, db_pdb, series_key, day_dt, message
       FROM   capr_alerts        WHERE '&cap_src' = 'LIVE'
       UNION ALL
       SELECT severity, sev_rank, kind, dbid, con_dbid, db_pdb, series_key, day_dt, message
       FROM   capr_alerts_latest WHERE '&cap_src' = 'SNAPSHOT')
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY CASE kind WHEN 'DATA_STALE' THEN 0 ELSE 1 END, sev_rank, kind, db_pdb, series_key, day_dt;
