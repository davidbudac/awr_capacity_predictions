--
-- ml/cap_forecast_ml.pks -- Tier 2 OML exponential-smoothing forecaster (spec).
-- =====================================================================
-- Wraps DBMS_DATA_MINING ESM (exponential smoothing) time-series models around
-- the same CAPD_* daily series the Tier 1 REGR forecasts fit, so the report can
-- show a seasonality-aware second opinion side by side with the linear trend.
--
-- 19c has no multi-series / partitioned ESM (that is 21c+), so this trains ONE
-- model per series and registers it in CAP_ML_MODEL. Model names are a stable
-- hash of the series identity. A retrain builds under <name>_N and swaps it in
-- only after it succeeded, so a failed retrain keeps the last good model.
--
-- Failure reporting: a failed build sets the registry row to status 'FAILED'
-- with last_error and failed_at (CAPF_ESM_HEALTH shows them). Every public
-- train_* procedure finishes all its series first, then raises ORA-20060 if any
-- FORECAST model failed, so a scheduler job run shows FAILED. Backtest twin
-- failures are recorded but never raise.
--
-- Cost per call, in model builds:
--   train_tablespaces    1 per tablespace, plus 2 backtest twins per tablespace
--                        under AUTO selection (the default), so 3.
--   train_cpu            1 per CPU series (BUSY_PCT, DB_CPU_SEC per container).
--   train_all            train_tablespaces + train_cpu, and with p_backtest
--                        (default TRUE) the backtest twins of every series it
--                        trains: 3 per tablespace, 2 per CPU series.
--   train_backtest       2 per tablespace + 1 per CPU series.
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
    --   esm_auto_tie_pct       AUTO candidates whose MAPEs differ by less than
    --                          this many points tie; EXSM_HOLT is kept and
    --                          chosen_by records AUTO_TIE
    -- The chosen type and both candidate MAPEs are recorded on the model's
    -- CAP_ML_MODEL row (model_type / chosen_by / mape_holt / mape_addw).
    PROCEDURE train_tablespaces(p_top_n IN NUMBER DEFAULT 20);

    -- Retrain one tablespace by name (its twins too under AUTO), same quality
    -- gate and model-type rules as train_tablespaces. p_con_dbid NULL = every
    -- container that has an eligible tablespace of that name. Raises ORA-20061
    -- when nothing eligible matches.
    PROCEDURE train_tablespace(p_tablespace_name IN VARCHAR2,
                               p_con_dbid        IN NUMBER DEFAULT NULL);

    -- Train ESM models for host busy% and DB CPU seconds. EXSM_ADDWINTERS
    -- (Holt-Winters additive) with weekly seasonality (EXSM_SEASONALITY = 7).
    -- Same M10.4 quality gate, applied to CAPF_CPU_TREND.
    PROCEDURE train_cpu;

    -- train_tablespaces(p_top_n) then train_cpu. p_backtest TRUE (default) also
    -- refreshes the backtest twins of the series it trains, so CAPF_BACKTEST
    -- scores the ESM and REGR engines over the same, current holdout.
    PROCEDURE train_all(p_top_n    IN NUMBER  DEFAULT 20,
                        p_backtest IN BOOLEAN DEFAULT TRUE);

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

    -- Low-level: register and (re)build one model from p_data_query, which must
    -- return DAY_DT and the p_target_col column. Every train_* procedure goes
    -- through it. It never raises: a failure lands on the registry row as
    -- status FAILED + last_error + failed_at, and any existing model of that
    -- name keeps serving. Public so a caller (or the test harness) can rebuild
    -- one model directly.
    PROCEDURE build_model(p_model        IN VARCHAR2,
                          p_series_kind  IN VARCHAR2,
                          p_dbid         IN NUMBER,
                          p_con_dbid     IN NUMBER,
                          p_series_key   IN VARCHAR2,
                          p_exsm_model   IN VARCHAR2,
                          p_seasonality  IN NUMBER,
                          p_data_query   IN CLOB,
                          p_target_col   IN VARCHAR2,
                          p_trained_thru IN DATE,
                          p_purpose      IN VARCHAR2 DEFAULT 'FORECAST');

    -- Drop every OML model this package created (both purposes, and any
    -- leftover <name>_N build) and clear CAP_ML_MODEL.
    PROCEDURE drop_all;

    -- Pipe the per-day fit+forecast for one registered model out of its dynamic
    -- DM$VP<model> result view (name is only known at runtime). Rows cover both
    -- the fitted history (actual not null) and the future horizon (actual null,
    -- prediction = forecast, with lower/upper 95% bounds). CAPF_ESM_FORECAST
    -- lateral-joins this over CAP_ML_MODEL.
    FUNCTION get_forecast(p_model IN VARCHAR2) RETURN cap_esm_tab PIPELINED;

END cap_forecast_ml;
/
