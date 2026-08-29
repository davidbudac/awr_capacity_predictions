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
              'CAP_FIXTURE_CONTAINER','CAP_FIXTURE_META',
              'CAP_FIXTURE_RESOURCE_LIMIT','CAP_FIXTURE_SYSSTAT');
BEGIN
    FOR i IN 1 .. v.COUNT LOOP
        BEGIN EXECUTE IMMEDIATE 'DROP TABLE ' || v(i) || ' PURGE';
        EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
    END LOOP;
END;
/

-- M9.5: CAP_TBSPC_OVERRIDE is a PERSISTED operator table, not a fixture table,
-- so it is never dropped here -- only the rows this fixture seeded (every
-- fixture tablespace is named FIX_%) are removed. ORA-00942 means the suite
-- was never installed in this schema, which is fine.
BEGIN
    EXECUTE IMMEDIATE q'[DELETE FROM cap_tbspc_override WHERE tablespace_name LIKE 'FIX!_%' ESCAPE '!']';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF;
END;
/
PROMPT Fixture tables dropped.
