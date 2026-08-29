-- bench/teardown.sql -- drop the bench tablespaces and the wizard account.
-- Run inside PDB1 as SYSDBA (bench/teardown.sh does this). Expects: admin_user
SET SERVEROUTPUT ON
SET VERIFY OFF

DECLARE
    PROCEDURE ddl(p_sql VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('ok  : ' || SUBSTR(p_sql, 1, 80));
    EXCEPTION
        WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('skip: ' || SUBSTR(p_sql, 1, 60) || ' (' || SQLCODE || ')');
    END;
BEGIN
    ddl('DROP TABLESPACE soetbs INCLUDING CONTENTS AND DATAFILES');
    ddl('DROP TABLESPACE shtbs  INCLUDING CONTENTS AND DATAFILES');
    ddl('DROP USER &admin_user CASCADE');
END;
/
