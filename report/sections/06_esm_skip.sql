--
-- 06_esm_skip.sql -- stub used when show_esm='N'. Prints a note, no query.
--
PROMPT
PROMPT == 6. TIER 2 (ESM) vs TIER 1 (REGR) ==
PROMPT    Skipped: either show_esm=N, or show_esm=AUTO with no ESM models trained.
PROMPT    Run  EXEC cap_forecast_ml.train_all  then re-run the report (or set
PROMPT    show_esm='Y' to force the (empty) table). The 6c holdout backtest
PROMPT    (REGR accuracy needs no models) is queryable any time: CAPF_BACKTEST.
