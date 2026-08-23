--
-- install.sql -- one-shot installer for the AWR capacity-predictions suite.
-- =====================================================================
-- Creates every CAP_* / CAPV_ / CAPD_ / CAPF_ / CAPA_ object into the CURRENT
-- schema, wiring the portable seam to one of three data sources.
--
-- Usage (the caller MUST DEFINE seam_mode first; see note below):
--
--   sqlplus / as sysdba
--   SQL> DEFINE seam_mode = 'local'      -- local | warehouse | fixture
--   SQL> @install.sql
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
WHENEVER SQLERROR EXIT SQL.SQLCODE
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

PROMPT  seam_mode  = &&seam_mode
PROMPT  seam_script= &seam_script
PROMPT  schema     = installing into the current schema
PROMPT

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
PROMPT -- [30] Tier 1 forecasts (CAPF_*) ...
@@ddl/30_forecast_views.sql
PROMPT -- [40] anomalies (CAPA_*) ...
@@ddl/40_anomaly_views.sql
PROMPT -- [45] integration/report layer (CAPR_CONTAINER + CAPR_ALERTS) ...
@@ddl/45_report_views.sql
PROMPT -- [50] Tier 2 OML ESM (CAP_ML_MODEL + package + CAPF_ESM/COMPARE) ...
@@ddl/50_ml.sql

-- --------------------------------------------------------------------
-- Closing validity check. Any INVALID object among our prefixes is a real
-- install failure -- in every seam mode (warehouse mode now compiles valid
-- against the awr-fleet-warehouse AWRV_* views, as of Milestone W).
-- --------------------------------------------------------------------
SET DEFINE '&'
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
    v_bad   PLS_INTEGER  := 0;
BEGIN
    FOR r IN (
        SELECT object_name, object_type
        FROM   user_objects
        WHERE  status = 'INVALID'
          AND (object_name LIKE 'CAP\_%'  ESCAPE '\'
            OR object_name LIKE 'CAPV\_%' ESCAPE '\'
            OR object_name LIKE 'CAPD\_%' ESCAPE '\'
            OR object_name LIKE 'CAPF\_%' ESCAPE '\'
            OR object_name LIKE 'CAPA\_%' ESCAPE '\'
            OR object_name LIKE 'CAPR\_%' ESCAPE '\')
        ORDER BY object_name
    ) LOOP
        v_bad := v_bad + 1;
        DBMS_OUTPUT.PUT_LINE('  INVALID ' || r.object_type || ' ' || r.object_name);
    END LOOP;

    IF v_bad > 0 THEN
        RAISE_APPLICATION_ERROR(-20001,
            'Install incomplete: ' || v_bad || ' object(s) invalid (see list above). '
            || 'Check DBA_HIST_* grants (local mode), the AWRV_* views + SELECT grants '
            || '(warehouse mode), or CAP_FIXTURE_* tables (fixture mode).');
    END IF;
    DBMS_OUTPUT.PUT_LINE('  All CAP* objects valid.');
END;
/

PROMPT
SET DEFINE '&'
PROMPT ============================================================
PROMPT  Install complete (seam_mode = &&seam_mode).
PROMPT  Next: report/report.sql  (text capacity report)
PROMPT        cap_forecast_ml.train_all  (optional Tier 2 ESM models)
PROMPT ============================================================
PROMPT

WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON
