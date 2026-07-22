--
-- ml/cap_forecast_ml.pks -- Tier 2 OML exponential-smoothing forecaster (spec).
-- =====================================================================
-- Wraps DBMS_DATA_MINING ESM (exponential smoothing) time-series models around
-- the same CAPD_* daily series the Tier 1 REGR forecasts fit, so the report can
-- show a seasonality-aware second opinion side by side with the linear trend.
--
-- 19c has no multi-series / partitioned ESM (that is 21c+), so this trains ONE
-- model per series and registers it in CAP_ML_MODEL. Model names are a stable
-- hash of the series identity, so re-training drops+rebuilds in place.
--
-- Privilege: the training procedures need CREATE MINING MODEL (free in all
-- editions since Dec 2019). The package COMPILES without it; only train_*
-- fails at runtime if it is missing.
--
CREATE OR REPLACE PACKAGE cap_forecast_ml AS

    -- Train an ESM model per permanent tablespace, limited to the p_top_n most
    -- capacity-critical (nearest days_to_full, then largest current usage).
    -- EXSM_HOLT: additive trend, no seasonality (tablespace growth is not weekly).
    PROCEDURE train_tablespaces(p_top_n IN NUMBER DEFAULT 20);

    -- Train ESM models for host busy% and DB CPU seconds. EXSM_HW (Holt-Winters)
    -- with weekly seasonality (EXSM_SEASONALITY = 7).
    PROCEDURE train_cpu;

    -- Convenience: train_tablespaces(p_top_n) then train_cpu.
    PROCEDURE train_all(p_top_n IN NUMBER DEFAULT 20);

    -- Drop every OML model this package created and clear CAP_ML_MODEL.
    PROCEDURE drop_all;

    -- Pipe the per-day fit+forecast for one registered model out of its dynamic
    -- DM$VP<model> result view (name is only known at runtime). Rows cover both
    -- the fitted history (actual not null) and the future horizon (actual null,
    -- prediction = forecast, with lower/upper 95% bounds). CAPF_ESM_FORECAST
    -- lateral-joins this over CAP_ML_MODEL.
    FUNCTION get_forecast(p_model IN VARCHAR2) RETURN cap_esm_tab PIPELINED;

END cap_forecast_ml;
/
