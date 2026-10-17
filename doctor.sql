--
-- doctor.sql -- preflight diagnostic for the AWR capacity-predictions suite.
-- =====================================================================
-- Answers, in one page, "will this suite actually produce forecasts for me,
-- and if not, why not?" -- BEFORE you run install.sql, and again afterwards.
--
-- Usage (any schema, any container -- run it where you intend to install):
--
--   sqlplus / as sysdba            -- or: sqlplus c##awrcap/...
--   SQL> @doctor.sql
--
-- STRICTLY READ-ONLY. It creates nothing, drops nothing, writes nothing: it
-- only SELECTs from data dictionary views (and, once installed, the suite's
-- own CAP_CONFIG / CAPV_ / CAPF_ views) and prints a PASS/WARN/FAIL checklist
-- through DBMS_OUTPUT.
--
-- It leaves one SQL*Plus variable behind for callers: cap_doctor_fail, the
-- number of FAIL lines ("1" if the block did not finish). quickstart.sql stops
-- before install when it is not 0.
--
-- The DBA_HIST_* checks count only when the install reads DBA_HIST_* (local
-- mode). Doctor takes the mode from the installed CAPV_SNAPSHOT, assumes local
-- before install, and lets a caller say which install it is about to run:
--   SQL> DEFINE cap_doctor_mode = fixture     -- local | warehouse | fixture
--   SQL> @doctor.sql
-- quickstart.sql sets it to local.
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
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 200
SET TAB OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

VARIABLE cap_doctor_fail_n NUMBER
VARIABLE cap_doctor_mode_v VARCHAR2(30)

-- Optional cap_doctor_mode, read without prompting: a zero-row NEW_VALUE
-- query defines an unset variable as empty and leaves a set one alone.
SET DEFINE '&'
SET TERMOUT OFF
COLUMN cap_mode_in NEW_VALUE cap_doctor_mode NOPRINT
SELECT NULL AS cap_mode_in FROM dual WHERE 1 = 0;
COLUMN cap_mode_in CLEAR
SET TERMOUT ON
EXEC :cap_doctor_mode_v := LOWER(TRIM('&cap_doctor_mode'))
SET DEFINE OFF

DECLARE
    -- checklist tallies
    n_pass      PLS_INTEGER := 0;
    n_warn      PLS_INTEGER := 0;
    n_fail      PLS_INTEGER := 0;

    v_schema    VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_session   VARCHAR2(128) := SYS_CONTEXT('USERENV', 'SESSION_USER');

    -- carried between checks so the closing summary can explain itself
    v_pack_ok       BOOLEAN     := FALSE;
    v_pack_known    BOOLEAN     := FALSE;
    v_seam_fails    PLS_INTEGER := 0;
    v_grant_missing PLS_INTEGER := 0;
    v_hist_days     NUMBER;                 -- best per-dbid snapshot day count
    v_short_hist    PLS_INTEGER := 0;       -- sources with < min_train_days
    v_retention_d   NUMBER;
    v_installed     BOOLEAN     := FALSE;
    v_seam_mode     VARCHAR2(30);           -- local | warehouse | fixture
    v_seam_refs     VARCHAR2(200);
    v_hist_applies  BOOLEAN     := TRUE;    -- FALSE in fixture / warehouse mode
    v_intended      VARCHAR2(30) := :cap_doctor_mode_v;   -- caller's DEFINE, or NULL

    -- knobs: CAP_CFG when installed, else the shipped defaults (05_config)
    v_knob_src      VARCHAR2(60) := 'shipped defaults (suite not installed here)';
    v_train         NUMBER := 90;
    v_min_train     NUMBER := 14;
    v_dow_weeks     NUMBER := 8;
    v_shift_days    NUMBER := 7;
    v_shift_base    NUMBER := 28;
    v_holdout       NUMBER := 28;
    v_esm_step      NUMBER := 30;

    TYPE t_names IS TABLE OF VARCHAR2(40);
    -- Exactly the FROM targets of ddl/10_seam_local.sql.
    v_views t_names := t_names(
        'DBA_HIST_SNAPSHOT',
        'DBA_HIST_TBSPC_SPACE_USAGE',
        'DBA_HIST_TABLESPACE',
        'DBA_HIST_DATAFILE',
        'DBA_HIST_OSSTAT',
        'DBA_HIST_SYS_TIME_MODEL',
        'DBA_HIST_PDB_INSTANCE',
        'DBA_HIST_DATABASE_INSTANCE',
        'DBA_HIST_RESOURCE_LIMIT',
        'DBA_HIST_SYSSTAT',
        'DBA_HIST_CON_SYS_TIME_MODEL',
        'DBA_HIST_CON_SYSSTAT',
        'DBA_HIST_PARAMETER',
        'DBA_HIST_ASM_DISKGROUP_STAT',
        'DBA_HIST_ASM_DISKGROUP');

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

    PROCEDURE tally(p_status IN VARCHAR2) IS
    BEGIN
        CASE p_status
            WHEN 'PASS' THEN n_pass := n_pass + 1;
            WHEN 'WARN' THEN n_warn := n_warn + 1;
            WHEN 'FAIL' THEN n_fail := n_fail + 1;
            ELSE NULL;      -- INFO lines do not count
        END CASE;
    END tally;

    -- One checklist line. Counts toward the summary tallies.
    PROCEDURE emit(p_status IN VARCHAR2,
                   p_label  IN VARCHAR2,
                   p_detail IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        tally(p_status);
        DBMS_OUTPUT.PUT_LINE('  [' || RPAD(p_status, 4) || '] '
                             || RPAD(p_label, 30) || ' ' || p_detail);
    END emit;

    -- Checks on DBA_HIST_* only count when the install reads them (local
    -- mode, or not installed yet); otherwise they print as INFO.
    FUNCTION hst(p_status IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN v_hist_applies THEN p_status ELSE 'INFO' END;
    END hst;

    -- SQLERRM trimmed to one readable line.
    FUNCTION err RETURN VARCHAR2 IS
    BEGIN
        RETURN SUBSTR(REPLACE(REPLACE(SQLERRM, CHR(10), ' '), CHR(13), ' '), 1, 90);
    END err;

    -- A knob read through CAP_CFG, or NULL when the knob or the view is missing.
    FUNCTION knob_raw(p_name IN VARCHAR2) RETURN NUMBER IS
        v_n NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT ' || DBMS_ASSERT.SIMPLE_SQL_NAME(p_name) || ' FROM cap_cfg'
            INTO v_n;
        RETURN v_n;
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END knob_raw;

    FUNCTION knob(p_name IN VARCHAR2, p_default IN NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN NVL(knob_raw(p_name), p_default);
    END knob;

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
            emit(hst('WARN'), p_label, 'cannot read: ' || v_e);
        ELSIF v_n >= v_min_train THEN
            emit(hst('PASS'), p_label, v_n || ' days (need >= ' || TO_CHAR(v_min_train) || ')');
        ELSE
            v_short_hist := v_short_hist + 1;
            emit(hst('WARN'), p_label, 'only ' || v_n || ' days (need >= '
                                  || TO_CHAR(v_min_train) || ')');
        END IF;
    END report_days;

    -- Does the current schema hold p_priv on SYS.p_obj DIRECTLY? 1 yes, 0 no,
    -- NULL when no dictionary view we can read answers the question.
    FUNCTION direct_obj_grant(p_obj IN VARCHAR2) RETURN NUMBER IS
        v_n NUMBER;
    BEGIN
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM dba_tab_privs WHERE grantee = :g'
                || ' AND owner = ''SYS'' AND table_name = :t'
                || ' AND privilege IN (''SELECT'', ''READ'')'
                INTO v_n USING v_schema, p_obj;
        EXCEPTION
            WHEN OTHERS THEN
                EXECUTE IMMEDIATE
                    'SELECT COUNT(*) FROM all_tab_privs WHERE grantee = :g'
                    || ' AND table_schema = ''SYS'' AND table_name = :t'
                    || ' AND privilege IN (''SELECT'', ''READ'')'
                    INTO v_n USING v_schema, p_obj;
        END;
        RETURN SIGN(v_n);
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END direct_obj_grant;

    -- Same for a system privilege granted directly to the current schema.
    FUNCTION direct_sys_priv(p_priv IN VARCHAR2) RETURN NUMBER IS
        v_n NUMBER;
    BEGIN
        BEGIN
            EXECUTE IMMEDIATE
                'SELECT COUNT(*) FROM dba_sys_privs WHERE grantee = :g AND privilege = :p'
                INTO v_n USING v_schema, p_priv;
        EXCEPTION
            WHEN OTHERS THEN
                IF v_schema <> v_session THEN
                    RETURN NULL;
                END IF;
                EXECUTE IMMEDIATE
                    'SELECT COUNT(*) FROM user_sys_privs WHERE privilege = :p'
                    INTO v_n USING p_priv;
        END;
        RETURN SIGN(v_n);
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END direct_sys_priv;

BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
    DBMS_OUTPUT.PUT_LINE(' AWR Capacity Predictions -- doctor.sql preflight');
    DBMS_OUTPUT.PUT_LINE(' ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));
    note('session user    : ' || v_session);
    note('current schema  : ' || v_schema);
    note('container       : ' || NVL(SYS_CONTEXT('USERENV', 'CON_NAME'), '(non-CDB)'));
    note('database        : ' || SYS_CONTEXT('USERENV', 'DB_NAME')
                              || '  instance ' || SYS_CONTEXT('USERENV', 'INSTANCE_NAME'));
    note('NOTE: probes and SESSION_PRIVS below are the SESSION USER''s. ALTER SESSION');
    note('      SET CURRENT_SCHEMA changes where objects resolve, not what you may do;');
    note('      the direct-grant checks look at the current schema itself.');
    IF v_intended IS NOT NULL THEN
        note('mode under test : ' || v_intended || ' (DEFINE cap_doctor_mode)');
    END IF;

    -- Installed here? Then the knobs come from CAP_CFG and the seam mode is
    -- inferred from what CAPV_SNAPSHOT actually depends on.
    DECLARE
        v_rows NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM cap_config' INTO v_rows;
        v_installed  := TRUE;
        v_knob_src   := 'CAP_CFG';
    EXCEPTION
        WHEN OTHERS THEN v_installed := FALSE;
    END;
    IF v_installed THEN
        v_train      := knob('train_days',            v_train);
        v_min_train  := knob('min_train_days',        v_min_train);
        v_dow_weeks  := knob('dow_weeks',             v_dow_weeks);
        v_shift_days := knob('shift_days',            v_shift_days);
        v_shift_base := knob('shift_baseline_days',   v_shift_base);
        v_holdout    := knob('backtest_holdout_days', v_holdout);
        v_esm_step   := knob('esm_prediction_step',   v_esm_step);

        FOR r IN (SELECT referenced_name
                  FROM   all_dependencies
                  WHERE  owner = v_schema
                    AND  name  = 'CAPV_SNAPSHOT'
                    AND  type  = 'VIEW') LOOP
            v_seam_refs := SUBSTR(v_seam_refs || r.referenced_name || ' ', 1, 200);
            IF    r.referenced_name = 'DBA_HIST_SNAPSHOT'      THEN v_seam_mode := 'local';
            ELSIF r.referenced_name LIKE 'AWRV\_%' ESCAPE '\'  THEN v_seam_mode := 'warehouse';
            ELSIF r.referenced_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\' THEN v_seam_mode := 'fixture';
            END IF;
        END LOOP;
    END IF;
    IF v_intended NOT IN ('local', 'warehouse', 'fixture') THEN
        v_intended := NULL;
    END IF;
    v_hist_applies := COALESCE(v_intended, v_seam_mode, 'local') = 'local';

    -- =================================================================
    -- 1. Target schema
    -- =================================================================
    hdr(' 1. Target schema (where install.sql would create objects)');
    IF v_schema = 'SYS' THEN
        emit('WARN', 'current schema', 'SYS -- every CAP* object would be owned by SYS');
        note('Works (the quickstart does it), but a dedicated owner is the production');
        note('path: run @create_owner.sql as SYSDBA, then install as that user.');
    ELSE
        emit('PASS', 'current schema', v_schema);
    END IF;

    -- =================================================================
    -- 2. Database settings that decide whether AWR collects anything
    -- =================================================================
    hdr(' 2. Database settings (CONTROL_MANAGEMENT_PACK_ACCESS, STATISTICS_LEVEL)');
    DECLARE
        v_val VARCHAR2(100);
        v_e   VARCHAR2(200);

        FUNCTION param(p_name IN VARCHAR2) RETURN VARCHAR2 IS
            v_v VARCHAR2(100);
        BEGIN
            BEGIN
                EXECUTE IMMEDIATE
                    'SELECT MAX(value) FROM v$parameter WHERE name = :n' INTO v_v USING p_name;
            EXCEPTION
                WHEN OTHERS THEN
                    v_e := err;
                    EXECUTE IMMEDIATE
                        'SELECT MAX(value) FROM v$system_parameter WHERE name = :n'
                        INTO v_v USING p_name;
                    v_e := NULL;
            END;
            RETURN v_v;
        EXCEPTION
            WHEN OTHERS THEN RETURN NULL;
        END param;
    BEGIN
        v_val := param('control_management_pack_access');
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

        v_e   := NULL;
        v_val := param('statistics_level');
        IF v_val IS NULL THEN
            emit('WARN', 'statistics_level',
                 'cannot read v$parameter (' || NVL(v_e, 'no row') || ')');
        ELSIF UPPER(v_val) = 'BASIC' THEN
            emit('FAIL', 'statistics_level', 'BASIC -- AWR takes no automatic snapshots');
        ELSE
            emit('PASS', 'statistics_level', v_val);
        END IF;
    END;

    -- =================================================================
    -- 3. DBA_HIST_* views the local seam reads
    -- =================================================================
    hdr(' 3. DBA_HIST_* readable (local seam, ' || v_views.COUNT || ' views)');
    IF NOT v_hist_applies THEN
        note('Seam mode is ' || COALESCE(v_intended, v_seam_mode)
             || ': these views are not used, so these lines are INFO.');
    END IF;
    FOR i IN 1 .. v_views.COUNT LOOP
        DECLARE
            v_n NUMBER;
        BEGIN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || v_views(i)
                              || ' WHERE ROWNUM = 1' INTO v_n;
            emit(hst('PASS'), v_views(i),
                 CASE WHEN v_n > 0 THEN 'readable, has rows' ELSE 'readable, EMPTY' END);
        EXCEPTION
            WHEN OTHERS THEN
                v_seam_fails := v_seam_fails + 1;
                emit(hst('FAIL'), v_views(i), err);
        END;
    END LOOP;

    -- The probes above run with the session user's privileges, roles
    -- included. The seam views compile with the OWNER's direct grants only.
    IF v_schema <> 'SYS' THEN
        DECLARE
            v_any     NUMBER := direct_sys_priv('SELECT ANY DICTIONARY');
            v_g       NUMBER;
            v_unknown PLS_INTEGER := 0;
            v_list    VARCHAR2(400);
        BEGIN
            IF v_any = 1 THEN
                emit(hst('PASS'), 'direct grants', v_schema
                     || ' holds SELECT ANY DICTIONARY directly');
            ELSE
                FOR i IN 1 .. v_views.COUNT LOOP
                    v_g := direct_obj_grant(v_views(i));
                    IF v_g IS NULL THEN
                        v_unknown := v_unknown + 1;
                    ELSIF v_g = 0 THEN
                        v_grant_missing := v_grant_missing + 1;
                        v_list := SUBSTR(v_list || CASE WHEN v_list IS NOT NULL THEN ', ' END
                                         || REPLACE(v_views(i), 'DBA_HIST_'), 1, 400);
                    END IF;
                END LOOP;
                IF v_unknown > 0 THEN
                    emit(hst('WARN'), 'direct grants', 'cannot read DBA_TAB_PRIVS / ALL_TAB_PRIVS for '
                         || v_schema);
                ELSIF v_grant_missing = 0 THEN
                    emit(hst('PASS'), 'direct grants', 'all ' || v_views.COUNT
                         || ' granted directly to ' || v_schema);
                ELSE
                    emit(hst('FAIL'),
                         'direct grants', v_schema || ' lacks a direct grant on '
                         || v_grant_missing || ' of ' || v_views.COUNT);
                    note('missing DBA_HIST_: ' || v_list);
                    note('A grant through a role (SELECT_CATALOG_ROLE, DBA) will not do: views');
                    note('and definer''s-rights PL/SQL see only direct grants. Fix with');
                    note('@create_owner.sql, or GRANT SELECT ON SYS.<view> TO ' || v_schema || ';');
                END IF;
            END IF;
        END;
    END IF;
    IF v_seam_fails > 0 AND v_hist_applies THEN
        note('Local mode needs every view above readable by the owning schema.');
        note('Warehouse / fixture mode do not need them.');
    END IF;

    -- =================================================================
    -- 4. Object-creation privileges
    -- =================================================================
    hdr(' 4. Privileges to install (SESSION_PRIVS of the session user)');
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
    -- cap_forecast_ml is definer's rights: it creates models with the
    -- owner's DIRECT privileges, whoever installed it.
    IF v_schema <> 'SYS' THEN
        DECLARE
            v_g NUMBER := direct_sys_priv('CREATE MINING MODEL');
        BEGIN
            IF v_g IS NULL THEN
                emit('WARN', 'direct MINING MODEL', 'cannot read DBA_SYS_PRIVS for ' || v_schema);
            ELSIF v_g = 1 THEN
                emit('PASS', 'direct MINING MODEL', 'granted directly to ' || v_schema);
            ELSE
                emit('WARN', 'direct MINING MODEL', v_schema
                     || ' lacks a direct CREATE MINING MODEL; Tier 2 training will fail');
            END IF;
        END;
    END IF;

    -- =================================================================
    -- 5. AWR retention + snapshot interval
    -- =================================================================
    hdr(' 5. AWR retention / interval (DBA_HIST_WR_CONTROL, vs train_days = '
        || TO_CHAR(v_train) || ')');
    DECLARE
        v_cur   SYS_REFCURSOR;
        v_dbid  NUMBER;
        v_ret   NUMBER;          -- retention, minutes
        v_int   NUMBER;          -- snap_interval, minutes
        v_days  NUMBER;
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

            IF v_days >= v_train THEN
                emit(hst('PASS'), 'retention dbid ' || v_dbid,
                     v_days || ' days (need >= train_days ' || TO_CHAR(v_train) || ')');
            ELSE
                emit(hst('WARN'), 'retention dbid ' || v_dbid,
                     v_days || ' days -- below train_days (' || TO_CHAR(v_train) || ')'
                     || CASE WHEN v_days < v_min_train + 1
                             THEN '; forecasts stay INSUFFICIENT_HISTORY'
                             ELSE '; the training window can never fill' END);
                note('  EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS('
                     || 'retention => ' || TO_CHAR(v_train * 1440) || ');');
            END IF;

            -- 40150 days is Oracle's "not set here" sentinel: a PDB that has
            -- never had its own settings inherits CDB$ROOT's interval.
            IF v_int IS NULL THEN
                NULL;
            ELSIF v_int >= 40150 * 1440 THEN
                emit(hst('PASS'), 'interval dbid ' || v_dbid,
                     'not set in this container (inherits CDB$ROOT)');
            ELSIF v_int = 0 THEN
                emit(hst('FAIL'), 'interval dbid ' || v_dbid,
                     'snapshots are DISABLED (interval 0)');
            ELSIF v_int <= 60 THEN
                emit(hst('PASS'), 'interval dbid ' || v_dbid, v_int || ' min');
            ELSE
                emit(hst('WARN'), 'interval dbid ' || v_dbid,
                     v_int || ' min -- coarse; daily peaks (p95/max) lose resolution');
            END IF;
        END LOOP;
        CLOSE v_cur;

        IF v_rows = 0 THEN
            emit(hst('WARN'), 'retention', 'no DBA_HIST_WR_CONTROL row');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            emit(hst('WARN'), 'DBA_HIST_WR_CONTROL', 'cannot read: ' || err);
    END;

    -- =================================================================
    -- 6. How much history each source actually has, and how fresh it is
    -- =================================================================
    hdr(' 6. History available per source (vs min_train_days = '
        || TO_CHAR(v_min_train) || ', from ' || v_knob_src || ')');
    DECLARE
        v_cur   SYS_REFCURSOR;
        v_dbid  NUMBER;
        v_days  NUMBER;
        v_from  VARCHAR2(20);
        v_to    VARCHAR2(20);
        v_age   NUMBER;          -- hours since the newest snapshot ended
        v_rows  PLS_INTEGER := 0;
    BEGIN
        OPEN v_cur FOR
            'SELECT dbid, COUNT(DISTINCT TRUNC(end_interval_time)),'
            || ' TO_CHAR(MIN(end_interval_time), ''YYYY-MM-DD''),'
            || ' TO_CHAR(MAX(end_interval_time), ''YYYY-MM-DD HH24:MI''),'
            || ' ROUND((SYSDATE - CAST(MAX(end_interval_time) AS DATE)) * 24, 1)'
            || ' FROM dba_hist_snapshot GROUP BY dbid ORDER BY 2 DESC';
        LOOP
            FETCH v_cur INTO v_dbid, v_days, v_from, v_to, v_age;
            EXIT WHEN v_cur%NOTFOUND OR v_rows >= 10;
            v_rows := v_rows + 1;
            v_hist_days := GREATEST(NVL(v_hist_days, 0), v_days);
            IF v_days >= v_min_train THEN
                emit(hst('PASS'), 'snapshots dbid ' || v_dbid,
                     v_days || ' days (' || v_from || ' .. ' || v_to || ')');
            ELSE
                v_short_hist := v_short_hist + 1;
                emit(hst('WARN'), 'snapshots dbid ' || v_dbid,
                     'only ' || v_days || ' days (' || v_from || ' .. ' || v_to || ')');
            END IF;
            IF v_age <= 24 THEN
                emit(hst('PASS'), 'newest snap dbid ' || v_dbid,
                     TO_CHAR(v_age, 'FM999999990.0') || ' h ago');
            ELSE
                emit(hst('WARN'), 'newest snap dbid ' || v_dbid, TO_CHAR(v_age, 'FM999999990.0')
                     || ' h ago -- is AWR still taking snapshots for this database?');
            END IF;
        END LOOP;
        CLOSE v_cur;
        IF v_rows = 0 THEN
            emit(hst('WARN'), 'snapshots', 'no rows in DBA_HIST_SNAPSHOT');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                IF v_cur%ISOPEN THEN CLOSE v_cur; END IF;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            emit(hst('WARN'), 'snapshots', 'cannot read: ' || err);
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
    -- 7. Readiness: days each feature needs vs days of history available
    -- =================================================================
    DECLARE
        v_avail NUMBER;
        v_src   VARCHAR2(60);
        v_e     VARCHAR2(200);
        v_esm   NUMBER := 4 * LEAST(30, v_esm_step);

        PROCEDURE ready(p_label IN VARCHAR2, p_need IN NUMBER) IS
            v_st VARCHAR2(4);
        BEGIN
            v_st := CASE WHEN v_avail >= p_need THEN 'PASS' ELSE 'WARN' END;
            tally(v_st);
            DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_label, 48) || LPAD(TO_CHAR(p_need), 6)
                                 || LPAD(NVL(TO_CHAR(v_avail), '?'), 7) || '   ' || v_st);
        END ready;
    BEGIN
        -- Once installed, count through the seam (whatever mode it is in);
        -- before install, the local-mode source.
        IF v_installed THEN
            v_avail := count_days('SELECT MAX(n) FROM (SELECT COUNT(DISTINCT'
                                  || ' TRUNC(end_interval_time)) n FROM capv_snapshot'
                                  || ' GROUP BY dbid)', v_e);
            v_src   := 'CAPV_SNAPSHOT';
        END IF;
        IF v_avail IS NULL THEN
            v_avail := v_hist_days;
            v_src   := 'DBA_HIST_SNAPSHOT';
        END IF;

        hdr(' 7. Readiness per feature (days of history; best dbid in ' || v_src
            || '; knobs from ' || v_knob_src || ')');
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD('feature', 48) || LPAD('need', 6)
                             || LPAD('have', 7) || '   status');
        ready('trend fit (min_train_days)',                         v_min_train);
        ready('full training window (train_days)',                  v_train);
        ready('CPU weekday baseline (dow_weeks*7)',                 v_dow_weeks * 7);
        ready('CPU level shift (shift_days+shift_baseline_days)',   v_shift_days + v_shift_base);
        ready('backtest (backtest_holdout_days+min_train_days)',    v_holdout + v_min_train);
        ready('ESM +' || LEAST(30, v_esm_step) || ' horizon (4 x step, 19c cap 30)', v_esm);
        IF v_avail IS NULL THEN
            note('No history could be counted (' || NVL(v_e, 'no snapshot rows') || ').');
        END IF;
    END;

    -- =================================================================
    -- 8. Installed-suite health (only meaningful once install.sql has run)
    -- =================================================================
    hdr(' 8. Suite install state (current schema: ' || v_schema || ')');
    IF NOT v_installed THEN
        emit('WARN', 'CAP_CONFIG', 'not present -- suite not installed here yet');
    ELSE
        emit('PASS', 'CAP_CONFIG', 'present');
        DECLARE
            v_ver NUMBER := knob_raw('suite_version');
        BEGIN
            IF v_ver IS NULL THEN
                emit('WARN', 'suite_version', 'not stamped (installed before M13?);'
                     || ' re-run install.sql');
            ELSE
                emit('PASS', 'suite_version', TO_CHAR(v_ver));
            END IF;
        END;

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
                      WHERE  owner = v_schema
                        AND  status = 'INVALID'
                        AND  object_name LIKE 'CAP%'
                      ORDER BY object_name) LOOP
                v_bad  := v_bad + 1;
                v_list := SUBSTR(v_list || CASE WHEN v_list IS NULL THEN '' ELSE ', ' END
                                 || r.object_name || ' (' || r.object_type || ')', 1, 300);
            END LOOP;
            -- WARN, not FAIL: re-running install.sql recreates or recompiles
            -- them, so this must not stop the quickstart that would fix it.
            IF v_bad = 0 THEN
                emit('PASS', 'CAP* objects', 'all valid');
            ELSE
                emit('WARN', 'CAP* objects', v_bad || ' INVALID: ' || v_list);
                note('install.sql recompiles CAP* objects and stops if any stay invalid.');
            END IF;
        END;

        IF v_seam_mode IS NULL AND v_seam_refs IS NULL THEN
            emit('WARN', 'seam mode', 'CAPV_SNAPSHOT not found in this schema');
        ELSIF v_seam_mode IS NULL THEN
            emit('WARN', 'seam mode', 'unrecognised: ' || v_seam_refs);
        ELSE
            emit('PASS', 'seam mode', v_seam_mode || '  (CAPV_SNAPSHOT -> ' || v_seam_refs || ')');
            IF v_seam_mode = 'local' AND (v_seam_fails > 0 OR v_grant_missing > 0) THEN
                note('Local seam installed but some DBA_HIST_* view is unreadable or not');
                note('granted directly (check 3).');
            END IF;
        END IF;

        -- A green checklist means little if every fit is untrustworthy, so say
        -- how the fits actually came out.
        DECLARE
            PROCEDURE quality(p_view IN VARCHAR2, p_label IN VARCHAR2) IS
                v_ok   NUMBER;
                v_low  NUMBER;
                v_flat NUMBER;
                v_ins  NUMBER;
                v_tot  NUMBER;
                v_txt  VARCHAR2(200);
            BEGIN
                EXECUTE IMMEDIATE
                    'SELECT COUNT(CASE WHEN quality = ''OK'' THEN 1 END),'
                    || ' COUNT(CASE WHEN quality = ''LOW_CONFIDENCE'' THEN 1 END),'
                    || ' COUNT(CASE WHEN quality = ''FLAT'' THEN 1 END),'
                    || ' COUNT(CASE WHEN quality = ''INSUFFICIENT_HISTORY'' THEN 1 END),'
                    || ' COUNT(*) FROM ' || p_view
                    INTO v_ok, v_low, v_flat, v_ins, v_tot;
                v_txt := v_ok || ' OK, ' || v_flat || ' FLAT, ' || v_low
                         || ' LOW_CONFIDENCE, ' || v_ins || ' INSUFFICIENT_HISTORY';
                IF v_tot = 0 THEN
                    emit('WARN', p_label, 'no rows');
                ELSIF v_ok + v_flat = 0 THEN
                    emit('WARN', p_label, v_txt || ' -- no trustworthy fit yet');
                ELSE
                    emit('PASS', p_label, v_txt);
                END IF;
            EXCEPTION
                WHEN OTHERS THEN emit('WARN', p_label, 'cannot read: ' || err);
            END quality;
        BEGIN
            quality('capf_tbspc_forecast', 'tablespace fits');
            quality('capf_cpu_trend',      'CPU fits');
        END;
    END IF;

    -- =================================================================
    -- 9. Config sanity (installed only): the rules live in CAP_CFG_CHECK
    -- =================================================================
    IF v_installed THEN
        hdr(' 9. Config sanity (CAP_CFG_CHECK)');
        DECLARE
            v_cur  SYS_REFCURSOR;
            v_knob VARCHAR2(40);
            v_stat VARCHAR2(10);
            v_why  VARCHAR2(400);
            v_all  PLS_INTEGER := 0;
            v_bad  PLS_INTEGER := 0;
        BEGIN
            OPEN v_cur FOR 'SELECT knob, status, reason FROM cap_cfg_check ORDER BY knob';
            LOOP
                FETCH v_cur INTO v_knob, v_stat, v_why;
                EXIT WHEN v_cur%NOTFOUND;
                v_all := v_all + 1;
                IF v_stat <> 'OK' THEN
                    v_bad := v_bad + 1;
                    emit('WARN', v_knob, v_stat || ': ' || v_why);
                END IF;
            END LOOP;
            CLOSE v_cur;
            IF v_bad = 0 THEN
                emit('PASS', 'CAP_CFG_CHECK', 'all ' || v_all || ' knobs OK');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                emit('WARN', 'CAP_CFG_CHECK', 'cannot read: ' || err || ' (re-run install.sql)');
        END;
    END IF;

    -- =================================================================
    -- Summary
    -- =================================================================
    hdr(' Summary');
    DBMS_OUTPUT.PUT_LINE('  ' || n_pass || ' PASS / ' || n_warn || ' WARN / '
                         || n_fail || ' FAIL');

    IF v_pack_known AND NOT v_pack_ok THEN
        note('Forecasts will be empty: CONTROL_MANAGEMENT_PACK_ACCESS excludes');
        note('DIAGNOSTIC, so AWR collects nothing to fit.');
    END IF;
    IF v_hist_applies AND (v_seam_fails > 0 OR v_grant_missing > 0) THEN
        note('A local-mode install would leave CAPV_* invalid: the owning schema');
        note('cannot read every DBA_HIST_* view the seam needs (check 3).');
    END IF;
    IF NOT v_hist_applies THEN
        note('Seam mode here is ' || COALESCE(v_intended, v_seam_mode)
             || ', so checks 3, 5 and 6 (DBA_HIST_*)');
        note('do not apply to this install -- the data comes from '
             || CASE COALESCE(v_intended, v_seam_mode)
                     WHEN 'warehouse' THEN 'the AWRV_* views.'
                     ELSE 'CAP_FIXTURE_* tables.' END);
    ELSIF NOT v_installed AND v_intended IS NULL THEN
        note('Not installed here, so checks 3, 5 and 6 assume local mode. Fixture and');
        note('warehouse installs do not read DBA_HIST_*.');
    END IF;
    IF v_short_hist > 0 AND v_hist_applies THEN
        note('Why forecasts may say INSUFFICIENT_HISTORY:');
        note('  ' || v_short_hist || ' source(s) hold fewer than min_train_days ('
             || TO_CHAR(v_min_train) || ') distinct days.');
        note('  A fit needs that many daily points, so those series stay quiet');
        note('  until AWR has accumulated them. Re-run doctor.sql later.');
    END IF;
    IF v_retention_d IS NOT NULL AND v_retention_d < v_train AND v_hist_applies THEN
        note('Retention (' || v_retention_d || ' d) is below train_days (' || v_train
             || ' d), so the training window can never fill.');
    END IF;
    IF n_fail = 0 AND n_warn = 0 THEN
        note('All green -- install.sql should produce usable forecasts.');
    ELSIF n_fail > 0 THEN
        note(n_fail || ' FAIL line(s): fix those before installing (quickstart.sql stops).');
    END IF;
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 74, '='));

    :cap_doctor_fail_n := n_fail;
END;
/

-- Hand the FAIL count to the caller as a substitution variable. NULL means
-- the block above did not finish, which counts as a failure.
SET TERMOUT OFF
COLUMN cap_doctor_fail NEW_VALUE cap_doctor_fail NOPRINT
SELECT TO_CHAR(NVL(:cap_doctor_fail_n, 1)) AS cap_doctor_fail FROM dual;
COLUMN cap_doctor_fail CLEAR
SET TERMOUT ON

SET FEEDBACK ON
