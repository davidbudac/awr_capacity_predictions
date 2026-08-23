--
-- test/fixture_remove.sql -- drop the CAP_FIXTURE_* tables.
-- =====================================================================
-- Run after testing to remove the synthetic tables. The CAPV_* seam views
-- created over them (fixture mode) are left as-is; re-install in local mode
-- (or run uninstall.sql) to fully clean up.
--
SET DEFINE OFF
DECLARE
    TYPE nl IS TABLE OF VARCHAR2(30);
    v nl := nl('CAP_FIXTURE_SNAPSHOT','CAP_FIXTURE_TBSPC_USAGE','CAP_FIXTURE_TABLESPACE',
              'CAP_FIXTURE_DATAFILE','CAP_FIXTURE_OSSTAT','CAP_FIXTURE_TIME_MODEL',
              'CAP_FIXTURE_CONTAINER','CAP_FIXTURE_META');
BEGIN
    FOR i IN 1 .. v.COUNT LOOP
        BEGIN EXECUTE IMMEDIATE 'DROP TABLE ' || v(i) || ' PURGE';
        EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
    END LOOP;
END;
/
PROMPT Fixture tables dropped.
