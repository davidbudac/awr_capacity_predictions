--
-- ddl/50_ml.sql -- Tier 2 OML ESM: registry table, types, package, views.
-- =====================================================================
-- Persists the model registry (CAP_ML_MODEL), the SQL types the pipelined
-- forecast reader returns, loads the cap_forecast_ml package, then builds the
-- two views the report consumes:
--   CAPF_ESM_FORECAST -- per-day fit+forecast for every trained model.
--   CAPF_COMPARE      -- Tier 1 REGR point projections vs Tier 2 ESM
--                        predictions, one row per (series, horizon, engine).
--
-- The package COMPILES without CREATE MINING MODEL; only training needs it.
-- OML models are dropped by cap_forecast_ml.drop_all (they need the registry),
-- so ddl/00_drop leaves them alone.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- Model registry. One row per trained (or attempted) series.
-- Idempotent create: on a re-install the registry (and its OML models) survive
-- because 00_drop no longer drops it. Swallow ORA-00955 and keep existing rows.
-- --------------------------------------------------------------------
DECLARE
BEGIN
    EXECUTE IMMEDIATE 'CREATE TABLE cap_ml_model (
        model_name       VARCHAR2(30)  CONSTRAINT cap_ml_model_pk PRIMARY KEY,
        series_kind      VARCHAR2(10)  NOT NULL,
        dbid             NUMBER        NOT NULL,
        con_dbid         NUMBER        NOT NULL,
        series_key       VARCHAR2(128) NOT NULL,
        exsm_model       VARCHAR2(20),
        seasonality      NUMBER,
        trained_through  DATE,
        trained_at       DATE,
        status           VARCHAR2(200)
    )';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

COMMENT ON TABLE cap_ml_model IS 'Registry of OML exponential-smoothing models built by cap_forecast_ml (one per series).';

-- --------------------------------------------------------------------
-- SQL types for the pipelined forecast reader (must be schema-level types so
-- they are usable in SQL TABLE(...) from CAPF_ESM_FORECAST).
-- --------------------------------------------------------------------
CREATE OR REPLACE TYPE cap_esm_row AS OBJECT (
    case_id      DATE,
    actual       NUMBER,
    prediction   NUMBER,
    lower_bound  NUMBER,
    upper_bound  NUMBER
);
/
CREATE OR REPLACE TYPE cap_esm_tab AS TABLE OF cap_esm_row;
/

-- --------------------------------------------------------------------
-- Package (spec + body). Paths resolve relative to the outermost caller
-- (install.sql / the repo root).
-- --------------------------------------------------------------------
@@ml/cap_forecast_ml.pks
@@ml/cap_forecast_ml.pkb

-- --------------------------------------------------------------------
-- CAPF_ESM_FORECAST -- per-day actual + forecast for every OK model.
-- Lateral join: TABLE(get_forecast(m.model_name)) is correlated to each
-- registry row (implicit LATERAL, 19c).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_esm_forecast AS
SELECT m.model_name,
       m.series_kind,
       m.dbid,
       m.con_dbid,
       m.series_key,
       m.seasonality,
       m.trained_through,
       t.case_id      AS day_dt,
       t.actual,
       t.prediction,
       t.lower_bound,
       t.upper_bound
FROM   cap_ml_model m,
       TABLE(cap_forecast_ml.get_forecast(m.model_name)) t
WHERE  m.status = 'OK';

-- --------------------------------------------------------------------
-- CAPF_COMPARE -- Tier 1 (REGR) vs Tier 2 (ESM) at matched horizons.
--   engine REGR: point projections from CAPF_TBSPC_FORECAST (+30/90/180/365)
--                and CAPF_CPU_TREND (+30/90). No interval (bounds NULL).
--   engine ESM : prediction + 95% bounds at +30 ONLY. Oracle 19c EXSM hard-caps
--                the horizon at 30 steps, so +90/180/365 are unreachable and
--                stay REGR-only. ESM rows are also gated on FRESHNESS: the model
--                must be trained THROUGH the series' current last day, so a
--                model left behind by a later top-N retrain (stale
--                trained_through) is not compared against a current-dated REGR
--                point.
-- series_kind is TBSPC or CPU; series_key is the tablespace name or the CPU
-- metric (BUSY_PCT / DB_CPU_SEC) so REGR and ESM rows line up.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_compare AS
-- ---- REGR, tablespace bytes ----
SELECT dbid, con_dbid, 'TBSPC' AS series_kind, tablespace_name AS series_key,
       30 AS horizon_days, 'REGR' AS engine,
       proj_30_bytes AS value, CAST(NULL AS NUMBER) AS lower_bound, CAST(NULL AS NUMBER) AS upper_bound
FROM   capf_tbspc_forecast WHERE quality <> 'INSUFFICIENT_HISTORY'
UNION ALL
SELECT dbid, con_dbid, 'TBSPC', tablespace_name, 90,  'REGR', proj_90_bytes,  NULL, NULL
FROM   capf_tbspc_forecast WHERE quality <> 'INSUFFICIENT_HISTORY'
UNION ALL
SELECT dbid, con_dbid, 'TBSPC', tablespace_name, 180, 'REGR', proj_180_bytes, NULL, NULL
FROM   capf_tbspc_forecast WHERE quality <> 'INSUFFICIENT_HISTORY'
UNION ALL
SELECT dbid, con_dbid, 'TBSPC', tablespace_name, 365, 'REGR', proj_365_bytes, NULL, NULL
FROM   capf_tbspc_forecast WHERE quality <> 'INSUFFICIENT_HISTORY'
-- ---- REGR, CPU metrics ----
UNION ALL
SELECT dbid, con_dbid, 'CPU', metric, 30, 'REGR', proj_30, NULL, NULL
FROM   capf_cpu_trend WHERE quality <> 'INSUFFICIENT_HISTORY'
UNION ALL
SELECT dbid, con_dbid, 'CPU', metric, 90, 'REGR', proj_90, NULL, NULL
FROM   capf_cpu_trend WHERE quality <> 'INSUFFICIENT_HISTORY'
-- ---- ESM, +30 ONLY (19c hard-caps the horizon at 30), fresh models only ----
UNION ALL
SELECT e.dbid, e.con_dbid,
       CASE WHEN e.series_kind = 'TBSPC' THEN 'TBSPC' ELSE 'CPU' END,
       e.series_key, 30, 'ESM', e.prediction, e.lower_bound, e.upper_bound
FROM   capf_esm_forecast e
WHERE  e.actual IS NULL
  AND  TRUNC(e.day_dt) = TRUNC(e.trained_through) + 30
  -- freshness: model must be trained through the series' current last day.
  AND  TRUNC(e.trained_through) = TRUNC(
         CASE e.series_kind
             WHEN 'TBSPC' THEN (SELECT MAX(day_dt) FROM capd_tbspc_daily d
                                 WHERE d.dbid = e.dbid AND d.con_dbid = e.con_dbid
                                   AND d.tablespace_name = e.series_key)
             WHEN 'CPU'   THEN (SELECT MAX(day_dt) FROM capd_cpu_daily d
                                 WHERE d.dbid = e.dbid AND d.con_dbid = e.con_dbid)
             WHEN 'DBCPU' THEN (SELECT MAX(day_dt) FROM capd_dbtime_daily d
                                 WHERE d.dbid = e.dbid AND d.con_dbid = e.con_dbid)
         END);
