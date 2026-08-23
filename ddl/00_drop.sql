--
-- ddl/00_drop.sql -- idempotent teardown of all CAP_* / CAPV_ / CAPD_ / CAPF_ / CAPA_ objects.
-- =====================================================================
-- Dropped in reverse dependency order (views first, then the two persisted
-- tables). Every drop is wrapped so a missing object is a no-op: the whole
-- suite re-installs cleanly whether or not a prior install exists.
--
-- OML mining models (schema objects created by ml/cap_forecast_ml) are NOT
-- dropped here -- they are owned by the ML package and removed by
-- cap_forecast_ml.drop_all / uninstall.sql, because dropping them requires
-- the model registry (CAP_ML_MODEL) to still exist.
--
-- Read-only against AWR; only touches this suite's own objects.
--
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    -- Views + the ESM pipelined interface, newest-layer-first so a view is
    -- dropped before the views it depends on (harmless either way -- CREATE
    -- OR REPLACE handles order on install -- but keeps DBA_DEPENDENCIES clean).
    TYPE name_list IS TABLE OF VARCHAR2(30);
    v_views name_list := name_list(
        'CAPR_ALERTS',
        'CAPR_CONTAINER',
        'CAPF_BACKTEST',
        'CAPF_COMPARE',
        'CAPF_ESM_BACKTEST',
        'CAPF_ESM_FORECAST',
        'CAPA_CPU_ANOM',
        'CAPA_TBSPC_ANOM',
        'CAPF_CPU_TREND',
        'CAPF_TBSPC_FORECAST',
        'CAPD_DBTIME_DAILY',
        'CAPD_CPU_DAILY',
        'CAPD_TBSPC_DELTA',
        'CAPD_TBSPC_DAILY',
        'CAPV_CONTAINER',
        'CAPV_TIME_MODEL',
        'CAPV_OSSTAT',
        'CAPV_DATAFILE',
        'CAPV_TABLESPACE',
        'CAPV_TBSPC_USAGE',
        'CAPV_SNAPSHOT'
    );
BEGIN
    FOR i IN 1 .. v_views.COUNT LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP VIEW ' || v_views(i);
        EXCEPTION
            WHEN OTHERS THEN
                -- ORA-00942 (table or view does not exist) is expected on a
                -- fresh install; re-raise anything else.
                IF SQLCODE != -942 THEN RAISE; END IF;
        END;
    END LOOP;

    -- NOTE: the two PERSISTED tables (CAP_CONFIG, CAP_ML_MODEL) are deliberately
    -- NOT dropped here. A re-install must preserve operator config overrides and
    -- the trained-model registry (05_config / 50_ml recreate them idempotently
    -- and MERGE-seed only missing keys). Dropping CAP_ML_MODEL here would also
    -- orphan the OML models (drop_all needs the registry to find them). Full
    -- teardown lives in uninstall.sql.

    -- The two SQL types backing CAPF_ESM_FORECAST. FORCE because the
    -- cap_forecast_ml package (get_forecast RETURN cap_esm_tab) depends on them
    -- and is not dropped here -- it is reloaded by ddl/50_ml right after, which
    -- revalidates it. Collection type (cap_esm_tab) first, then its element
    -- (cap_esm_row). ORA-04043 = "does not exist" is expected on a fresh install.
    FOR y IN (SELECT 'CAP_ESM_TAB' AS n FROM dual
              UNION ALL SELECT 'CAP_ESM_ROW' FROM dual) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP TYPE ' || y.n || ' FORCE';
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE != -4043 THEN RAISE; END IF;
        END;
    END LOOP;
END;
/
