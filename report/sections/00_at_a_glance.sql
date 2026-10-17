--
-- 00_at_a_glance.sql -- coverage, last refresh run, alert roll-up + list.
-- The alerts come from CAPR_ALERTS only (M7.3), so this block and the HTML
-- report's banner can never disagree: both read the same view. The anomaly
-- kinds use the CAP_CONFIG anomaly_report_days window (not this report's
-- &anomaly_days). The two lines above them come from CAPR_COVERAGE (one per
-- dbid) and CAPR_RUNS (the results layer, ddl/60).
-- Scope (&cap_sdbid / &cap_scon) filters every query. Source SNAPSHOT reads
-- the alerts from CAPR_ALERTS_LATEST (the OPEN, unacknowledged states of the
-- last refresh run) and prints the coverage that run kept on CAP_RUN
-- (cov_summary, every dbid; the run summary on a run older than that
-- column). The UNION ALL branches carry a constant predicate, so the
-- optimizer never evaluates the other source.
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
PROMPT    The TOTAL row counts the rows below by severity.

COLUMN cov_line FORMAT A160 WORD_WRAPPED HEADING 'COVERAGE'
COLUMN run_line FORMAT A160 WORD_WRAPPED HEADING 'RESULTS LAYER'

SELECT summary AS cov_line
FROM   capr_coverage
WHERE  '&cap_src' = 'LIVE'
  AND  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR dbid IN (SELECT dbid FROM capr_container WHERE con_dbid = &cap_scon))
UNION  ALL
SELECT NVL(cov_summary, 'coverage as of ' || summary)
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

COLUMN severity FORMAT A4   HEADING 'SEV'
COLUMN kind     FORMAT A16  HEADING 'KIND'
COLUMN db_pdb   FORMAT A20  HEADING 'DB/PDB'
COLUMN message  FORMAT A140 WORD_WRAPPED HEADING 'MESSAGE'

-- One read of the alert source (the WITH is materialized): the TOTAL row
-- counts the scoped rows by severity, the rest is the list.
WITH a AS (
        SELECT /*+ MATERIALIZE */ severity, sev_rank, kind, db_pdb, series_key, day_dt, message
        FROM  (SELECT severity, sev_rank, kind, dbid, con_dbid, db_pdb, series_key, day_dt, message
               FROM   capr_alerts        WHERE '&cap_src' = 'LIVE'
               UNION ALL
               SELECT severity, sev_rank, kind, dbid, con_dbid, db_pdb, series_key, day_dt, message
               FROM   capr_alerts_latest WHERE '&cap_src' = 'SNAPSHOT')
        WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
          AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
     )
SELECT severity,
       kind,
       db_pdb,
       message
FROM  (SELECT CAST(NULL AS VARCHAR2(4)) AS severity, 'TOTAL' AS kind, CAST(NULL AS VARCHAR2(512)) AS db_pdb,
              'CRIT ' || COUNT(CASE WHEN severity = 'CRIT' THEN 1 END)
              || ', WARN ' || COUNT(CASE WHEN severity = 'WARN' THEN 1 END)
              || ', INFO ' || COUNT(CASE WHEN severity = 'INFO' THEN 1 END) AS message,
              0 AS grp, 0 AS stale_first, 0 AS sev_rank, CAST(NULL AS VARCHAR2(256)) AS series_key,
              CAST(NULL AS DATE) AS day_dt
       FROM   a
       UNION ALL
       SELECT severity, kind, db_pdb, message,
              1, CASE kind WHEN 'DATA_STALE' THEN 0 ELSE 1 END, sev_rank, series_key, day_dt
       FROM   a)
ORDER  BY grp, stale_first, sev_rank, kind, db_pdb, series_key, day_dt;
