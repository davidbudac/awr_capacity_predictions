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
    -- M10.4 quality gate: only series whose Tier 1 quality is OK or
    -- LOW_CONFIDENCE are eligible -- FLAT / INSUFFICIENT_HISTORY are skipped.
    -- M10.4 model type, from CAP_CONFIG:
    --   esm_tbspc_model        0 = EXSM_HOLT (additive trend, no seasonality)
    --                          1 = EXSM_ADDWINTERS with weekly seasonality (7)
    --                          2 = AUTO (default) -- train both candidates as
    --                              backtest twins and keep the lower-MAPE one
    --   esm_select_by_backtest 1 (default) enables the AUTO comparison; 0 makes
    --                          AUTO fall back to EXSM_HOLT without training twins
    -- The chosen type and both candidate MAPEs are recorded on the model's
    -- CAP_ML_MODEL row (model_type / chosen_by / mape_holt / mape_addw).
    PROCEDURE train_tablespaces(p_top_n IN NUMBER DEFAULT 20);

    -- Train ESM models for host busy% and DB CPU seconds. EXSM_ADDWINTERS
    -- (Holt-Winters additive) with weekly seasonality (EXSM_SEASONALITY = 7).
    -- Same M10.4 quality gate, applied to CAPF_CPU_TREND.
    PROCEDURE train_cpu;

    -- Convenience: train_tablespaces(p_top_n) then train_cpu.
    PROCEDURE train_all(p_top_n IN NUMBER DEFAULT 20);

    -- M9.4 backtest: train purpose=BACKTEST twins of the same series with the
    -- last p_holdout_days (default: CAP_CONFIG backtest_holdout_days) of data
    -- HELD OUT, so CAPF_BACKTEST can score their forecasts against the real
    -- values. Separate model names (CBT* prefixes); never appear in
    -- CAPF_ESM_FORECAST / CAPF_COMPARE. Re-run after data grows to refresh.
    -- M10.4: tablespaces get ONE TWIN PER CANDIDATE model type (EXSM_HOLT and
    -- EXSM_ADDWINTERS/7), scored separately in CAPF_ESM_CANDIDATE; CPU series
    -- have a single candidate. train_tablespaces calls this itself when AUTO.
    PROCEDURE train_backtest(p_top_n        IN NUMBER DEFAULT 20,
                             p_holdout_days IN NUMBER DEFAULT NULL);

    -- Drop every OML model this package created (both purposes) and clear
    -- CAP_ML_MODEL.
    PROCEDURE drop_all;

    -- Pipe the per-day fit+forecast for one registered model out of its dynamic
    -- DM$VP<model> result view (name is only known at runtime). Rows cover both
    -- the fitted history (actual not null) and the future horizon (actual null,
    -- prediction = forecast, with lower/upper 95% bounds). CAPF_ESM_FORECAST
    -- lateral-joins this over CAP_ML_MODEL.
    FUNCTION get_forecast(p_model IN VARCHAR2) RETURN cap_esm_tab PIPELINED;

END cap_forecast_ml;
/
