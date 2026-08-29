--
-- doctor.sql -- preflight diagnostic for the AWR capacity-predictions suite.
-- =====================================================================
-- Answers, in one page, "will this suite actually produce forecasts for me,
-- and if not, why not?" -- BEFORE you run install.sql, and again afterwards.
--
-- Usage (any schema, any container -- run it where you intend to install):
--
--   sqlplus / as sysdba            -- or: sqlplus captest/...@pdb1
--   SQL> @doctor.sql
--
-- STRICTLY READ-ONLY. It creates nothing, drops nothing, writes nothing: it
-- only SELECTs from data dictionary views and prints a PASS/WARN/FAIL
-- checklist through DBMS_OUTPUT.
--
-- Note on the CAPV_* seam rule (CLAUDE.md): that rule says the ANALYTICS must
-- never touch DBA_HIST_* outside ddl/10_seam_local.sql, so local / warehouse /
-- fixture modes stay byte-identical downstream. doctor.sql is not analytics --
-- it is a preflight probe whose entire job is to test whether those base
-- objects are reachable, so it references them directly and on purpose. Every
-- such reference is dynamic (EXECUTE IMMEDIATE / ref cursor) precisely so a
-- missing object or a missing grant degrades to one WARN/FAIL line instead of
-- failing to compile the block.
--
-- Everything runs inside ONE anonymous block with per-check EXCEPTION
-- handlers, so no single privilege error can cut the checklist short.
--
SET DEFINE OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 200
SET TAB OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

DECLARE
    -- checklist tallies
    n_pass      PLS_INTEGER := 0;
    n_warn      PLS_INTEGER := 0;
    n_fail      PLS_INTEGER := 0;

    -- carried between checks so the closing summary can explain itself
    v_pack_ok       BOOLEAN     := FALSE;
    v_pack_known    BOOLEAN     := FALSE;
    v_seam_fails    PLS_INTEGER := 0;
    v_min_train     NUMBER      := 14;      -- CAP_CONFIG default if not installed
    v_min_train_src VARCHAR2(60) := 'built-in default';
    v_hist_days     NUMBER;                 -- best per-dbid snapshot day count
    v_short_hist    PLS_INTEGER := 0;       -- sources with < min_train_days
    v_retention_d   NUMBER;
    v_installed     BOOLEAN     := FALSE;
    v_seam_mode     VARCHAR2(30);           -- local | warehouse | fixture

    TYPE t_names IS TABLE OF VARCHAR2(30);
    v_views t_names := t_names(
        'DBA_HIST_SNAPSHOT',
        'DBA_HIST_TBSPC_SPACE_USAGE',
        'DBA_HIST_TABLESPACE',
        'DBA_HIST_DATAFILE',
        'DBA_HIST_OSSTAT',
        'DBA_HIST_SYS_TIME_MODEL',
        'DBA_HIST_PDB_INSTANCE',
        'DBA_HIST_DATABASE_INSTANCE');

    v_privs t_names := t_names(
        'CREATE TABLE',
        'CREATE VIEW',
        'CREATE PROCEDURE',
        'CREATE TYPE',
        'CREATE MINING MODEL',
        'CREATE JOB');

    PROCEDURE hdr(p_text IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(' ');
        DBMS_OUTPUT.PUT_LINE(p_text);
        DBMS_OUTPUT.PUT_LINE(RPAD('-', 74, '-'));
    END hdr;

    PROCEDURE note(p_text IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('         ' || p_text);
    END note;

    -- One checklist line. Counts toward the summary tallies.
    PROCEDURE emit(p_status IN VARCHAR2,
                   p_label  IN VARCHAR2,
                   p_detail IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        CASE p_status
            WHEN 'PASS' THEN n_pass := n_pass + 1;
            WHEN 'WARN' THEN n_warn := n_warn + 1;
            WHEN 'FAIL' THEN n_fail := n_fail + 1;
            ELSE NULL;
        END CASE;
        DBMS_OUTPUT.PUT_LINE('  [' || RPAD(p_status, 4) || '] '
                             || RPAD(p_label, 30) || ' ' || p_detail);
    END emit;

    -- SQLERRM trimmed to one readable line.
    FUNCTION err RETURN VARCHAR2 IS
    BEGIN
        RETURN SUBSTR(REPLACE(REPLACE(SQLERRM, CHR(10), ' '), CHR(13), ' '), 1, 90);
    END err;

    -- Count distinct AWR days behind a dynamic aggregate query. Returns NULL
    -- when the query cannot run (missing object / grant) and sets p_err.
    FUNCTION count_days(p_sql IN VARCHAR2, p_err OUT VARCHAR2) RETURN NUMBER IS
        v_n NUMBER;
    BEGIN
        EXECUTE IMMEDIATE p_sql INTO v_n;
        RETURN v_n;
    EXCEPTION
        WHEN OTHERS THEN
            p_err := err;
            RETURN NULL;
    END count_days;

    -- PASS when a source covers min_train_days, WARN otherwise.
    PROCEDURE report_days(p_label IN VARCHAR2, p_sql IN VARCHAR2) IS
        v_n   NUMBER;
        v_e   VARCHAR2(200);
    BEGIN
        v_n := count_days(p_sql, v_e);
        IF v_n IS NULL THEN
            emit('WARN', p_label, 'cannot read: ' || v_e);
        ELSIF v_n >= v_min_train THEN
            emit('PASS', p_label, v_n || ' days (need >= ' || TO_CHAR(v_min_train) || ')');
        ELSE
            v_short_hist := v_short_hist + 1;
            emit('WARN', p_label, 'only ' || v_n || ' days (need >= '
                                  || TO_CHAR(v_min_train) || ')');
        END IF;
    END report_days;

BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
    DBMS_OUTPUT.PUT_LINE(' AWR Capacity Predictions -- doctor.sql preflight');
    DBMS_OUTPUT.PUT_LINE(' ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
    note('session user    : ' || SYS_CONTEXT('USERENV', 'SESSION_USER'));
    note('current schema  : ' || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'));
    note('container       : ' || NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), '(non-CDB)'));
    note('database        : ' || SYS_CONTEXT('USERENV', 'DB_NAME')
                              || '  instance ' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME'));
    note('NOTE: privileges below are the SESSION USER''s. ALTER SESSION SET');
    note('      CURRENT_SCHEMA changes where objects resolve, not what you may do.');

    -- min_train_days drives several comparisons below; take it from CAP_CONFIG
    -- when the suite is already installed here, else the shipped default.
    BEGIN
        EXECUTE IMMEDIATE
            'SELECT cfg_value FROM cap_config WHERE cfg_name = ''min_train_days'''
            INTO v_min_train;
        v_min_train_src := 'CAP_CONFIG';
        v_installed := TRUE;
    EXCEPTION
        WHEN OTHERS THEN
            v_min_train     := 14;
            v_min_train_src := 'built-in default (CAP_CONFIG not readable)';
    END;

    -- =================================================================
    -- 1. Diagnostics Pack access
    -- =================================================================
    hdr(' 1. Diagnostics Pack (CONTROL_MANAGEMENT_PACK_ACCESS)');
    DECLARE
        v_val VARCHAR2(100);
        v_e   VARCHAR2(200);
    BEGIN
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT MAX(value) FROM v$parameter WHERE name = ' ||
                '''control_management_pack_access'''
                INTO v_val;
        EXCEPTION
            WHEN OTHERS THEN
                v_e := err;
                -- fall back to the system-wide view, then to the session context
                BEGIN
                    EXECUTE IMMEDIATE
                        'SELECT MAX(value) FROM v$system_parameter WHERE name = ' ||
                        '''control_management_pack_access'''
                        INTO v_val;
                    v_e := NULL;
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
        END;

        IF v_val IS NOT NULL THEN
            v_pack_known := TRUE;
            IF INSTR(UPPER(v_val), 'DIAGNOSTIC') > 0 THEN
                v_pack_ok := TRUE;
                emit('PASS', 'pack access', v_val);
            ELSE
                emit('FAIL', 'pack access', v_val
                     || ' -- AWR is not licensed/enabled; DBA_HIST_* will be empty');
            END IF;
        ELSE
            emit('WARN', 'pack access',
                 'cannot read v$parameter (' || NVL(v_e, 'no row') || ')');
        END IF;
    END;

    -- =================================================================
    -- 2. Direct SELECT on every DBA_HIST_* view the local seam needs
    -- =================================================================
    hdr(' 2. DBA_HIST_* readable (local seam; direct grant, not via a role)');
    FOR i IN 1 .. v_views.COUNT LOOP
        DECLARE
            v_n NUMBER;
        BEGIN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v_views(i)
                              || ' WHERE ROWNUM = 1' INTO v_n;
            emit('PASS', v_views(i),
                 CASE WHEN v_n > 0 THEN 'readable, has rows' ELSE 'readable, EMPTY' END);
        EXCEPTION
            WHEN OTHERS THEN
                v_seam_fails := v_seam_fails + 1;
                emit('FAIL', v_views(i), err);
        END;
    END LOOP;
    IF v_seam_fails > 0 THEN
        note('Local mode needs a DIRECT grant (roles are not visible inside a view):');
        note('  GRANT SELECT ON <view> TO <schema>;   -- for each FAIL above');
        note('Warehouse / fixture mode do not need these.');
    END IF;

    -- =================================================================
    -- 3. Object-creation privileges
    -- =================================================================
    hdr(' 3. Privileges to install (SESSION_PRIVS of the session user)');
    FOR i IN 1 .. v_privs.COUNT LOOP
        DECLARE
            v_n NUMBER := 0;
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM session_privs WHERE privilege = :p'
                INTO v_n USING v_privs(i);
            IF v_n > 0 THEN
                emit('PASS', v_privs(i), 'granted');
            ELSIF v_privs(i) = 'CREATE MINING MODEL' THEN
                emit('WARN', v_privs(i),
                     'missing -- Tier 2 ESM (ml/) will fail at train time; Tier 1 is fine');
            ELSIF v_privs(i) = 'CREATE JOB' THEN
                emit('WARN', v_privs(i), 'missing -- install_jobs.sql cannot create jobs');
            ELSE
                emit('FAIL', v_privs(i), 'missing -- install.sql cannot create its objects');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                emit('WARN', v_privs(i), 'cannot read SESSION_PRIVS: ' || err);
        END;
    END LOOP;

    -- =================================================================
    -- 4. AWR retention + snapshot interval
    -- =================================================================
    hdr(' 4. AWR retention / interval (DBA_HIST_WR_CONTROL)');
    DECLARE
        v_cur   SYS_REFCURSOR;
        v_dbid  NUMBER;
        v_ret   NUMBER;          -- retention, minutes
        v_int   NUMBER;          -- snap_interval, minutes
        v_days  NUMBER;
        v_need  NUMBER := v_min_train + 1;
        v_rows  PLS_INTEGER := 0;
    BEGIN
        -- One row per dbid. In a PDB you see both the PDB's row and the CDB's,
        -- so report each rather than aggregating them into one misleading number.
        OPEN v_cur FOR
            'SELECT dbid,'
            || ' EXTRACT(DAY FROM retention) * 1440'
            || ' + EXTRACT(HOUR FROM retention) * 60'
            || ' + EXTRACT(MINUTE FROM retention),'
            || ' EXTRACT(DAY FROM snap_interval) * 1440'
            || ' + EXTRACT(HOUR FROM snap_interval) * 60'
            || ' + EXTRACT(MINUTE FROM snap_interval)'
            || ' FROM dba_hist_wr_control ORDER BY dbid';
        LOOP
            FETCH v_cur INTO v_dbid, v_ret, v_int;
            EXIT WHEN v_cur%NOTFOUND OR v_rows >= 10;
            v_rows := v_rows + 1;

            v_days := ROUND(v_ret / 1440, 1);
            -- worst (smallest) retention seen drives the closing summary
            v_retention_d := LEAST(NVL(v_retention_d, v_days), v_days);

            IF v_days >= v_need THEN
                emit('PASS', 'retention dbid ' || v_dbid,
                     v_days || ' days (need >= ' || TO_CHAR(v_need) || ')');
            ELSE
                emit('WARN', 'retention dbid ' || v_dbid,
                     v_days || ' days -- below min_train_days+1 (' || TO_CHAR(v_need)
                     || '); forecasts stay INSUFFICIENT_HISTORY');
                note('  EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS('
                     || 'retention => ' || TO_CHAR(v_need * 1440) || ');');
            END IF;

            -- 40150 days is Oracle's "not set here" sentinel: a PDB that has
            -- never had its own settings inherits CDB$ROOT's interval.
            IF v_int IS NULL THEN
                NULL;
            ELSIF v_int >= 40150 * 1440 THEN
                emit('PASS', 'interval dbid ' || v_dbid,
                     'not set in this container (inherits CDB$ROOT)');
            ELSIF v_int = 0 THEN
                emit('FAIL', 'interval dbid ' || v_dbid,
                     'snapshots are DISABLED (interval 0)');
            ELSIF v_int <= 60 THEN
                emit('PASS', 'interval dbid ' || v_dbid, v_int || ' min');
            ELSE
                emit('WARN', 'interval dbid ' || v_dbid,
                     v_int || ' min -- coarse; daily peaks (p95/max) lose resolution');
            END IF;
        END LOOP;
        CLOSE v_cur;

        IF v_rows = 0 THEN
            emit('WARN', 'retention', 'no DBA_HIST_WR_CONTROL row');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            emit('WARN', 'DBA_HIST_WR_CONTROL', 'cannot read: ' || err);
    END;

    -- =================================================================
    -- 5. How much history each source actually has
    -- =================================================================
    hdr(' 5. History available per source (vs min_train_days = '
        || TO_CHAR(v_min_train) || ', from ' || v_min_train_src || ')');
    DECLARE
        v_cur   SYS_REFCURSOR;
        v_dbid  NUMBER;
        v_days  NUMBER;
        v_from  VARCHAR2(20);
        v_to    VARCHAR2(20);
        v_rows  PLS_INTEGER := 0;
    BEGIN
        OPEN v_cur FOR
            'SELECT dbid, COUNT(DISTINCT TRUNC(end_interval_time)),'
            || ' TO_CHAR(MIN(end_interval_time), ''YYYY-MM-DD''),'
            || ' TO_CHAR(MAX(end_interval_time), ''YYYY-MM-DD'')'
            || ' FROM dba_hist_snapshot GROUP BY dbid ORDER BY 2 DESC';
        LOOP
            FETCH v_cur INTO v_dbid, v_days, v_from, v_to;
            EXIT WHEN v_cur%NOTFOUND OR v_rows >= 10;
            v_rows := v_rows + 1;
            v_hist_days := GREATEST(NVL(v_hist_days, 0), v_days);
            IF v_days >= v_min_train THEN
                emit('PASS', 'snapshots dbid ' || v_dbid,
                     v_days || ' days (' || v_from || ' .. ' || v_to || ')');
            ELSE
                v_short_hist := v_short_hist + 1;
                emit('WARN', 'snapshots dbid ' || v_dbid,
                     'only ' || v_days || ' days (' || v_from || ' .. ' || v_to || ')');
            END IF;
        END LOOP;
        CLOSE v_cur;
        IF v_rows = 0 THEN
            emit('WARN', 'snapshots', 'no rows in DBA_HIST_SNAPSHOT');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            emit('WARN', 'snapshots', 'cannot read: ' || err);
    END;

    report_days('tablespace usage',
        'SELECT COUNT(DISTINCT TRUNC(s.end_interval_time))'
        || ' FROM dba_hist_tbspc_space_usage u, dba_hist_snapshot s'
        || ' WHERE s.snap_id = u.snap_id AND s.dbid = u.dbid');

    report_days('host CPU (OSSTAT BUSY)',
        'SELECT COUNT(DISTINCT TRUNC(s.end_interval_time))'
        || ' FROM dba_hist_osstat o, dba_hist_snapshot s'
        || ' WHERE s.snap_id = o.snap_id AND s.dbid = o.dbid'
        || ' AND s.instance_number = o.instance_number'
        || ' AND o.stat_name = ''BUSY_TIME''');

    report_days('DB CPU (time model)',
        'SELECT COUNT(DISTINCT TRUNC(s.end_interval_time))'
        || ' FROM dba_hist_sys_time_model t, dba_hist_snapshot s'
        || ' WHERE s.snap_id = t.snap_id AND s.dbid = t.dbid'
        || ' AND s.instance_number = t.instance_number'
        || ' AND t.stat_name = ''DB CPU''');

    -- =================================================================
    -- 6. Installed-suite health (only meaningful once install.sql has run)
    -- =================================================================
    hdr(' 6. Suite install state (current schema: '
        || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') || ')');
    IF NOT v_installed THEN
        emit('WARN', 'CAP_CONFIG', 'not present -- suite not installed here yet');
    ELSE
        emit('PASS', 'CAP_CONFIG', 'present');

        -- Invalid CAP* objects. NOTE: USER_OBJECTS / USER_DEPENDENCIES follow the
        -- SESSION USER, not CURRENT_SCHEMA (verified on 19c: with SYS connected
        -- and CURRENT_SCHEMA=CAPTEST, USER_OBJECTS shows none of CAPTEST's
        -- objects). So filter ALL_* on owner = CURRENT_SCHEMA instead, which is
        -- where install.sql actually put things.
        DECLARE
            v_bad   PLS_INTEGER := 0;
            v_list  VARCHAR2(300);
        BEGIN
            FOR r IN (SELECT object_name, object_type
                      FROM   all_objects
                      WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
                        AND  status = 'INVALID'
                        AND  object_name LIKE 'CAP%'
                      ORDER BY object_name) LOOP
                v_bad  := v_bad + 1;
                v_list := SUBSTR(v_list || CASE WHEN v_list IS NULL THEN '' ELSE ', ' END
                                 || r.object_name, 1, 300);
            END LOOP;
            IF v_bad = 0 THEN
                emit('PASS', 'CAP* objects', 'all valid');
            ELSE
                emit('FAIL', 'CAP* objects', v_bad || ' INVALID: ' || v_list);
            END IF;
        END;

        -- seam mode, inferred from what CAPV_SNAPSHOT actually depends on
        DECLARE
            v_mode  VARCHAR2(30) := NULL;
            v_refs  VARCHAR2(200);
        BEGIN
            FOR r IN (SELECT referenced_name
                      FROM   all_dependencies
                      WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
                        AND  name = 'CAPV_SNAPSHOT'
                        AND  type = 'VIEW') LOOP
                v_refs := SUBSTR(v_refs || r.referenced_name || ' ', 1, 200);
                IF    r.referenced_name = 'DBA_HIST_SNAPSHOT'      THEN v_mode := 'local';
                ELSIF r.referenced_name LIKE 'AWRV\_%' ESCAPE '\'  THEN v_mode := 'warehouse';
                ELSIF r.referenced_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\' THEN v_mode := 'fixture';
                END IF;
            END LOOP;

            IF v_mode IS NULL AND v_refs IS NULL THEN
                emit('WARN', 'seam mode', 'CAPV_SNAPSHOT not found in this schema');
            ELSIF v_mode IS NULL THEN
                emit('WARN', 'seam mode', 'unrecognised: ' || v_refs);
            ELSE
                v_seam_mode := v_mode;
                emit('PASS', 'seam mode', v_mode || '  (CAPV_SNAPSHOT -> ' || v_refs || ')');
                IF v_mode = 'local' AND v_seam_fails > 0 THEN
                    note('Local seam installed but ' || v_seam_fails
                         || ' DBA_HIST_* view(s) unreadable by this session.');
                END IF;
            END IF;
        END;
    END IF;

    -- =================================================================
    -- 7. Summary
    -- =================================================================
    hdr(' Summary');
    DBMS_OUTPUT.PUT_LINE('  ' || n_pass || ' PASS / ' || n_warn || ' WARN / '
                         || n_fail || ' FAIL');

    IF v_pack_known AND NOT v_pack_ok THEN
        note('Forecasts will be empty: CONTROL_MANAGEMENT_PACK_ACCESS excludes');
        note('DIAGNOSTIC, so AWR collects nothing to fit.');
    END IF;
    IF v_seam_fails > 0 THEN
        note('Local-mode install would leave CAPV_* invalid: ' || v_seam_fails
             || ' DBA_HIST_* view(s) not readable by this session.');
    END IF;
    IF v_seam_mode IN ('warehouse', 'fixture') THEN
        note('Seam mode here is ' || v_seam_mode || ', so checks 2 and 5 (DBA_HIST_*)');
        note('do not apply to this install -- the data comes from '
             || CASE v_seam_mode WHEN 'warehouse' THEN 'the AWRV_* views.'
                                 ELSE 'CAP_FIXTURE_* tables.' END);
    END IF;
    IF v_short_hist > 0 THEN
        note('Why forecasts may say INSUFFICIENT_HISTORY:');
        note('  ' || v_short_hist || ' source(s) hold fewer than min_train_days ('
             || TO_CHAR(v_min_train) || ') distinct days.');
        note('  A fit needs that many daily points, so those series stay quiet');
        note('  until AWR has accumulated them. Re-run doctor.sql later.');
    END IF;
    IF v_retention_d IS NOT NULL AND v_hist_days IS NOT NULL
       AND v_retention_d < v_min_train + 1 THEN
        note('Retention (' || v_retention_d || ' d) caps history below the training');
        note('window, so history can never reach min_train_days.');
    END IF;
    IF n_fail = 0 AND n_warn = 0 THEN
        note('All green -- install.sql should produce usable forecasts.');
    END IF;
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
END;
/

SET FEEDBACK ON
