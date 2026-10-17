--
-- install_jobs.sql -- OPT-IN DBMS_SCHEDULER automation for the suite.
-- =====================================================================
-- NOT part of install.sql. Run it separately, in the schema that owns the
-- suite, only if you want the three background jobs below:
--
--   CAP_REFRESH_JOB   daily (01:30) cap_results.refresh -- snapshot CAPR_FIT
--                     and CAPR_ALERTS into the results tables (CAP_RUN,
--                     CAP_FIT_HIST, CAP_ALERT_STATE, CAP_ALERT_EVENT), so
--                     pollers get NEW / RESOLVED events and the reports and
--                     CAPR_ALERTS_LATEST read the last run instead of the
--                     view chain. The schedule is the refresh_interval
--                     DEFINE. A failed refresh ends FAILED and leaves a
--                     FAILED row in CAP_RUN with the error stack.
--   CAP_ML_RETRAIN    daily (02:00) cap_forecast_ml.train_all -- refresh
--                     the Tier 2 OML ESM models against the latest AWR days.
--                     Needs CREATE MINING MODEL. The schedule is the
--                     retrain_interval DEFINE (a DBMS_SCHEDULER calendar
--                     string). Daily, not weekly, because of the freshness
--                     gate: CAPF_COMPARE drops a model older than
--                     esm_max_age_days (7), and until then compares an ESM
--                     value dated up to a week before the REGR one. A run
--                     ends FAILED (ORA-20060) when any forecast model failed
--                     to build; the reason is in CAPF_ESM_HEALTH.last_error.
--   CAP_REPORT_SPOOL_JOB
--                     daily (03:00) cap_report_spool(<dir>) -- writes an
--                     alert-snapshot text file into a directory object. With
--                     a refresh run on record it lists the OPEN, not acked
--                     alerts of CAPR_ALERTS_LATEST plus the last run's
--                     events; with none it evaluates CAPR_ALERTS live.
--
-- Why the "_JOB" suffix: DBMS_SCHEDULER jobs live in the SAME schema
-- namespace as procedures, so a job called CAP_REPORT_SPOOL beside a
-- procedure of that name fails with ORA-27477 "already exists" (verified on
-- 19c). The procedure keeps the plain name -- it is the thing you call by
-- hand -- and the job takes the suffix.
--
-- ALL JOBS ARE CREATED DISABLED. Nothing runs until you enable them (the
-- closing PROMPT block shows how). Re-running this script is idempotent: it
-- drops the jobs if they exist, then recreates them, again disabled.
--
-- Why the spool job is not "the report": SQL*Plus spooling cannot happen
-- inside a scheduler PL/SQL job -- there is no SQL*Plus there. So the job
-- writes a POLLABLE SNAPSHOT, not the full report: a header (timestamp,
-- database, data freshness, last refresh run, CRIT/WARN/INFO counts) plus
-- one pipe-delimited line per alert. For the full formatted report keep using
-- `sqlplus ... @report/report.sql` from cron / the OS scheduler.
--
-- Usage:
--   sqlplus / as sysdba
--   SQL> DEFINE report_dir = 'MY_DIR'    -- optional; default CAP_REPORTS
--   SQL> DEFINE retrain_interval = 'FREQ=WEEKLY;BYDAY=SUN;BYHOUR=2'
--                                        -- optional; default daily 02:00
--   SQL> DEFINE refresh_interval = 'FREQ=HOURLY;BYMINUTE=15'
--                                        -- optional; default daily 01:30
--   SQL> @install_jobs.sql
--
-- The directory object is NOT created here (that needs CREATE ANY DIRECTORY
-- and a path decision only you can make). The script checks ALL_DIRECTORIES
-- and prints the exact DDL if it is missing.
--
-- Read-only against AWR, as ever: the jobs only read the CAP views and write
-- to CAP_ML_MODEL, the results tables and the OS file.
--
-- Remove everything with @uninstall_jobs.sql.
--
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

-- --------------------------------------------------------------------
-- Default report_dir when the caller did not DEFINE it. First SELECT
-- returns no rows, which DEFINEs the variable as empty without prompting;
-- the second applies the default. (Same COLUMN ... NEW_VALUE trick the
-- report driver uses for unset positional args.)
-- --------------------------------------------------------------------
SET TERMOUT OFF
COLUMN report_dir NEW_VALUE report_dir NOPRINT
SELECT CAST(NULL AS VARCHAR2(30)) AS report_dir FROM dual WHERE 1 = 0;
SELECT UPPER(NVL('&report_dir', 'CAP_REPORTS')) AS report_dir FROM dual;
COLUMN retrain_interval NEW_VALUE retrain_interval NOPRINT
SELECT CAST(NULL AS VARCHAR2(200)) AS retrain_interval FROM dual WHERE 1 = 0;
SELECT NVL('&retrain_interval', 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0') AS retrain_interval FROM dual;
COLUMN refresh_interval NEW_VALUE refresh_interval NOPRINT
SELECT CAST(NULL AS VARCHAR2(200)) AS refresh_interval FROM dual WHERE 1 = 0;
SELECT NVL('&refresh_interval', 'FREQ=DAILY;BYHOUR=1;BYMINUTE=30;BYSECOND=0') AS refresh_interval FROM dual;
SET TERMOUT ON

PROMPT
PROMPT ============================================================
PROMPT  AWR Capacity Predictions -- scheduler jobs (opt-in)
PROMPT ============================================================
PROMPT  report_dir = &report_dir  (directory object for the alert snapshot)
PROMPT  retrain    = &retrain_interval  (CAP_ML_RETRAIN schedule)
PROMPT  refresh    = &refresh_interval  (CAP_REFRESH_JOB schedule)
PROMPT

-- --------------------------------------------------------------------
-- Directory object check. Warn + instruct; never create it here.
-- --------------------------------------------------------------------
DECLARE
    v_n    PLS_INTEGER := 0;
    v_path VARCHAR2(4000);
BEGIN
    BEGIN
        SELECT COUNT(*), MAX(directory_path)
        INTO   v_n, v_path
        FROM   all_directories
        WHERE  directory_name = '&report_dir';
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('  [WARN] cannot read ALL_DIRECTORIES: ' || SQLERRM);
            v_n := -1;
    END;

    IF v_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  [WARN] directory object &report_dir does not exist.');
        DBMS_OUTPUT.PUT_LINE('         CAP_REPORT_SPOOL will fail with ORA-29280 until'
                             || ' you create it:');
        DBMS_OUTPUT.PUT_LINE('           CREATE OR REPLACE DIRECTORY &report_dir AS'
                             || ' ''/path/on/the/db/server'';');
        DBMS_OUTPUT.PUT_LINE('           GRANT READ, WRITE ON DIRECTORY &report_dir TO '
                             || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') || ';');
    ELSIF v_n > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  [ OK ] directory &report_dir -> ' || v_path);
    END IF;
END;
/

PROMPT -- creating procedure cap_report_spool ...

CREATE OR REPLACE PROCEDURE cap_report_spool (p_dir IN VARCHAR2 DEFAULT 'CAP_REPORTS')
AUTHID DEFINER
AS
    -- Pollable alert snapshot, written to <p_dir>/cap_alerts.txt (overwritten
    -- on every run, so a poller can just read the one stable file name).
    -- NOT the full capacity report -- that needs SQL*Plus formatting; this is
    -- one line per alert plus a header.
    -- Format: SEVERITY|KIND|DB_PDB|SERIES_KEY|DAY|VALUE|THRESHOLD|UNIT|MESSAGE
    -- The header says how fresh the data is (one "data through" line per dbid,
    -- from CAPR_FRESHNESS) and which refresh run the list comes from.
    -- With an OK live refresh run on record the alerts are the OPEN, not
    -- acked states of CAPR_ALERTS_LATEST (the last run's view; acked ones
    -- are left out) and the run's events follow as '#event|' lines; with
    -- none they are CAPR_ALERTS, evaluated now. DATA_STALE rows come first:
    -- a stalled AWR would otherwise read as a quiet system.
    c_file  CONSTANT VARCHAR2(30) := 'cap_alerts.txt';
    l_f     UTL_FILE.FILE_TYPE;
    l_crit  PLS_INTEGER := 0;
    l_warn  PLS_INTEGER := 0;
    l_info  PLS_INTEGER := 0;
    l_tot   PLS_INTEGER := 0;
    l_run   NUMBER;

    PROCEDURE alert_line(p_sev VARCHAR2, p_kind VARCHAR2, p_db VARCHAR2, p_key VARCHAR2,
                         p_day DATE, p_val NUMBER, p_thr NUMBER, p_unit VARCHAR2, p_msg VARCHAR2) IS
    BEGIN
        UTL_FILE.PUT_LINE(l_f,
            p_sev                                   || '|' ||
            p_kind                                  || '|' ||
            NVL(p_db, '-')                          || '|' ||
            NVL(p_key, '-')                         || '|' ||
            NVL(TO_CHAR(p_day, 'YYYY-MM-DD'), '-')  || '|' ||
            NVL(TO_CHAR(ROUND(p_val, 2)), '-')      || '|' ||
            NVL(TO_CHAR(ROUND(p_thr, 2)), '-')      || '|' ||
            NVL(p_unit, '-')                        || '|' ||
            NVL(p_msg, '-'));
    END alert_line;
BEGIN
    SELECT MAX(run_id) INTO l_run FROM cap_run WHERE status = 'OK' AND backdated = 'N';
    IF l_run IS NOT NULL THEN
        SELECT COUNT(CASE WHEN severity = 'CRIT' THEN 1 END),
               COUNT(CASE WHEN severity = 'WARN' THEN 1 END),
               COUNT(CASE WHEN severity = 'INFO' THEN 1 END),
               COUNT(*)
        INTO   l_crit, l_warn, l_info, l_tot
        FROM   capr_alerts_latest;
    ELSE
        SELECT COUNT(CASE WHEN severity = 'CRIT' THEN 1 END),
               COUNT(CASE WHEN severity = 'WARN' THEN 1 END),
               COUNT(CASE WHEN severity = 'INFO' THEN 1 END),
               COUNT(*)
        INTO   l_crit, l_warn, l_info, l_tot
        FROM   capr_alerts;
    END IF;

    l_f := UTL_FILE.FOPEN(UPPER(p_dir), c_file, 'w', 32767);

    UTL_FILE.PUT_LINE(l_f, '# AWR Capacity Predictions -- alert snapshot');
    UTL_FILE.PUT_LINE(l_f, '# generated : '
                           || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    UTL_FILE.PUT_LINE(l_f, '# database  : ' || SYS_CONTEXT('USERENV', 'DB_NAME')
                           || ' / ' || NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), 'non-CDB'));
    UTL_FILE.PUT_LINE(l_f, '# schema    : ' || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
    FOR d IN (SELECT dbid, db_name, newest_snap, age_hours, is_stale
              FROM   capr_freshness
              ORDER  BY dbid) LOOP
        UTL_FILE.PUT_LINE(l_f, '# data through: ' || d.db_name || ' (dbid ' || d.dbid || ') '
                               || TO_CHAR(d.newest_snap, 'YYYY-MM-DD HH24:MI') || ', '
                               || TO_CHAR(d.age_hours, 'FM9999990.0') || ' h ago'
                               || CASE WHEN d.is_stale = 'Y' THEN ' (STALE)' END);
    END LOOP;
    IF l_run IS NULL THEN
        UTL_FILE.PUT_LINE(l_f, '# refresh   : no refresh run yet (live evaluation of CAPR_ALERTS)');
    END IF;
    FOR r IN (SELECT run_id, as_of_day, status, last_ok_age_hours, stale_run, summary, is_last
              FROM   capr_runs
              WHERE  is_last = 'Y' OR run_id = l_run
              ORDER  BY run_id DESC) LOOP
        UTL_FILE.PUT_LINE(l_f, '# refresh   : ' || CASE WHEN r.is_last = 'Y' THEN 'last ' ELSE 'last OK ' END
                               || r.summary || ', as of ' || TO_CHAR(r.as_of_day, 'YYYY-MM-DD')
                               || ', status ' || r.status
                               || CASE WHEN r.run_id = l_run
                                       THEN ', ' || TO_CHAR(r.last_ok_age_hours, 'FM9999990.0') || ' h ago' END
                               || CASE WHEN r.stale_run = 'Y' THEN ' (STALE REFRESH)' END);
    END LOOP;
    UTL_FILE.PUT_LINE(l_f, '# alerts    : ' || l_tot || ' total  ('
                           || l_crit || ' CRIT, ' || l_warn || ' WARN, '
                           || l_info || ' INFO)'
                           || CASE WHEN l_run IS NOT NULL
                                   THEN ' open and not acked as of run ' || l_run END);
    UTL_FILE.PUT_LINE(l_f, '# columns   : '
                           || 'SEVERITY|KIND|DB_PDB|SERIES_KEY|DAY|VALUE|THRESHOLD|UNIT|MESSAGE');
    UTL_FILE.PUT_LINE(l_f, '#');

    IF l_tot = 0 THEN
        UTL_FILE.PUT_LINE(l_f, 'OK|NONE|-|-|-|-|-|-|No capacity alerts.');
    ELSIF l_run IS NOT NULL THEN
        FOR r IN (SELECT severity, kind, db_pdb, series_key, day_dt,
                         value, threshold, unit, message
                  FROM   capr_alerts_latest
                  ORDER  BY CASE kind WHEN 'DATA_STALE' THEN 0 ELSE 1 END,
                            sev_rank, kind, db_pdb, series_key) LOOP
            alert_line(r.severity, r.kind, r.db_pdb, r.series_key, r.day_dt,
                       r.value, r.threshold, r.unit, r.message);
        END LOOP;
    ELSE
        FOR r IN (SELECT severity, kind, db_pdb, series_key, day_dt,
                         value, threshold, unit, message
                  FROM   capr_alerts
                  ORDER  BY CASE kind WHEN 'DATA_STALE' THEN 0 ELSE 1 END,
                            sev_rank, kind, db_pdb, series_key) LOOP
            alert_line(r.severity, r.kind, r.db_pdb, r.series_key, r.day_dt,
                       r.value, r.threshold, r.unit, r.message);
        END LOOP;
    END IF;

    IF l_run IS NOT NULL THEN
        UTL_FILE.PUT_LINE(l_f, '#');
        UTL_FILE.PUT_LINE(l_f, '# events of run ' || l_run
                               || ': #event|EVENT|SEVERITY|KIND|DB_PDB|SERIES_KEY|AT|MESSAGE');
        FOR e IN (SELECT event, severity, kind, db_pdb, series_key, at_time, message
                  FROM   capr_alert_events
                  WHERE  run_id = l_run
                  ORDER  BY event_id) LOOP
            UTL_FILE.PUT_LINE(l_f, '#event|' || e.event || '|' || e.severity || '|' || e.kind || '|'
                                   || NVL(e.db_pdb, '-') || '|' || NVL(e.series_key, '-') || '|'
                                   || TO_CHAR(e.at_time, 'YYYY-MM-DD HH24:MI') || '|' || NVL(e.message, '-'));
        END LOOP;
    END IF;

    UTL_FILE.FCLOSE(l_f);
EXCEPTION
    WHEN OTHERS THEN
        IF UTL_FILE.IS_OPEN(l_f) THEN
            UTL_FILE.FCLOSE(l_f);
        END IF;
        RAISE;
END cap_report_spool;
/

-- Report (but do not fail on) a procedure that could not compile -- e.g. when
-- CAPR_ALERTS is missing because the suite is not installed in this schema.
DECLARE
    v_status VARCHAR2(20);
BEGIN
    -- ALL_OBJECTS + owner, not USER_OBJECTS: USER_* follows the session user,
    -- not CURRENT_SCHEMA, so it would look in the wrong schema whenever you
    -- installed with ALTER SESSION SET CURRENT_SCHEMA.
    SELECT MAX(status) INTO v_status
    FROM   all_objects
    WHERE  owner       = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
      AND  object_name = 'CAP_REPORT_SPOOL'
      AND  object_type = 'PROCEDURE';

    IF v_status IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('  [WARN] procedure CAP_REPORT_SPOOL was not created.');
    ELSIF v_status = 'INVALID' THEN
        DBMS_OUTPUT.PUT_LINE('  [WARN] procedure CAP_REPORT_SPOOL is INVALID '
                             || '(are CAPR_ALERTS and ddl/60 installed in this schema?).');
    ELSE
        DBMS_OUTPUT.PUT_LINE('  [ OK ] procedure CAP_REPORT_SPOOL is VALID.');
    END IF;
END;
/

PROMPT -- (re)creating the three jobs, DISABLED ...

-- --------------------------------------------------------------------
-- Drop-if-exists. ORA-27475 (unknown job) / ORA-27476 (does not exist) are
-- the "was not there" codes; anything else is a real problem and re-raises.
-- --------------------------------------------------------------------
DECLARE
    PROCEDURE drop_job(p_name IN VARCHAR2) IS
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => p_name, force => TRUE);
        DBMS_OUTPUT.PUT_LINE('  dropped existing job ' || p_name);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-27475, -27476) THEN
                RAISE;
            END IF;
    END drop_job;
BEGIN
    drop_job('CAP_REFRESH_JOB');
    drop_job('CAP_ML_RETRAIN');
    drop_job('CAP_REPORT_SPOOL_JOB');
END;
/

BEGIN
    -- Results layer: one refresh run per schedule tick. A failure re-raises,
    -- so the job run reads FAILED in the scheduler log as well as in CAP_RUN.
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'CAP_REFRESH_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN cap_results.refresh; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => '&refresh_interval',
        enabled         => FALSE,
        auto_drop       => FALSE,
        comments        => 'AWR capacity: results layer refresh (cap_results.refresh)');
    DBMS_OUTPUT.PUT_LINE('  created CAP_REFRESH_JOB   (disabled, &refresh_interval)');
END;
/

BEGIN
    -- Tier 2 retrain (see the header for why daily). train_all(p_top_n)
    -- defaults to the top 20 capacity-critical series, which is what the
    -- report shows, and refreshes their backtest twins too.
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'CAP_ML_RETRAIN',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN cap_forecast_ml.train_all; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => '&retrain_interval',
        enabled         => FALSE,
        auto_drop       => FALSE,
        comments        => 'AWR capacity: OML ESM retrain (cap_forecast_ml.train_all)');
    DBMS_OUTPUT.PUT_LINE('  created CAP_ML_RETRAIN    (disabled, &retrain_interval)');
END;
/

BEGIN
    -- Daily alert snapshot to <report_dir>/cap_alerts.txt.
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'CAP_REPORT_SPOOL_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN cap_report_spool(''&report_dir''); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY;BYHOUR=3;BYMINUTE=0;BYSECOND=0',
        enabled         => FALSE,
        auto_drop       => FALSE,
        comments        => 'AWR capacity: daily CAPR_ALERTS snapshot via UTL_FILE');
    DBMS_OUTPUT.PUT_LINE('  created CAP_REPORT_SPOOL_JOB (disabled, FREQ=DAILY 03:00)');
END;
/

PROMPT
PROMPT -- current state:
SET FEEDBACK ON
COLUMN job_name        FORMAT A20
COLUMN enabled         FORMAT A8
COLUMN repeat_interval FORMAT A44
SELECT job_name, enabled, repeat_interval
FROM   all_scheduler_jobs
WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
  AND  job_name IN ('CAP_REFRESH_JOB', 'CAP_ML_RETRAIN', 'CAP_REPORT_SPOOL_JOB')
ORDER  BY job_name;
SET FEEDBACK OFF

PROMPT
PROMPT ============================================================
PROMPT  Jobs installed, DISABLED. To turn them on:
PROMPT    EXEC DBMS_SCHEDULER.ENABLE('CAP_REFRESH_JOB')
PROMPT    EXEC DBMS_SCHEDULER.ENABLE('CAP_ML_RETRAIN')
PROMPT    EXEC DBMS_SCHEDULER.ENABLE('CAP_REPORT_SPOOL_JOB')
PROMPT  To run one once, right now:
PROMPT    EXEC DBMS_SCHEDULER.RUN_JOB('CAP_REPORT_SPOOL_JOB')
PROMPT  Or write the snapshot by hand, no job needed:
PROMPT    EXEC cap_report_spool('&report_dir')
PROMPT  To check results:
PROMPT    SELECT job_name, status, error#, actual_start_date
PROMPT      FROM user_scheduler_job_run_details ORDER BY log_date DESC;
PROMPT  To remove everything again:
PROMPT    @uninstall_jobs.sql
PROMPT ============================================================
PROMPT

SET FEEDBACK ON
