--
-- create_owner.sql -- create a dedicated schema that owns the suite.
-- =====================================================================
-- The quickstart installs as SYS. That is fine for a first look, but it puts
-- every CAP* object in the dictionary schema. The production path is a
-- dedicated owner: run this script once as SYSDBA (or a DBA holding CREATE
-- USER, GRANT ANY PRIVILEGE and GRANT ANY OBJECT PRIVILEGE), then install as
-- that owner. Not called by quickstart.sql.
--
-- Where to run it, and the default owner name:
--   CDB      in CDB$ROOT, where AWR lives. Creates a COMMON user, default
--            C##AWRCAP (the C## prefix is mandatory for a common user), and
--            grants with CONTAINER=ALL.
--   non-CDB  in the database. Default owner AWRCAP. No CONTAINER clause.
--   a PDB    a local user, default AWRCAP. Use this for fixture or warehouse
--            mode, or for PDB-level AWR.
--
-- Usage (every DEFINE is optional):
--   sqlplus / as sysdba
--   SQL> DEFINE owner       = C##AWRCAP   -- default by container, see above
--   SQL> DEFINE owner_pw    = secret      -- omitted: NO AUTHENTICATION
--   SQL> DEFINE owner_ts    = USERS       -- default: database default tablespace
--   SQL> DEFINE owner_quota = 1G          -- default 1G; UNLIMITED is allowed
--   SQL> @create_owner.sql
--
-- Without owner_pw the user is schema-only (NO AUTHENTICATION): nobody can log
-- in as it, and you install as SYSDBA with
--   ALTER SESSION SET CURRENT_SCHEMA = C##AWRCAP;
-- or give it a password later with ALTER USER ... IDENTIFIED BY. The password
-- may not contain a single or double quote.
--
-- What it grants, all DIRECT (views and the definer's-rights ML package
-- ignore privileges that arrive through a role):
--   system  CREATE SESSION / TABLE / VIEW / TYPE / PROCEDURE / MINING MODEL / JOB
--   object  SELECT on the fifteen DBA_HIST_* views ddl/10_seam_local.sql reads,
--           plus DBA_HIST_WR_CONTROL and V_$PARAMETER, which only doctor.sql
--           reads (retention, pack access, STATISTICS_LEVEL).
--   quota   owner_quota on owner_ts.
--
-- Idempotent: an existing user (ORA-01920) is kept as is, password and default
-- tablespace untouched; the quota and grants are re-applied. Exits non-zero if
-- any statement failed.
--
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET LINESIZE 200
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

-- Optional DEFINEs. A zero-row NEW_VALUE query defines an unset variable as
-- empty and leaves a set one alone, so nothing prompts. Distinct column
-- aliases, because COLUMN settings key on the alias for the whole session.
SET TERMOUT OFF
COLUMN cap_o_in  NEW_VALUE owner       NOPRINT
COLUMN cap_p_in  NEW_VALUE owner_pw    NOPRINT
COLUMN cap_t_in  NEW_VALUE owner_ts    NOPRINT
COLUMN cap_q_in  NEW_VALUE owner_quota NOPRINT
SELECT NULL AS cap_o_in, NULL AS cap_p_in, NULL AS cap_t_in, NULL AS cap_q_in
FROM   dual WHERE 1 = 0;

COLUMN cap_o_eff NEW_VALUE owner       NOPRINT
COLUMN cap_t_eff NEW_VALUE owner_ts    NOPRINT
COLUMN cap_q_eff NEW_VALUE owner_quota NOPRINT
SELECT UPPER(NVL('&owner',
                 CASE SYS_CONTEXT('USERENV', 'CON_ID')
                      WHEN '1' THEN 'C##AWRCAP' ELSE 'AWRCAP' END)) AS cap_o_eff,
       UPPER(NVL('&owner_ts',
                 (SELECT property_value FROM database_properties
                  WHERE  property_name = 'DEFAULT_PERMANENT_TABLESPACE')))  AS cap_t_eff,
       UPPER(NVL('&owner_quota', '1G'))                                    AS cap_q_eff
FROM   dual;
COLUMN cap_o_in  CLEAR
COLUMN cap_p_in  CLEAR
COLUMN cap_t_in  CLEAR
COLUMN cap_q_in  CLEAR
COLUMN cap_o_eff CLEAR
COLUMN cap_t_eff CLEAR
COLUMN cap_q_eff CLEAR
SET TERMOUT ON

PROMPT
PROMPT ============================================================
PROMPT  AWR Capacity Predictions -- create_owner
PROMPT ============================================================

DECLARE
    v_con    VARCHAR2(10)  := SYS_CONTEXT('USERENV', 'CON_ID');
    v_owner  VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME('&owner');
    v_pw     VARCHAR2(128) := '&owner_pw';
    v_ts     VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME('&owner_ts');
    v_quota  VARCHAR2(20)  := '&owner_quota';
    v_cont   VARCHAR2(20);
    v_fail   PLS_INTEGER   := 0;
    v_new    BOOLEAN       := TRUE;
    v_auth   VARCHAR2(30);

    TYPE t_list IS TABLE OF VARCHAR2(40);
    v_sys t_list := t_list(
        'CREATE SESSION', 'CREATE TABLE', 'CREATE VIEW', 'CREATE TYPE',
        'CREATE PROCEDURE', 'CREATE MINING MODEL', 'CREATE JOB');
    -- The first fifteen are exactly the FROM targets of ddl/10_seam_local.sql.
    v_obj t_list := t_list(
        'DBA_HIST_SNAPSHOT', 'DBA_HIST_TBSPC_SPACE_USAGE', 'DBA_HIST_TABLESPACE',
        'DBA_HIST_DATAFILE', 'DBA_HIST_OSSTAT', 'DBA_HIST_SYS_TIME_MODEL',
        'DBA_HIST_PDB_INSTANCE', 'DBA_HIST_DATABASE_INSTANCE',
        'DBA_HIST_RESOURCE_LIMIT', 'DBA_HIST_SYSSTAT',
        'DBA_HIST_CON_SYS_TIME_MODEL', 'DBA_HIST_CON_SYSSTAT',
        'DBA_HIST_PARAMETER', 'DBA_HIST_ASM_DISKGROUP_STAT', 'DBA_HIST_ASM_DISKGROUP',
        'DBA_HIST_WR_CONTROL', 'V_$PARAMETER');

    PROCEDURE run(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('  done    ' || p_sql);
    EXCEPTION
        WHEN OTHERS THEN
            v_fail := v_fail + 1;
            DBMS_OUTPUT.PUT_LINE('  FAILED  ' || p_sql);
            DBMS_OUTPUT.PUT_LINE('          ' || SQLERRM);
    END run;
BEGIN
    IF NOT REGEXP_LIKE(v_quota, '^([0-9]+[KMGT]?|UNLIMITED)$') THEN
        RAISE_APPLICATION_ERROR(-20001, 'owner_quota must look like 500M, 1G or UNLIMITED, not '
                                        || v_quota);
    END IF;
    IF v_con = '1' THEN
        IF v_owner NOT LIKE 'C##%' THEN
            RAISE_APPLICATION_ERROR(-20001, 'In CDB$ROOT the owner must be a common user'
                                            || ' with the C## prefix, not ' || v_owner);
        END IF;
        v_cont := ' CONTAINER=ALL';
    END IF;

    DBMS_OUTPUT.PUT_LINE('  owner      = ' || v_owner);
    DBMS_OUTPUT.PUT_LINE('  container  = ' || NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), '(non-CDB)')
                         || CASE WHEN v_cont IS NOT NULL THEN '  (common user, CONTAINER=ALL)' END);
    DBMS_OUTPUT.PUT_LINE('  tablespace = ' || v_ts || '  quota ' || v_quota);
    DBMS_OUTPUT.PUT_LINE(' ');

    BEGIN
        EXECUTE IMMEDIATE 'CREATE USER ' || v_owner
            || CASE WHEN v_pw IS NULL THEN ' NO AUTHENTICATION'
                    ELSE ' IDENTIFIED BY "' || v_pw || '"' END
            || ' DEFAULT TABLESPACE ' || v_ts || v_cont;
        DBMS_OUTPUT.PUT_LINE('  done    CREATE USER ' || v_owner
            || CASE WHEN v_pw IS NULL THEN ' NO AUTHENTICATION'
                    ELSE ' IDENTIFIED BY ********' END
            || ' DEFAULT TABLESPACE ' || v_ts || v_cont);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -1920 THEN
                v_new := FALSE;
                DBMS_OUTPUT.PUT_LINE('  exists  user ' || v_owner
                                     || ' (password and default tablespace left unchanged)');
            ELSE
                RAISE;
            END IF;
    END;

    run('ALTER USER ' || v_owner || ' QUOTA ' || v_quota || ' ON ' || v_ts);
    FOR i IN 1 .. v_sys.COUNT LOOP
        run('GRANT ' || v_sys(i) || ' TO ' || v_owner || v_cont);
    END LOOP;
    FOR i IN 1 .. v_obj.COUNT LOOP
        run('GRANT SELECT ON SYS.' || v_obj(i) || ' TO ' || v_owner || v_cont);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(' ');
    IF v_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20002, v_fail || ' statement(s) failed for owner '
                                        || v_owner || ' (see FAILED lines above).');
    END IF;
    DBMS_OUTPUT.PUT_LINE('  Owner ' || v_owner || ' is ready'
                         || CASE WHEN v_new THEN ' (created)' ELSE ' (already existed)' END
                         || '. Next, from the repo root:');
    BEGIN
        SELECT authentication_type INTO v_auth FROM dba_users WHERE username = v_owner;
    EXCEPTION
        WHEN OTHERS THEN v_auth := NULL;
    END;
    IF v_auth = 'NONE' THEN
        DBMS_OUTPUT.PUT_LINE('    ALTER SESSION SET CURRENT_SCHEMA = ' || v_owner || ';');
    ELSE
        DBMS_OUTPUT.PUT_LINE('    CONNECT ' || v_owner || '/<password>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('    @doctor.sql');
    DBMS_OUTPUT.PUT_LINE('    DEFINE seam_mode = local');
    DBMS_OUTPUT.PUT_LINE('    @install.sql');
END;
/

UNDEFINE owner_pw
WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
