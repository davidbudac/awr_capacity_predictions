-- bench/setup/00_redo_logs.sql -- enlarge online + standby redo (CDB$ROOT, sysdba).
--
-- Stock dbmint ships 3 x 50 MB online / 4 x 50 MB standby redo; the SOE build
-- pinned the DB on "log file switch (checkpoint incomplete)" (~19 switches/h),
-- so every OLTP phase would be redo-bound instead of CPU-bound. This replaces
-- them with 3 x &redo_mb MB online and 4 x &redo_mb MB standby groups (OMF).
-- Idempotent: skips groups that are already >= &redo_mb. Run on the PRIMARY;
-- a physical standby needs the same standby-redo change on its side.
SET SERVEROUTPUT ON VERIFY OFF FEEDBACK OFF
DECLARE
    want_mb   CONSTANT NUMBER := &redo_mb;
    n_small   NUMBER;
    v_status  VARCHAR2(16);
    PROCEDURE say(p VARCHAR2) IS BEGIN DBMS_OUTPUT.PUT_LINE(p); END;
BEGIN
    -- online redo -----------------------------------------------------------
    SELECT COUNT(*) INTO n_small FROM v$log WHERE bytes < want_mb * 1024 * 1024;
    IF n_small = 0 THEN
        say('online redo already >= ' || want_mb || ' MB, nothing to do');
    ELSE
        FOR i IN 1 .. 3 LOOP
            EXECUTE IMMEDIATE 'ALTER DATABASE ADD LOGFILE SIZE ' || want_mb || 'M';
        END LOOP;
        say('added 3 x ' || want_mb || ' MB online groups');
        -- cycle the small groups out and drop them once they are INACTIVE
        FOR r IN (SELECT group# FROM v$log WHERE bytes < want_mb * 1024 * 1024 ORDER BY group#) LOOP
            LOOP
                SELECT status INTO v_status FROM v$log WHERE group# = r.group#;
                EXIT WHEN v_status IN ('INACTIVE', 'UNUSED');
                EXECUTE IMMEDIATE 'ALTER SYSTEM SWITCH LOGFILE';
                EXECUTE IMMEDIATE 'ALTER SYSTEM CHECKPOINT';
                DBMS_SESSION.SLEEP(2);
            END LOOP;
            EXECUTE IMMEDIATE 'ALTER DATABASE DROP LOGFILE GROUP ' || r.group#;
            say('dropped online group ' || r.group#);
        END LOOP;
    END IF;
    -- standby redo ----------------------------------------------------------
    FOR r IN (SELECT group# FROM v$standby_log
              WHERE bytes < want_mb * 1024 * 1024 AND status = 'UNASSIGNED') LOOP
        EXECUTE IMMEDIATE 'ALTER DATABASE DROP STANDBY LOGFILE GROUP ' || r.group#;
        say('dropped standby group ' || r.group#);
    END LOOP;
    SELECT COUNT(*) INTO n_small FROM v$standby_log WHERE bytes >= want_mb * 1024 * 1024;
    FOR i IN n_small + 1 .. 4 LOOP
        EXECUTE IMMEDIATE 'ALTER DATABASE ADD STANDBY LOGFILE SIZE ' || want_mb || 'M';
    END LOOP;
    say('standby redo: 4 x ' || want_mb || ' MB');
END;
/
SET FEEDBACK ON
SELECT group#, bytes/1048576 mb, status FROM v$log ORDER BY 1;
SELECT group#, bytes/1048576 mb, status FROM v$standby_log ORDER BY 1;
