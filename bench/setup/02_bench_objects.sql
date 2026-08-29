-- bench/setup/02_bench_objects.sql -- run inside PDB1 as SYSDBA.
--
-- Creates the two benchmark tablespaces and a PDB-local DBA account for the
-- swingbench wizards (so the SYS password never has to be known or typed --
-- the wizards use JDBC thin, which cannot do OS authentication).
--
-- MAXSIZE is capped ON PURPOSE: days_to_full is only meaningful against a
-- bounded tablespace. NEXT 64M keeps the allocated-bytes series stepping in
-- visible increments rather than one jump.
--
-- Expects DEFINEs: maxsize, admin_user, admin_pass
SET SERVEROUTPUT ON
SET VERIFY OFF

DECLARE
    PROCEDURE ddl(p_sql VARCHAR2, p_ignore NUMBER DEFAULT NULL) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('ok  : ' || SUBSTR(p_sql, 1, 100));
    EXCEPTION
        WHEN OTHERS THEN
            IF p_ignore IS NOT NULL AND SQLCODE = p_ignore THEN
                DBMS_OUTPUT.PUT_LINE('skip: ' || SUBSTR(p_sql, 1, 60) || ' (already exists)');
            ELSE
                RAISE;
            END IF;
    END;
BEGIN
    -- ORA-01543: tablespace already exists
    ddl('CREATE TABLESPACE soetbs DATAFILE SIZE 256M AUTOEXTEND ON NEXT 64M MAXSIZE &maxsize', -1543);
    ddl('CREATE TABLESPACE shtbs  DATAFILE SIZE 256M AUTOEXTEND ON NEXT 64M MAXSIZE &maxsize', -1543);

    -- ORA-01920: user name conflicts with another user
    ddl('CREATE USER &admin_user IDENTIFIED BY "&admin_pass" DEFAULT TABLESPACE users', -1920);
    ddl('ALTER USER &admin_user IDENTIFIED BY "&admin_pass"');
    ddl('GRANT dba, unlimited tablespace TO &admin_user');
END;
/

COLUMN tablespace_name FORMAT a20
SELECT tablespace_name,
       ROUND(SUM(bytes)    / 1024 / 1024) mb,
       ROUND(SUM(maxbytes) / 1024 / 1024) max_mb
  FROM dba_data_files
 WHERE tablespace_name IN ('SOETBS', 'SHTBS')
 GROUP BY tablespace_name
 ORDER BY 1;
