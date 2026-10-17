--
-- quickstart.sql -- zero-to-first-report in one run (local mode).
-- =====================================================================
-- Runs, in order:
--   1. doctor.sql          preflight checklist (read-only; PASS/WARN/FAIL)
--   2. install.sql         seam_mode = local, into the current schema
--   3. report/report.sql   the first text report -> reports/cap_report_*.txt
--
-- Usage -- from the REPO ROOT (the @@ includes resolve from the outermost
-- caller on 19c), connected where AWR is visible, i.e. sysdba in CDB$ROOT:
--
--   sqlplus / as sysdba
--   SQL> @quickstart.sql
--
-- or simply  ./quickstart.sh  (same thing, wrapped).
--
-- Local mode only. For warehouse / fixture mode use install.sql directly with
-- DEFINE seam_mode (see docs: Reference -> Advanced install).
--
-- Read-only against AWR: the only writes are the suite's own CAP_CONFIG /
-- CAP_TBSPC_OVERRIDE / CAP_ML_MODEL tables. Re-running is idempotent.
-- On a stock box (8-day AWR retention) the first report says
-- INSUFFICIENT_HISTORY -- that is expected; raise retention and let it fill.
--
-- It stops before install when doctor.sql reports any FAIL line. WARN lines
-- (short history, SYS as the target schema) do not stop it. To install anyway:
--   SQL> DEFINE force_install = Y
--   SQL> @quickstart.sql
--
-- As SYS this installs into SYS. For a dedicated owner see create_owner.sql.
--
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF

PROMPT
PROMPT ############################################################
PROMPT  AWR Capacity Predictions -- quickstart (local mode)
PROMPT  1/3 preflight   2/3 install   3/3 first report
PROMPT ############################################################
PROMPT

-- reports/ must exist before report.sql can SPOOL into it. Done here, before
-- install.sql switches WHENEVER OSERROR to EXIT, so a no-op on an existing
-- dir (or a Windows shell) cannot abort the run.
HOST mkdir -p reports

PROMPT ==== [1/3] preflight -- doctor.sql ====
-- Judge readiness for the local install this script is about to run, even if
-- the schema currently holds a fixture or warehouse install.
DEFINE cap_doctor_mode = 'local'
@@doctor.sql
SET DEFINE '&'
SET FEEDBACK OFF

-- force_install defaults to N without prompting: a zero-row NEW_VALUE query
-- defines an unset variable as empty and leaves a set one alone.
SET TERMOUT OFF
COLUMN cap_force_in NEW_VALUE force_install NOPRINT
SELECT NULL AS cap_force_in FROM dual WHERE 1 = 0;
COLUMN cap_force_in CLEAR
SET TERMOUT ON

-- Stop on a doctor FAIL: print why, then divide by zero under
-- WHENEVER SQLERROR EXIT so sqlplus exits non-zero before install.sql runs.
SET HEADING OFF
SELECT 'quickstart: STOPPED before install. doctor.sql reported &cap_doctor_fail FAIL line(s)'
       || ' (a FAIL means install.sql would fail or forecasts would be empty).'
       || CHR(10) || 'Fix the FAIL lines above and re-run, or DEFINE force_install = Y to install anyway.'
FROM   dual
WHERE  TO_NUMBER('&cap_doctor_fail') > 0
  AND  UPPER(NVL('&force_install', 'N')) <> 'Y';
SET HEADING ON
WHENEVER SQLERROR EXIT FAILURE
COLUMN cap_gate NOPRINT
SELECT CASE WHEN TO_NUMBER('&cap_doctor_fail') > 0
             AND UPPER(NVL('&force_install', 'N')) <> 'Y'
            THEN 1/0 ELSE 0 END AS cap_gate
FROM   dual;
COLUMN cap_gate CLEAR
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT ==== [2/3] install -- install.sql  (seam_mode = local) ====
DEFINE seam_mode = 'local'
@@install.sql

PROMPT
PROMPT ==== [3/3] first report -- report/report.sql ====
@@report/report.sql

SET DEFINE '&'
PROMPT ############################################################
PROMPT  Quickstart done. The report path is printed just above.
PROMPT  If it says INSUFFICIENT_HISTORY: AWR retention is probably
PROMPT  the stock 8 days. Raise it (the only Oracle change you make):
PROMPT    EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention => 90*24*60);
PROMPT  then re-run @report/report.sql once history has accumulated.
PROMPT ############################################################
PROMPT
UNDEFINE seam_mode
UNDEFINE force_install
UNDEFINE cap_doctor_mode
