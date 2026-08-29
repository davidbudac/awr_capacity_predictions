--
-- uninstall_jobs.sql -- remove everything install_jobs.sql created.
-- =====================================================================
-- Drops the two DBMS_SCHEDULER jobs and the CAP_REPORT_SPOOL procedure from
-- the current schema. Idempotent: safe against a partial install or a schema
-- that never had the jobs. Touches nothing else -- the suite's views, tables
-- and OML models are untouched (use uninstall.sql for those).
--
SET DEFINE OFF
SET VERIFY   OFF
SET FEEDBACK OFF
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

PROMPT -- dropping scheduler jobs ...

DECLARE
    -- ORA-27475 (unknown job) / ORA-27476 (does not exist) mean "already gone".
    PROCEDURE drop_job(p_name IN VARCHAR2) IS
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => p_name, force => TRUE);
        DBMS_OUTPUT.PUT_LINE('  dropped job ' || p_name);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE IN (-27475, -27476) THEN
                DBMS_OUTPUT.PUT_LINE('  (job ' || p_name || ' not present)');
            ELSE
                DBMS_OUTPUT.PUT_LINE('  (could not drop ' || p_name || ': '
                                     || SQLERRM || ')');
            END IF;
    END drop_job;
BEGIN
    drop_job('CAP_ML_RETRAIN');
    drop_job('CAP_REPORT_SPOOL_JOB');
END;
/

PROMPT -- dropping procedure cap_report_spool ...

BEGIN
    EXECUTE IMMEDIATE 'DROP PROCEDURE cap_report_spool';
    DBMS_OUTPUT.PUT_LINE('  dropped procedure CAP_REPORT_SPOOL');
EXCEPTION
    WHEN OTHERS THEN
        -- ORA-04043: object does not exist
        IF SQLCODE = -4043 THEN
            DBMS_OUTPUT.PUT_LINE('  (procedure CAP_REPORT_SPOOL not present)');
        ELSE
            RAISE;
        END IF;
END;
/

PROMPT -- jobs uninstall complete.
SET FEEDBACK ON
