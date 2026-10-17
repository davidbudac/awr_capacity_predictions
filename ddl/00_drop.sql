--
-- ddl/00_drop.sql -- idempotent teardown of all CAP_* / CAPV_ / CAPD_ / CAPF_ / CAPA_ objects.
-- =====================================================================
-- Drops the views (reverse dependency order) and the two ESM types. The
-- persisted tables stay (see the NOTE below). Every drop is wrapped so a
-- missing object is a no-op: the whole suite re-installs cleanly whether or
-- not a prior install exists.
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
        'CAPR_FORECAST_ACCURACY',
        'CAPR_WEEKLY_DIGEST',
        'CAPR_FIT_HISTORY',
        'CAPR_COVERAGE',
        'CAPR_RUNS',
        'CAPR_ALERT_EVENTS',
        'CAPR_ALERTS_LATEST',
        'CAPR_ALERTS',
        'CAPR_FORECAST_POINTS',
        'CAPR_BACKTEST',
        'CAPR_ESM_COMPARE',
        'CAPR_TBSPC_FORECAST',
        'CAPR_FIT',
        'CAPR_HOURLY_POINTS',
        'CAPR_SERIES_POINTS',
        'CAPR_CPU_SHIFTS',
        'CAPR_CPU_ANOMALIES',
        'CAPR_CPU_TREND',
        'CAPR_TBSPC_ANOMALIES',
        'CAPR_TBSPC_DAYS_TO_FULL',
        'CAPR_SERIES_ANOMALIES',
        'CAPR_SERIES',
        'CAPR_SEVERITY',
        'CAPR_FRESHNESS',
        'CAPR_ANOMALIES',
        'CAPR_CONTAINER',
        'CAPF_SERIES_FORECAST',
        'CAPD_SERIES_DAILY',
        'CAPF_BACKTEST',
        'CAPF_COMPARE',
        'CAPF_ESM_HEALTH_SUMMARY',
        'CAPF_ESM_HEALTH',
        'CAPF_ESM_CANDIDATE',
        'CAPF_ESM_BACKTEST',
        'CAPF_ESM_FORECAST',
        'CAPA_CPU_SHIFT',
        'CAPA_CPU_ANOM',
        'CAPA_TBSPC_ANOM',
        'CAPA_ANOM_DAY',
        'CAPA_ANOM',
        'CAPA_OBS',
        'CAPF_CPU_TREND',
        'CAPF_TBSPC_FORECAST',
        'CAPD_CPU_HOURLY',
        'CAPD_DBTIME_DAILY',
        'CAPD_CPU_DAILY',
        'CAPD_DBTIME_INTERVAL',
        'CAPD_CPU_INTERVAL',
        'CAPD_COUNTER_DELTA',
        'CAPD_TBSPC_DELTA',
        'CAPD_TBSPC_DAILY',
        'CAPV_CONTRACT',
        'CAPV_CONTAINER',
        'CAPV_TIME_MODEL',
        'CAPV_OSSTAT',
        'CAPV_DATAFILE',
        'CAPV_TABLESPACE',
        'CAPV_TBSPC_USAGE',
        'CAPV_RESOURCE_LIMIT',
        'CAPV_SYSSTAT',
        'CAPV_PARAMETER',
        'CAPV_ASM_DISKGROUP',
        'CAPV_SNAPSHOT',
        'CAP_CFG_CHECK',
        'CAP_CFG'
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

    -- NOTE: the PERSISTED tables are deliberately NOT dropped here: CAP_CONFIG,
    -- CAP_TBSPC_OVERRIDE, CAP_ML_MODEL and the results layer's CAP_RUN,
    -- CAP_FIT_HIST, CAP_ALERT_STATE, CAP_ALERT_EVENT. A re-install must preserve
    -- operator config overrides, the hand-set tablespace limits / exclusions
    -- (M9.5), the trained-model registry and the run history, alert state and
    -- acks (05_config / 50_ml / 60_results recreate them idempotently).
    -- Dropping CAP_ML_MODEL would orphan the OML models (drop_all needs the
    -- registry to find them). The CAP_RESULTS package is replaced by ddl/60.
    -- Full teardown lives in uninstall.sql.

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
