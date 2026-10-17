--
-- install.sql -- one-shot installer for the AWR capacity-predictions suite.
-- =====================================================================
-- Creates every CAP_* / CAPV_ / CAPD_ / CAPF_ / CAPA_ object into the CURRENT
-- schema, wiring the portable seam to one of three data sources.
--
-- Usage (the caller MUST DEFINE seam_mode first; see note below):
--
--   sqlplus c##awrcap/...                -- the owner create_owner.sql made
--   SQL> DEFINE seam_mode = 'local'      -- local | warehouse | fixture
--   SQL> @install.sql
--
-- The header prints the target schema. Installing into SYS still works (the
-- quickstart does it) but prints a warning: a dedicated owner keeps the
-- suite out of the dictionary schema and is the production path.
--
-- seam_mode dispatch:
--   local      CAPV_* over DBA_HIST_*      (needs Diagnostics Pack + direct
--              SELECT grants on the DBA_HIST_* views). Install in CDB$ROOT.
--   warehouse  CAPV_* over the awr-fleet-warehouse AWRV_* seam views. Install
--              where those views are visible: as the warehouse owner (AWRWH),
--              or in a schema with direct SELECT grants on the AWRV_* views.
--   fixture    CAPV_* over CAP_FIXTURE_* tables. Run test/fixture_install.sql
--              FIRST to create + populate them, then install with this mode.
--
-- Note on defaulting: SQL*Plus has no "define if unset", so &&seam_mode below
-- will PROMPT once if you did not DEFINE it. Non-interactive callers (the test
-- harness, CI) always DEFINE it up front to avoid the prompt consuming a line.
--
-- Read-only against AWR data: the only rows this suite ever writes are into
-- its own CAP_CONFIG / CAP_ML_MODEL tables. No AWR object is modified.
--
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET TIMING   OFF
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
-- EXIT FAILURE, not SQL.SQLCODE: the OS keeps only the low 8 bits of the exit
-- status, so an ORA- code that is a multiple of 256 would exit 0.
WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR  EXIT FAILURE

-- Pin '.' as decimal separator so REGR_* / numeric literals are locale-safe.
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

PROMPT
PROMPT ============================================================
PROMPT  AWR Capacity Predictions -- install
PROMPT ============================================================

-- Resolve the seam script from seam_mode. An unrecognised mode forces a
-- ZERO_DIVIDE so the install aborts loudly instead of silently skipping the
-- seam. LOWER() makes the mode case-insensitive.
COLUMN seam_script NEW_VALUE seam_script NOPRINT
SELECT 'ddl/' ||
       CASE LOWER(NVL('&&seam_mode', 'local'))
            WHEN 'local'     THEN '10_seam_local.sql'
            WHEN 'warehouse' THEN '11_seam_warehouse.sql'
            WHEN 'fixture'   THEN '12_seam_fixture.sql'
            ELSE TO_CHAR(1/0)   -- invalid seam_mode -> abort
       END AS seam_script
FROM   dual;

COLUMN cap_schema NEW_VALUE cap_schema NOPRINT
SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AS cap_schema FROM dual;

PROMPT  seam_mode  = &&seam_mode
PROMPT  seam_script= &seam_script
PROMPT  schema     = &cap_schema
PROMPT

BEGIN
    IF SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') = 'SYS' THEN
        DBMS_OUTPUT.PUT_LINE('  ############################################################');
        DBMS_OUTPUT.PUT_LINE('  WARNING: installing into SYS.');
        DBMS_OUTPUT.PUT_LINE('  Every CAP* object will be owned by SYS in this container.');
        DBMS_OUTPUT.PUT_LINE('  This works, but it mixes the suite into the dictionary');
        DBMS_OUTPUT.PUT_LINE('  schema. For a real install, create a dedicated owner with');
        DBMS_OUTPUT.PUT_LINE('  @create_owner.sql and install as that user.');
        DBMS_OUTPUT.PUT_LINE('  ############################################################');
    END IF;
END;
/

-- --------------------------------------------------------------------
-- Layered DDL, in dependency order. @@ resolves relative to this file's dir.
-- --------------------------------------------------------------------
PROMPT -- [00] drop any prior install ...
@@ddl/00_drop.sql
PROMPT -- [05] CAP_CONFIG + seed ...
@@ddl/05_config.sql
-- The included DDL files each SET DEFINE OFF (so literal text is never treated
-- as a substitution). Restore '&' here so &seam_script resolves for the @@ include.
SET DEFINE '&'
PROMPT -- [seam] &seam_script ...
@@&seam_script
PROMPT -- [20] daily series (CAPD_*) ...
@@ddl/20_daily_views.sql
PROMPT -- [25] fixed-ceiling series (CAPD_SERIES_DAILY: processes/sessions, redo, DB size) ...
@@ddl/25_series_daily.sql
PROMPT -- [30] Tier 1 forecasts (CAPF_*) ...
@@ddl/30_forecast_views.sql
PROMPT -- [35] fixed-ceiling series forecast (CAPF_SERIES_FORECAST) ...
@@ddl/35_series_forecast.sql
PROMPT -- [40] anomalies (CAPA_*) ...
@@ddl/40_anomaly_views.sql
PROMPT -- [45] integration/report layer (CAPR_CONTAINER + CAPR_ALERTS + sections) ...
@@ddl/45_report_views.sql
PROMPT -- [50] Tier 2 OML ESM (CAP_ML_MODEL + package + CAPF_ESM/COMPARE) ...
@@ddl/50_ml.sql
PROMPT -- [55] report views that need Tier 2 (CAPR_TBSPC_FORECAST/ESM_COMPARE/BACKTEST) ...
@@ddl/55_report_views_ml.sql

-- --------------------------------------------------------------------
-- Recompile, then check. A re-install drops and recreates the views, which
-- leaves any dependent object INVALID (e.g. CAP_REPORT_SPOOL from
-- install_jobs.sql, which reads CAPR_ALERTS), and nothing else recompiles it.
-- Both steps read ALL_OBJECTS on owner = CURRENT_SCHEMA: USER_OBJECTS follows
-- the session user, so it looks in the wrong schema under
-- ALTER SESSION SET CURRENT_SCHEMA.
-- --------------------------------------------------------------------
SET DEFINE '&'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
DECLARE
    v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    v_sql   VARCHAR2(400);
BEGIN
    -- Two passes: an object that failed because its own dependency was still
    -- invalid compiles on the second.
    FOR pass IN 1 .. 2 LOOP
        FOR r IN (
            SELECT object_name, object_type
            FROM   all_objects
            WHERE  owner  = v_owner
              AND  status = 'INVALID'
              AND  REGEXP_LIKE(object_name, '^CAP[VDFAR]?_')
              AND  object_type IN ('VIEW', 'PROCEDURE', 'FUNCTION', 'PACKAGE',
                                   'PACKAGE BODY', 'TYPE', 'TYPE BODY',
                                   'TRIGGER', 'SYNONYM')
            ORDER BY DECODE(object_type, 'TYPE', 1, 'PACKAGE', 2, 'VIEW', 3,
                                         'SYNONYM', 3, 'FUNCTION', 4,
                                         'PROCEDURE', 4, 'TYPE BODY', 5,
                                         'PACKAGE BODY', 5, 6),
                     object_name
        ) LOOP
            v_sql := 'ALTER '
                  || CASE r.object_type
                         WHEN 'PACKAGE BODY' THEN 'PACKAGE'
                         WHEN 'TYPE BODY'    THEN 'TYPE'
                         ELSE r.object_type
                     END
                  || ' ' || DBMS_ASSERT.ENQUOTE_NAME(v_owner, FALSE)
                  || '.' || DBMS_ASSERT.ENQUOTE_NAME(r.object_name, FALSE)
                  || CASE WHEN r.object_type IN ('PACKAGE BODY', 'TYPE BODY')
                          THEN ' COMPILE BODY' ELSE ' COMPILE' END;
            BEGIN
                EXECUTE IMMEDIATE v_sql;
                DBMS_OUTPUT.PUT_LINE('  recompiled ' || r.object_type || ' ' || r.object_name);
            EXCEPTION
                WHEN OTHERS THEN
                    -- ORA-24344 (compiled with errors) lands here; the check
                    -- below lists whatever is still invalid.
                    IF pass = 2 THEN
                        DBMS_OUTPUT.PUT_LINE('  recompile failed: ' || r.object_type || ' '
                                             || r.object_name || ' (' || SQLERRM || ')');
                    END IF;
            END;
        END LOOP;
    END LOOP;
END;
/

-- Any INVALID object among our prefixes is a real install failure, in every
-- seam mode (warehouse mode compiles valid against the awr-fleet-warehouse
-- AWRV_* views, as of Milestone W).
DECLARE
    v_bad   PLS_INTEGER  := 0;
BEGIN
    FOR r IN (
        SELECT object_name, object_type
        FROM   all_objects
        WHERE  owner  = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
          AND  status = 'INVALID'
          AND  REGEXP_LIKE(object_name, '^CAP[VDFAR]?_')
        ORDER BY object_name
    ) LOOP
        v_bad := v_bad + 1;
        DBMS_OUTPUT.PUT_LINE('  INVALID ' || r.object_type || ' ' || r.object_name);
    END LOOP;

    IF v_bad > 0 THEN
        RAISE_APPLICATION_ERROR(-20001,
            'Install incomplete: ' || v_bad || ' object(s) invalid in schema '
            || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') || ' (see list above). '
            || 'Check DBA_HIST_* grants (local mode), the AWRV_* views + SELECT grants '
            || '(warehouse mode), or CAP_FIXTURE_* tables (fixture mode).');
    END IF;
    DBMS_OUTPUT.PUT_LINE('  All CAP* objects valid in schema '
                         || SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') || '.');
END;
/

PROMPT
SET DEFINE '&'
PROMPT ============================================================
PROMPT  Install complete (seam_mode = &&seam_mode, schema = &cap_schema).
PROMPT  Next: report/report.sql  (text capacity report)
PROMPT        cap_forecast_ml.train_all  (optional Tier 2 ESM models)
PROMPT ============================================================
PROMPT

WHENEVER SQLERROR CONTINUE
WHENEVER OSERROR  CONTINUE
SET FEEDBACK ON
