--
-- grafana/ords/awrcap_module_drop.sql -- remove the `awrcap` ORDS module.
--
--   As the schema owner:  SQL> @grafana/ords/awrcap_module_drop.sql
--   As a DBA:             SQL> @grafana/ords/awrcap_module_drop.sql CAPDEMO
--
-- Leaves the schema REST-enabled (other modules may live there); disable it
-- with ORDS.ENABLE_SCHEMA(p_enabled => FALSE) if awrcap was the only one.
-- A missing module is a no-op.
--
SET DEFINE ON
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

COLUMN 1 NEW_VALUE 1 NOPRINT
SELECT NULL AS "1" FROM dual WHERE 1 = 0;

DECLARE
    v_schema VARCHAR2(128) := UPPER(NVL('&1', SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')));
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') = v_schema THEN
        EXECUTE IMMEDIATE q'[BEGIN ords.delete_module(p_module_name => 'awrcap'); END;]';
    ELSE
        EXECUTE IMMEDIATE q'[BEGIN ords_admin.delete_module(p_schema => :s, p_module_name => 'awrcap'); END;]'
            USING v_schema;
    END IF;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('awrcap module removed from ' || v_schema);
END;
/

UNDEFINE 1
