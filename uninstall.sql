--
-- uninstall.sql -- remove every object the suite created from the current schema.
-- =====================================================================
-- Removes the opt-in scheduler jobs first (uninstall_jobs.sql), then the OML
-- models (via the package, which needs the registry), then all views, then
-- the three persisted tables, the two types and the package. Idempotent: safe
-- to run against a partial or already-removed install. "Does not exist" is
-- silent; any other error is printed and the script carries on. The last
-- block counts what is left in the current schema (0 expected).
--
-- CAP_FIXTURE_* test tables are not the suite's; test/fixture_remove.sql
-- drops them. The closing count lists them separately.
--
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF
WHENEVER SQLERROR CONTINUE

PROMPT -- removing scheduler jobs + cap_report_spool (uninstall_jobs.sql) ...
@@uninstall_jobs.sql
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF

PROMPT -- dropping OML models (cap_forecast_ml.drop_all) ...
BEGIN
    -- Dynamic, so a missing package is a runtime error we can recognise
    -- instead of a compile error of this block.
    EXECUTE IMMEDIATE 'BEGIN cap_forecast_ml.drop_all; END;';
    DBMS_OUTPUT.PUT_LINE('  OML models dropped');
EXCEPTION
    WHEN OTHERS THEN
        -- ORA-06550 wraps PLS-00201: package not installed.
        IF SQLCODE = -6550 THEN
            DBMS_OUTPUT.PUT_LINE('  (cap_forecast_ml not present)');
        ELSE
            DBMS_OUTPUT.PUT_LINE('  ERROR in drop_all: ' || SQLERRM);
        END IF;
END;
/

PROMPT -- dropping suite objects (ddl/00_drop.sql) ...
@@ddl/00_drop.sql
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF

PROMPT -- dropping persisted tables, types and package ...
-- The three persisted tables outlive 00_drop (which preserves them across a
-- re-install). A true uninstall removes them here.
DECLARE
    PROCEDURE drop_it(p_ddl IN VARCHAR2, p_gone IN PLS_INTEGER) IS
    BEGIN
        EXECUTE IMMEDIATE p_ddl;
        DBMS_OUTPUT.PUT_LINE('  ' || p_ddl);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != p_gone THEN
                DBMS_OUTPUT.PUT_LINE('  ERROR on "' || p_ddl || '": ' || SQLERRM);
            END IF;
    END drop_it;
BEGIN
    -- ORA-00942 table does not exist, ORA-04043 object does not exist.
    drop_it('DROP TABLE cap_ml_model PURGE',       -942);
    drop_it('DROP TABLE cap_tbspc_override PURGE', -942);
    drop_it('DROP TABLE cap_config PURGE',         -942);
    drop_it('DROP TYPE cap_esm_tab',               -4043);
    drop_it('DROP TYPE cap_esm_row',               -4043);
    drop_it('DROP PACKAGE cap_forecast_ml',        -4043);
END;
/

PROMPT -- what is left ...
DECLARE
    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_left  PLS_INTEGER := 0;
    v_fix   PLS_INTEGER := 0;
BEGIN
    FOR r IN (SELECT object_type, object_name
              FROM   all_objects
              WHERE  owner = v_owner
                AND  object_name LIKE 'CAP%'
              ORDER BY object_type, object_name) LOOP
        IF r.object_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\' THEN
            v_fix := v_fix + 1;
        ELSE
            v_left := v_left + 1;
            DBMS_OUTPUT.PUT_LINE('  still present: ' || r.object_type || ' ' || r.object_name);
        END IF;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('  ' || v_left || ' CAP% object(s) left in schema ' || v_owner
                         || ' (0 expected)');
    IF v_fix > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  plus ' || v_fix || ' CAP_FIXTURE_* test table(s);'
                             || ' remove them with @test/fixture_remove.sql');
    END IF;
END;
/

PROMPT -- uninstall complete.
SET FEEDBACK ON
