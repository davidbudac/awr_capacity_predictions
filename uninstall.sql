--
-- uninstall.sql -- remove every object the suite created from the current schema.
-- =====================================================================
-- Drops OML models first (via the package, which needs the registry), then all
-- views + the two persisted tables via ddl/00_drop.sql. Idempotent: safe to run
-- against a partial or already-removed install.
--
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

PROMPT -- dropping OML models (cap_forecast_ml.drop_all) ...
BEGIN
    cap_forecast_ml.drop_all;
EXCEPTION
    WHEN OTHERS THEN
        -- Package may not exist (never installed / already removed): ignore.
        DBMS_OUTPUT.PUT_LINE('  (skipped drop_all: ' || SQLERRM || ')');
END;
/

PROMPT -- dropping suite objects (ddl/00_drop.sql) ...
@@ddl/00_drop.sql

-- The two persisted tables outlive 00_drop (which preserves them across a
-- re-install). A true uninstall removes them here.
BEGIN
    FOR t IN (SELECT 'CAP_ML_MODEL' AS n FROM dual
              UNION ALL SELECT 'CAP_CONFIG' FROM dual) LOOP
        BEGIN EXECUTE IMMEDIATE 'DROP TABLE ' || t.n || ' PURGE';
        EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN NULL; END IF; END;
    END LOOP;
END;
/

-- The two schema-level types outlive 00_drop (which only handles views/tables).
BEGIN
    EXECUTE IMMEDIATE 'DROP TYPE cap_esm_tab';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -4043 THEN NULL; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP TYPE cap_esm_row';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -4043 THEN NULL; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP PACKAGE cap_forecast_ml';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -4043 THEN NULL; END IF;
END;
/

PROMPT -- uninstall complete.
