--
-- 00_at_a_glance.sql -- alert roll-up + current alert list.
-- Consumes CAPR_ALERTS only (M7.3), so this block and the HTML report's
-- banner can never disagree: both read the same view. The anomaly kinds use
-- the CAP_CONFIG anomaly_report_days window (not this report's &anomaly_days).
--
PROMPT
PROMPT == 0. AT A GLANCE (from CAPR_ALERTS) ==
PROMPT    One row per current issue. TBSPC_FULL/CPU_SAT: confident forecast inside the
PROMPT    warning window. TBSPC_NEARFULL: nearly full RIGHT NOW, any forecast quality.
PROMPT    *_ANOM: flagged days in the alert window (INFO = shrink/LOW side).

COLUMN crit_n  FORMAT 9990  HEADING 'CRIT'
COLUMN warn_n  FORMAT 9990  HEADING 'WARN'
COLUMN info_n  FORMAT 9990  HEADING 'INFO'

SELECT NVL(SUM(CASE WHEN severity = 'CRIT' THEN 1 END), 0) AS crit_n,
       NVL(SUM(CASE WHEN severity = 'WARN' THEN 1 END), 0) AS warn_n,
       NVL(SUM(CASE WHEN severity = 'INFO' THEN 1 END), 0) AS info_n
FROM   capr_alerts;

COLUMN severity FORMAT A4   HEADING 'SEV'
COLUMN kind     FORMAT A14  HEADING 'KIND'
COLUMN db_pdb   FORMAT A20  HEADING 'DB/PDB'
COLUMN message  FORMAT A110 HEADING 'MESSAGE'

SELECT severity,
       kind,
       db_pdb,
       message
FROM   capr_alerts
ORDER  BY sev_rank, kind, db_pdb, series_key, day_dt;
