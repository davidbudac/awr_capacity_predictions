--
-- 00_at_a_glance.sql -- alert roll-up + current alert list.
-- Consumes CAPR_ALERTS only (M7.3), so this block and the HTML report's
-- banner can never disagree: both read the same view. The anomaly kinds use
-- the CAP_CONFIG anomaly_report_days window (not this report's &anomaly_days).
--
PROMPT
PROMPT == 0. AT A GLANCE (from CAPR_ALERTS) ==
PROMPT    One row per current issue. TBSPC_FULL/CPU_SAT/DBCPU_SAT/SERIES_LIMIT: confident
PROMPT    forecast inside the warning window. TBSPC_NEARFULL/SERIES_NEARLIMIT/CPU_HOT/DBCPU_HOT:
PROMPT    at the line RIGHT NOW, any forecast quality. *_ANOM: flagged days in the alert
PROMPT    window (INFO = shrink/LOW side). CPU_SHIFT: a sustained level shift.
PROMPT    DATA_STALE (listed first): AWR snapshots stopped arriving, so everything else is
PROMPT    frozen. MODEL_HEALTH: Tier 2 training failed (WARN) or went stale (INFO).

COLUMN crit_n  FORMAT 9990  HEADING 'CRIT'
COLUMN warn_n  FORMAT 9990  HEADING 'WARN'
COLUMN info_n  FORMAT 9990  HEADING 'INFO'

SELECT NVL(SUM(CASE WHEN severity = 'CRIT' THEN 1 END), 0) AS crit_n,
       NVL(SUM(CASE WHEN severity = 'WARN' THEN 1 END), 0) AS warn_n,
       NVL(SUM(CASE WHEN severity = 'INFO' THEN 1 END), 0) AS info_n
FROM   capr_alerts;

COLUMN severity FORMAT A4   HEADING 'SEV'
COLUMN kind     FORMAT A16  HEADING 'KIND'
COLUMN db_pdb   FORMAT A20  HEADING 'DB/PDB'
COLUMN message  FORMAT A140 WORD_WRAPPED HEADING 'MESSAGE'

SELECT severity,
       kind,
       db_pdb,
       message
FROM   capr_alerts
ORDER  BY CASE kind WHEN 'DATA_STALE' THEN 0 ELSE 1 END, sev_rank, kind, db_pdb, series_key, day_dt;
