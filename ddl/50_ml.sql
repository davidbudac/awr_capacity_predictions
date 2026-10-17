--
-- ddl/50_ml.sql -- Tier 2 OML ESM: registry table, types, package, views.
-- =====================================================================
-- Persists the model registry (CAP_ML_MODEL), the SQL types the pipelined
-- forecast reader returns, loads the cap_forecast_ml package, then builds the
-- views the report consumes:
--   CAPF_ESM_FORECAST -- per-day fit+forecast for every trained FORECAST model.
--   CAPF_ESM_BACKTEST -- same, for the purpose=BACKTEST truncated models.
--   CAPF_ESM_CANDIDATE-- M10.4 holdout MAPE/bias of EVERY backtest twin, one
--                        row per (series, model_type) -- the evidence
--                        train_tablespaces' AUTO model-type selection reads.
--   CAPF_ESM_HEALTH   -- one row per registry model: status, age, staleness,
--                        last_error. CAPF_ESM_HEALTH_SUMMARY counts the
--                        FORECAST models per container (ok / failed / stale).
--   CAPF_COMPARE      -- Tier 1 REGR point projections vs Tier 2 ESM
--                        predictions, one row per (series, horizon, engine).
--   CAPF_BACKTEST     -- M9.4 holdout accuracy (MAPE/bias) per series per
--                        engine; REGR rows always, ESM rows after
--                        cap_forecast_ml.train_backtest. M10.4: the ESM row is
--                        the SELECTED candidate only, so the view keeps its
--                        one-row-per-(series,engine) shape.
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
        status           VARCHAR2(200),
        purpose          VARCHAR2(10)  DEFAULT ''FORECAST'' NOT NULL,
        model_type       VARCHAR2(20),
        chosen_by        VARCHAR2(20),
        mape_holt        NUMBER,
        mape_addw        NUMBER,
        last_error       VARCHAR2(4000),
        failed_at        DATE
    )';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

-- Upgrade path (M9.4): a registry created before the purpose column existed
-- gains it here. ORA-01430 = column already exists (fresh create above).
DECLARE
BEGIN
    EXECUTE IMMEDIATE
        'ALTER TABLE cap_ml_model ADD (purpose VARCHAR2(10) DEFAULT ''FORECAST'' NOT NULL)';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

-- Upgrade path (M10.4): the model-type selection columns.
--   model_type  which ESM candidate this row is / was trained with
--               ('EXSM_HOLT' | 'EXSM_ADDWINTERS'); mirrors exsm_model.
--   chosen_by   how a FORECAST row's type was decided: AUTO_BACKTEST (lower
--               holdout MAPE won), AUTO_TIE (MAPEs within esm_auto_tie_pct,
--               HOLT kept), CONFIG (esm_tbspc_model pinned it) or DEFAULT
--               (AUTO with esm_select_by_backtest = 0).
--   mape_holt / mape_addw  the two candidates' holdout MAPE% at decision time,
--               so the report can say WHY. NULL on BACKTEST twin rows.
-- Added one at a time: ORA-01430 on any one of them must not skip the rest.
DECLARE
    TYPE cols IS TABLE OF VARCHAR2(200);
    v cols := cols('model_type VARCHAR2(20)',
                   'chosen_by  VARCHAR2(20)',
                   'mape_holt  NUMBER',
                   'mape_addw  NUMBER');
BEGIN
    FOR i IN 1 .. v.COUNT LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE cap_ml_model ADD (' || v(i) || ')';
        EXCEPTION
            WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
        END;
    END LOOP;
    -- Backfill the type for rows registered before the column existed.
    EXECUTE IMMEDIATE 'UPDATE cap_ml_model SET model_type = exsm_model
                        WHERE model_type IS NULL AND exsm_model IS NOT NULL';
    COMMIT;
END;
/

-- Upgrade path (Tier 2 health): a failed build now keeps status = 'FAILED'
-- and puts the error text in last_error, the failure time in failed_at.
-- trained_at / trained_through describe the model that is serving, so they
-- no longer move on a failed attempt. Rows written by the older package
-- carried 'FAILED:<message>' in status; split those once.
DECLARE
    TYPE cols IS TABLE OF VARCHAR2(200);
    v cols := cols('last_error VARCHAR2(4000)',
                   'failed_at  DATE');
BEGIN
    FOR i IN 1 .. v.COUNT LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE cap_ml_model ADD (' || v(i) || ')';
        EXCEPTION
            WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
        END;
    END LOOP;
    EXECUTE IMMEDIATE q'[UPDATE cap_ml_model
                            SET last_error = SUBSTR(status, 8),
                                failed_at  = trained_at,
                                status     = 'FAILED'
                          WHERE status LIKE 'FAILED:%']';
    COMMIT;
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
-- CAPF_ESM_FORECAST -- per-day actual + forecast for every FORECAST model that
-- has an OML model behind it: status OK, or FAILED where an earlier build
-- survived the failed retrain (trained_through NOT NULL; a series that never
-- built has a NULL trained_through). CAPF_ESM_HEALTH says which is which.
-- Lateral join: TABLE(get_forecast(m.model_name)) is correlated to each
-- registry row (implicit LATERAL, 19c).
--   step_days        forecast rows only: days after trained_through (1..30,
--                    the 19c EXSM step cap); NULL on the fitted history.
--   esm_horizon_days the model's furthest step, i.e. MAX(step_days). Below 30
--                    when build_model's FLOOR(rows/4) floor bit (90 rows -> 22).
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
       t.upper_bound,
       m.model_type,                 -- M10.4: which ESM candidate won this series
       m.chosen_by,
       m.mape_holt,
       m.mape_addw,
       m.status,
       CASE WHEN t.actual IS NULL
             AND TRUNC(t.case_id) - TRUNC(m.trained_through) BETWEEN 1 AND 30
            THEN TRUNC(t.case_id) - TRUNC(m.trained_through)
       END                                               AS step_days,
       MAX(CASE WHEN t.actual IS NULL
                 AND TRUNC(t.case_id) - TRUNC(m.trained_through) BETWEEN 1 AND 30
                THEN TRUNC(t.case_id) - TRUNC(m.trained_through)
           END) OVER (PARTITION BY m.model_name)         AS esm_horizon_days
FROM   cap_ml_model m,
       TABLE(cap_forecast_ml.get_forecast(m.model_name)) t
WHERE  m.status IN ('OK', 'FAILED')
  AND  m.trained_through IS NOT NULL
  AND  m.purpose = 'FORECAST';

-- --------------------------------------------------------------------
-- CAPF_ESM_BACKTEST -- same shape, but for the truncated-training models
-- cap_forecast_ml.train_backtest builds (purpose = BACKTEST). Their forecast
-- rows (actual NULL) fall INSIDE the holdout window, where real daily values
-- exist to score them against -- consumed by CAPF_BACKTEST below. Kept out of
-- CAPF_ESM_FORECAST so backtest models never leak into the report's Tier 2
-- forecasts or CAPF_COMPARE. step_days / esm_horizon_days as above (a twin
-- trained on 93 rows reaches +23 at most).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_esm_backtest AS
SELECT m.model_name,
       m.series_kind,
       m.dbid,
       m.con_dbid,
       m.series_key,
       m.trained_through,
       t.case_id      AS day_dt,
       t.actual,
       t.prediction,
       m.model_type,                 -- M10.4: one twin per candidate model type
       m.status,
       CASE WHEN t.actual IS NULL
             AND TRUNC(t.case_id) - TRUNC(m.trained_through) BETWEEN 1 AND 30
            THEN TRUNC(t.case_id) - TRUNC(m.trained_through)
       END                                               AS step_days,
       MAX(CASE WHEN t.actual IS NULL
                 AND TRUNC(t.case_id) - TRUNC(m.trained_through) BETWEEN 1 AND 30
                THEN TRUNC(t.case_id) - TRUNC(m.trained_through)
           END) OVER (PARTITION BY m.model_name)         AS esm_horizon_days
FROM   cap_ml_model m,
       TABLE(cap_forecast_ml.get_forecast(m.model_name)) t
WHERE  m.status IN ('OK', 'FAILED')
  AND  m.trained_through IS NOT NULL
  AND  m.purpose = 'BACKTEST';

-- --------------------------------------------------------------------
-- CAPF_ESM_CANDIDATE (M10.4) -- holdout score of EVERY backtest twin, one row
-- per (series, model_type). This is the EVIDENCE behind ESM model-type
-- selection: cap_forecast_ml.train_tablespaces trains both candidate twins
-- (EXSM_HOLT and EXSM_ADDWINTERS/7) for each tablespace series, reads their
-- mape_pct from here, and builds the production model with the winner.
-- Same scoring as CAPF_BACKTEST's ESM branch -- predictions with actual IS NULL
-- fall inside the holdout window, where the real daily value exists -- but
-- grouped by model_type instead of collapsed to one row per series.
-- CPU series have a single candidate, so they appear here with one row.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_esm_candidate AS
WITH act AS (
        SELECT dbid, con_dbid, 'TBSPC' AS series_kind, tablespace_name AS series_key,
               day_dt, used_bytes AS val
        FROM   capd_tbspc_daily
        UNION ALL
        SELECT dbid, con_dbid, 'CPU', 'BUSY_PCT', day_dt, busy_pct
        FROM   capd_cpu_daily WHERE busy_pct IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'CPU', 'DB_CPU_SEC', day_dt, db_cpu_sec
        FROM   capd_dbtime_daily WHERE db_cpu_sec IS NOT NULL
     )
SELECT h.dbid,
       h.con_dbid,
       h.series_kind,
       h.series_key,
       e.model_type,
       TRUNC(e.trained_through)                      AS cutoff_day,
       COUNT(*)                                      AS n_days,
       AVG(ABS(e.prediction - h.val)
           / NULLIF(ABS(h.val), 0)) * 100            AS mape_pct,
       AVG((e.prediction - h.val)
           / NULLIF(ABS(h.val), 0)) * 100            AS bias_pct
FROM   capf_esm_backtest e
JOIN   act h
  ON   h.dbid = e.dbid AND h.con_dbid = e.con_dbid
 AND   h.series_kind = CASE WHEN e.series_kind = 'TBSPC' THEN 'TBSPC' ELSE 'CPU' END
 AND   h.series_key  = e.series_key
 AND   h.day_dt      = TRUNC(e.day_dt)
WHERE  e.actual IS NULL
GROUP  BY h.dbid, h.con_dbid, h.series_kind, h.series_key,
          e.model_type, TRUNC(e.trained_through);

-- --------------------------------------------------------------------
-- CAPF_ESM_HEALTH -- one row per CAP_ML_MODEL row, so a failed or stale model
-- is visible without reading the registry by hand.
--   status          OK | FAILED | TRAINING (a build in progress, or one whose
--                   session died). FAILED keeps the last good model serving,
--                   if there was one (trained_through NOT NULL).
--   model_age_days  FORECAST: series last day - trained_through.
--                   BACKTEST: (series last day - backtest_holdout_days) -
--                   trained_through, i.e. how far the twin's cutoff lags the
--                   cutoff CAPF_BACKTEST's REGR engine uses today.
--   stale_flag      'Y' when model_age_days > esm_max_age_days. CAPF_COMPARE
--                   drops a stale model's ESM row.
-- The series last day uses the same filters as the Tier 1 last_day (CPU and
-- DB CPU days with a NULL value do not count), so a model trained through the
-- current last day has age 0.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_esm_health AS
WITH m AS (
        SELECT r.model_name, r.series_kind, r.dbid, r.con_dbid, r.series_key,
               r.purpose, r.model_type, r.status, r.trained_through, r.trained_at,
               r.last_error, r.failed_at,
               CASE r.series_kind
                   WHEN 'TBSPC' THEN (SELECT MAX(d.day_dt) FROM capd_tbspc_daily d
                                       WHERE d.dbid = r.dbid AND d.con_dbid = r.con_dbid
                                         AND d.tablespace_name = r.series_key)
                   WHEN 'CPU'   THEN (SELECT MAX(d.day_dt) FROM capd_cpu_daily d
                                       WHERE d.dbid = r.dbid AND d.con_dbid = r.con_dbid
                                         AND d.busy_pct IS NOT NULL)
                   WHEN 'DBCPU' THEN (SELECT MAX(d.day_dt) FROM capd_dbtime_daily d
                                       WHERE d.dbid = r.dbid AND d.con_dbid = r.con_dbid
                                         AND d.db_cpu_sec IS NOT NULL)
               END AS last_day
        FROM   cap_ml_model r
     ),
     a AS (
        SELECT m.*,
               cfg.esm_max_age_days                        AS max_age,
               TRUNC(m.last_day)
                 - CASE WHEN m.purpose = 'BACKTEST' THEN cfg.backtest_holdout_days ELSE 0 END
                 - TRUNC(m.trained_through)                AS age
        FROM   m CROSS JOIN cap_cfg cfg
     )
SELECT a.model_name,
       a.series_kind,
       a.dbid,
       a.con_dbid,
       a.series_key,
       a.purpose,
       a.model_type,
       a.status,
       a.trained_through,
       a.trained_at,
       TRUNC(a.last_day)                                   AS series_last_day,
       a.age                                               AS model_age_days,
       a.max_age                                           AS esm_max_age_days,
       CASE WHEN a.age > a.max_age THEN 'Y' ELSE 'N' END   AS stale_flag,
       a.last_error,
       a.failed_at
FROM   a;

-- --------------------------------------------------------------------
-- CAPF_ESM_HEALTH_SUMMARY -- FORECAST models per container: how many are OK,
-- FAILED (last build failed) and stale. A FAILED model can be stale as well;
-- the counts overlap on purpose. Feeds the report header's Tier 2 line.
-- Backtest twins are left out: they never reach the forecast surface.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_esm_health_summary AS
SELECT dbid,
       con_dbid,
       COUNT(*)                                           AS n_models,
       COUNT(CASE WHEN status = 'OK'     THEN 1 END)      AS n_ok,
       COUNT(CASE WHEN status = 'FAILED' THEN 1 END)      AS n_failed,
       COUNT(CASE WHEN stale_flag = 'Y'  THEN 1 END)      AS n_stale,
       MAX(trained_at)                                    AS last_trained_at,
       MAX(failed_at)                                     AS last_failed_at
FROM   capf_esm_health
WHERE  purpose = 'FORECAST'
GROUP  BY dbid, con_dbid;

-- --------------------------------------------------------------------
-- CAPF_COMPARE -- Tier 1 (REGR) vs Tier 2 (ESM) at matched horizons.
--   engine REGR: point projections from CAPF_TBSPC_FORECAST (+30/90/180/365)
--                and CAPF_CPU_TREND (+30/90). No interval (bounds NULL).
--   engine ESM : prediction + 95% bounds in the 30-day bucket ONLY. Oracle 19c
--                EXSM hard-caps the horizon at 30 steps, so +90/180/365 are
--                unreachable and stay REGR-only. The ESM value is the model's
--                FURTHEST step (esm_horizon_days, <= 30), not exactly +30:
--                build_model's FLOOR(rows/4) floor leaves a 90-row series at
--                +22, and an exact-+30 match would show nothing at all.
--                ESM rows are gated on AGE: model_age_days (series last day -
--                trained_through, from CAPF_ESM_HEALTH) <= esm_max_age_days,
--                so a weekly retrain stays visible all week and a model left
--                behind by a later top-N retrain eventually drops out.
--   esm_horizon_days / model_age_days are NULL on REGR rows. horizon_days is
--   the comparison bucket; the ESM value sits at trained_through +
--   esm_horizon_days, i.e. esm_horizon_days - model_age_days past the series'
--   last day.
-- series_kind is TBSPC or CPU; series_key is the tablespace name or the CPU
-- metric (BUSY_PCT / DB_CPU_SEC) so REGR and ESM rows line up.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_compare AS
-- ---- REGR, tablespace bytes ----
SELECT dbid, con_dbid, 'TBSPC' AS series_kind, tablespace_name AS series_key,
       30 AS horizon_days, 'REGR' AS engine,
       proj_30_bytes AS value, CAST(NULL AS NUMBER) AS lower_bound, CAST(NULL AS NUMBER) AS upper_bound,
       CAST(NULL AS VARCHAR2(20)) AS model_type,
       CAST(NULL AS NUMBER) AS esm_horizon_days, CAST(NULL AS NUMBER) AS model_age_days
FROM   capf_tbspc_forecast WHERE quality <> 'INSUFFICIENT_HISTORY'
UNION ALL
SELECT dbid, con_dbid, 'TBSPC', tablespace_name, 90,  'REGR', proj_90_bytes,  NULL, NULL, NULL, NULL, NULL
FROM   capf_tbspc_forecast WHERE quality <> 'INSUFFICIENT_HISTORY'
UNION ALL
SELECT dbid, con_dbid, 'TBSPC', tablespace_name, 180, 'REGR', proj_180_bytes, NULL, NULL, NULL, NULL, NULL
FROM   capf_tbspc_forecast WHERE quality <> 'INSUFFICIENT_HISTORY'
UNION ALL
SELECT dbid, con_dbid, 'TBSPC', tablespace_name, 365, 'REGR', proj_365_bytes, NULL, NULL, NULL, NULL, NULL
FROM   capf_tbspc_forecast WHERE quality <> 'INSUFFICIENT_HISTORY'
-- ---- REGR, CPU metrics ----
UNION ALL
SELECT dbid, con_dbid, 'CPU', metric, 30, 'REGR', proj_30, NULL, NULL, NULL, NULL, NULL
FROM   capf_cpu_trend WHERE quality <> 'INSUFFICIENT_HISTORY'
UNION ALL
SELECT dbid, con_dbid, 'CPU', metric, 90, 'REGR', proj_90, NULL, NULL, NULL, NULL, NULL
FROM   capf_cpu_trend WHERE quality <> 'INSUFFICIENT_HISTORY'
-- ---- ESM, furthest step <= 30, models no older than esm_max_age_days ----
-- M10.4: model_type rides along so the report can name the winning candidate.
UNION ALL
SELECT e.dbid, e.con_dbid,
       CASE WHEN e.series_kind = 'TBSPC' THEN 'TBSPC' ELSE 'CPU' END,
       e.series_key, 30, 'ESM', e.prediction, e.lower_bound, e.upper_bound,
       e.model_type, e.esm_horizon_days, h.model_age_days
FROM   capf_esm_forecast e
JOIN   capf_esm_health h
  ON   h.model_name = e.model_name
WHERE  e.step_days = e.esm_horizon_days
  AND  h.model_age_days <= h.esm_max_age_days;

-- --------------------------------------------------------------------
-- CAPF_BACKTEST (M9.4) -- holdout accuracy per series per engine.
-- Protocol: hide the last backtest_holdout_days of each series, fit on the
-- train_days window ENDING at that cutoff, then score predictions against the
-- held-out actuals:
--   engine REGR : the linear fit is recomputed here in pure SQL on the
--                 truncated window -- always available, no models needed.
--   engine ESM  : rows appear after EXEC cap_forecast_ml.train_backtest
--                 (or train_all, which refreshes the twins of the series it
--                 trains), which trains purpose=BACKTEST models through the
--                 same cutoff; their forecast rows land inside the holdout.
--                 NOTE: ESM may cover fewer than holdout_days days (the 19c
--                 30-step cap and the rows/4 conservative floor) -- n_days
--                 says how many days each engine was actually scored on.
-- Metrics (over scored days): mape_pct = AVG(|pred-actual| / actual) * 100,
-- bias_pct = AVG((pred-actual) / actual) * 100 (positive = engine
-- over-forecast). series_kind is TBSPC or CPU (DBCPU folds into CPU with
-- series_key DB_CPU_SEC, matching CAPF_COMPARE).
--
-- M10.4: a tablespace series now has TWO backtest twins (one per candidate
-- model type). To keep this view's one-row-per-(series, engine) shape, the ESM
-- row reports the SELECTED candidate -- the one the production model was built
-- with -- and the new model_type column names it. Per-candidate scores live in
-- CAPF_ESM_CANDIDATE. If no production model exists yet (twins trained but
-- train_tablespaces not run), the best-MAPE candidate stands in, ties to
-- EXSM_HOLT, so the section-6c verdict is never arbitrary.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_backtest AS
WITH act AS (
        SELECT dbid, con_dbid, 'TBSPC' AS series_kind, tablespace_name AS series_key,
               day_dt, used_bytes AS val
        FROM   capd_tbspc_daily
        UNION ALL
        SELECT dbid, con_dbid, 'CPU', 'BUSY_PCT', day_dt, busy_pct
        FROM   capd_cpu_daily WHERE busy_pct IS NOT NULL
        UNION ALL
        SELECT dbid, con_dbid, 'CPU', 'DB_CPU_SEC', day_dt, db_cpu_sec
        FROM   capd_dbtime_daily WHERE db_cpu_sec IS NOT NULL
     ),
     b AS (
        SELECT a.*,
               a.day_dt - DATE '2020-01-01' AS day_n,
               MAX(a.day_dt) OVER (PARTITION BY a.dbid, a.con_dbid,
                                   a.series_kind, a.series_key) AS last_day
        FROM   act a
     ),
     fit AS (
        SELECT b.dbid, b.con_dbid, b.series_kind, b.series_key,
               MAX(b.last_day) - cfg.backtest_holdout_days AS cutoff_day,
               cfg.backtest_holdout_days                   AS holdout_days,
               REGR_SLOPE(b.val, b.day_n)                  AS slope,
               REGR_INTERCEPT(b.val, b.day_n)              AS icept,
               REGR_COUNT(b.val, b.day_n)                  AS n_train
        FROM   b CROSS JOIN cap_cfg cfg
        WHERE  b.day_dt <= b.last_day - cfg.backtest_holdout_days
          AND  b.day_dt >  b.last_day - cfg.backtest_holdout_days - cfg.train_days
        GROUP  BY b.dbid, b.con_dbid, b.series_kind, b.series_key, cfg.backtest_holdout_days
     )
-- ---- REGR: score the truncated linear fit over the holdout actuals ----
SELECT h.dbid, h.con_dbid, h.series_kind, h.series_key,
       'REGR'                                        AS engine,
       f.cutoff_day,
       f.holdout_days,
       f.n_train,
       COUNT(*)                                      AS n_days,
       AVG(ABS(f.icept + f.slope * h.day_n - h.val)
           / NULLIF(ABS(h.val), 0)) * 100            AS mape_pct,
       AVG((f.icept + f.slope * h.day_n - h.val)
           / NULLIF(ABS(h.val), 0)) * 100            AS bias_pct,
       CAST(NULL AS VARCHAR2(20))                    AS model_type
FROM   b h
JOIN   fit f
  ON   f.dbid = h.dbid AND f.con_dbid = h.con_dbid
 AND   f.series_kind = h.series_kind AND f.series_key = h.series_key
WHERE  h.day_dt > f.cutoff_day
  AND  f.slope IS NOT NULL
GROUP  BY h.dbid, h.con_dbid, h.series_kind, h.series_key,
          f.cutoff_day, f.holdout_days, f.n_train
UNION ALL
-- ---- ESM: the SELECTED candidate's holdout score (M9.4 / M10.4) ----
-- CAPF_ESM_CANDIDATE already did the per-twin scoring; the pick is the twin
-- whose model_type matches this series' production model, else the lowest
-- MAPE, else EXSM_HOLT.
SELECT c.dbid, c.con_dbid, c.series_kind, c.series_key,
       'ESM'                                         AS engine,
       c.cutoff_day,
       (SELECT backtest_holdout_days FROM cap_cfg)   AS holdout_days,
       CAST(NULL AS NUMBER)                          AS n_train,
       c.n_days,
       c.mape_pct,
       c.bias_pct,
       c.model_type
FROM   (SELECT cc.*,
               ROW_NUMBER() OVER (PARTITION BY cc.dbid, cc.con_dbid,
                                               cc.series_kind, cc.series_key
                                  ORDER BY CASE WHEN cc.model_type = p.model_type
                                                THEN 0 ELSE 1 END,
                                           cc.mape_pct ASC NULLS LAST,
                                           CASE cc.model_type
                                                WHEN 'EXSM_HOLT' THEN 0 ELSE 1 END)
                                                     AS pick_rank
        FROM   capf_esm_candidate cc
        LEFT   JOIN cap_ml_model p
          ON   p.purpose = 'FORECAST'
         AND   p.dbid = cc.dbid AND p.con_dbid = cc.con_dbid
         AND   p.series_key = cc.series_key) c
WHERE  c.pick_rank = 1;
