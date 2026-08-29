--
-- ml/cap_forecast_ml.pkb -- Tier 2 OML exponential-smoothing forecaster (body).
-- =====================================================================
-- See the spec for the contract. Design notes:
--   * One OML model per series (19c has no partitioned ESM). Model name is a
--     stable MD5 of (dbid | con_dbid | series_key), prefixed with a letter so
--     it is a legal identifier and re-training rebuilds the same name in place.
--     dbid is in the hash so two databases with a colliding con_dbid + series
--     name (warehouse / migration) get distinct models. M10.4: the BACKTEST
--     tablespace twins hash (... | model_type) as well, because there is now
--     one twin per candidate model type.
--   * data_query is built as literal-embedded text per series because
--     CREATE_MODEL2's data_query cannot bind. Series keys here are Oracle
--     identifiers (tablespace names / fixed metric strings), so simple
--     quote-doubling is sufficient and injection-safe.
--   * Every train wraps CREATE_MODEL2 so one bad series (e.g. too few points
--     for Holt-Winters) records status='FAILED:...' in CAP_ML_MODEL and the
--     rest still train.
--   * M10.4 quality gate: only series whose Tier 1 fit is OK / LOW_CONFIDENCE
--     are trained at all. A FLAT or INSUFFICIENT_HISTORY series has nothing for
--     ESM to learn, and training it only burns time and pollutes section 6.
--   * M10.4 model-type selection: with esm_tbspc_model = 2 (AUTO) and
--     esm_select_by_backtest = 1 (both defaults) each tablespace series gets
--     BOTH candidate backtest twins (EXSM_HOLT and EXSM_ADDWINTERS/7); the
--     production model is then trained with whichever candidate scored the
--     lower holdout MAPE in CAPF_ESM_CANDIDATE (ties -> HOLT). The decision and
--     both MAPEs are recorded on the production row (model_type / chosen_by /
--     mape_holt / mape_addw) so the report can explain the pick.
--
CREATE OR REPLACE PACKAGE BODY cap_forecast_ml AS

    g_pred_step  CONSTANT PLS_INTEGER := 30;   -- default; overridden from CAP_CONFIG below
    -- Oracle 19c EXSM caps EXSM_PREDICTION_STEP at a HARD 30 regardless of series
    -- length (verified: 30 ok, 31 fails at 121/300/600 rows). Never request more.
    g_step_max   CONSTANT PLS_INTEGER := 30;
    g_conf       CONSTANT VARCHAR2(8) := '0.95';

    -- M10.4 candidate model types for a tablespace series.
    c_holt       CONSTANT VARCHAR2(20) := 'EXSM_HOLT';
    c_addw       CONSTANT VARCHAR2(20) := 'EXSM_ADDWINTERS';
    c_addw_seas  CONSTANT NUMBER       := 7;   -- weekly season

    -- Tier 1 qualities a series must have before it is worth an ESM model.
    -- (Kept as two literals rather than a knob: FLAT / INSUFFICIENT_HISTORY are
    --  definitionally unlearnable, not a matter of taste.)

    -- ----------------------------------------------------------------
    -- model_name for a series: letter prefix + 16 hex of MD5(identity).
    -- Identity includes dbid so a con_dbid+key collision across databases
    -- (warehouse / DBID migration) does not overwrite another db's model.
    -- ----------------------------------------------------------------
    FUNCTION model_name_for(p_prefix IN VARCHAR2,
                            p_dbid IN NUMBER,
                            p_con_dbid IN NUMBER,
                            p_series_key IN VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(30);
    BEGIN
        -- STANDARD_HASH is SQL-only, so resolve via a scalar SELECT.
        SELECT p_prefix || '_' ||
               SUBSTR(STANDARD_HASH(TO_CHAR(p_dbid) || '|' || TO_CHAR(p_con_dbid) || '|' || p_series_key, 'MD5'), 1, 16)
          INTO v FROM dual;
        RETURN v;
    END;

    FUNCTION cfg_num(p_name IN VARCHAR2, p_default IN NUMBER) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        SELECT cfg_value INTO v FROM cap_config WHERE cfg_name = p_name;
        RETURN v;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN p_default;
    END;

    -- ----------------------------------------------------------------
    -- Drop one OML model + its registry row. Used by the twin purge below and
    -- by drop_all's orphan sweep.
    -- ----------------------------------------------------------------
    PROCEDURE drop_one(p_model IN VARCHAR2) IS
    BEGIN
        BEGIN
            DBMS_DATA_MINING.DROP_MODEL(p_model, force => TRUE);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        DELETE FROM cap_ml_model WHERE model_name = p_model;
        COMMIT;
    END drop_one;

    -- ----------------------------------------------------------------
    -- M10.4: remove BACKTEST twins of ONE series that are not in the current
    -- candidate set -- e.g. the single pre-M10.4 twin, whose name hashed the
    -- series key WITHOUT the model type. Without this a stale twin would keep
    -- scoring in CAPF_ESM_CANDIDATE forever.
    -- ----------------------------------------------------------------
    PROCEDURE purge_twins(p_dbid       IN NUMBER,
                          p_con_dbid   IN NUMBER,
                          p_series_key IN VARCHAR2,
                          p_keep1      IN VARCHAR2,
                          p_keep2      IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        FOR s IN (SELECT model_name FROM cap_ml_model
                  WHERE  purpose = 'BACKTEST'
                    AND  dbid = p_dbid AND con_dbid = p_con_dbid
                    AND  series_key = p_series_key
                    AND  model_name NOT IN (p_keep1, NVL(p_keep2, p_keep1))) LOOP
            drop_one(s.model_name);
        END LOOP;
    END purge_twins;

    -- ----------------------------------------------------------------
    -- Core: register + (re)build one ESM model. Isolates all failure so a
    -- single bad series never aborts a batch train.
    -- ----------------------------------------------------------------
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
                          p_purpose      IN VARCHAR2 DEFAULT 'FORECAST') IS
        l_set   DBMS_DATA_MINING.SETTING_LIST;
        l_err   VARCHAR2(200);
        l_rows  PLS_INTEGER;
        l_step  PLS_INTEGER;
    BEGIN
        -- Oracle 19c EXSM caps the horizon at a HARD 30 steps (ORA-40206 above
        -- that at any series length). Also keep it <= FLOOR(rows/4) as a
        -- conservative floor for short series. Never exceeds g_step_max, so ESM
        -- forecasts only ever reach +30 days; +90/180/365 stay REGR-only.
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (' || p_data_query || ')' INTO l_rows;
        l_step := GREATEST(1, LEAST(cfg_num('esm_prediction_step', g_pred_step),
                                    g_step_max, FLOOR(l_rows / 4)));
        -- model_type mirrors exsm_model: it is the M10.4 "which candidate is
        -- this" label the registry, CAPF_* views and the report all key off.
        -- chosen_by / mape_* are cleared here and (re)stamped by the caller, so
        -- a rationale can never survive a train that did not produce it.
        MERGE INTO cap_ml_model m
        USING (SELECT p_model AS model_name FROM dual) s
        ON (m.model_name = s.model_name)
        WHEN MATCHED THEN UPDATE SET
            series_kind = p_series_kind, dbid = p_dbid, con_dbid = p_con_dbid,
            series_key = p_series_key, exsm_model = p_exsm_model,
            seasonality = p_seasonality, trained_through = p_trained_thru,
            trained_at = SYSDATE, status = 'TRAINING', purpose = p_purpose,
            model_type = p_exsm_model, chosen_by = NULL,
            mape_holt = NULL, mape_addw = NULL
        WHEN NOT MATCHED THEN INSERT
            (model_name, series_kind, dbid, con_dbid, series_key, exsm_model,
             seasonality, trained_through, trained_at, status, purpose, model_type)
            VALUES
            (p_model, p_series_kind, p_dbid, p_con_dbid, p_series_key, p_exsm_model,
             p_seasonality, p_trained_thru, SYSDATE, 'TRAINING', p_purpose, p_exsm_model);
        COMMIT;

        -- Drop any prior model of this name (ignore "does not exist").
        BEGIN
            DBMS_DATA_MINING.DROP_MODEL(p_model, force => TRUE);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        l_set('ALGO_NAME')             := 'ALGO_EXPONENTIAL_SMOOTHING';
        l_set('EXSM_MODEL')            := p_exsm_model;
        l_set('EXSM_INTERVAL')         := 'EXSM_INTERVAL_DAY';
        l_set('EXSM_PREDICTION_STEP')  := TO_CHAR(l_step);
        l_set('EXSM_SETMISSING')       := 'EXSM_MISS_AUTO';
        l_set('EXSM_CONFIDENCE_LEVEL') := g_conf;
        IF p_seasonality IS NOT NULL THEN
            l_set('EXSM_SEASONALITY')  := TO_CHAR(p_seasonality);
        END IF;

        DBMS_DATA_MINING.CREATE_MODEL2(
            model_name          => p_model,
            mining_function     => 'TIME_SERIES',
            data_query          => p_data_query,
            set_list            => l_set,
            case_id_column_name => 'DAY_DT',
            target_column_name  => p_target_col);

        UPDATE cap_ml_model SET status = 'OK', trained_at = SYSDATE
        WHERE  model_name = p_model;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            l_err := SUBSTR('FAILED:' || SQLERRM, 1, 200);   -- SQLERRM not allowed inside SQL
            UPDATE cap_ml_model
               SET status = l_err, trained_at = SYSDATE
             WHERE model_name = p_model;
            COMMIT;
    END build_model;

    -- ----------------------------------------------------------------
    -- M9.4 / M10.4: BACKTEST twins for the tablespace series -- one per
    -- candidate model type. Same series selection (and M10.4 quality gate) as
    -- train_tablespaces, each data_query truncated at
    --   cutoff = series last day - holdout
    -- so the twins' forecast rows land inside the holdout window where real
    -- values exist. Split out of train_backtest so train_tablespaces can reuse
    -- it for AUTO selection without also rebuilding the CPU twins.
    -- ----------------------------------------------------------------
    PROCEDURE backtest_tbspc(p_top_n IN NUMBER, p_holdout_days IN NUMBER) IS
        v_hold   NUMBER := NVL(p_holdout_days, cfg_num('backtest_holdout_days', 28));
        v_min    NUMBER := cfg_num('min_train_days', 14);
        v_mh     VARCHAR2(30);
        v_mw     VARCHAR2(30);
        v_key    VARCHAR2(4000);
        v_cut    DATE;
        v_q      CLOB;
    BEGIN
        FOR r IN (
            SELECT dbid, con_dbid, tablespace_name, last_day, train_n
            FROM   capf_tbspc_forecast
            WHERE  train_n >= v_min
              AND  quality IN ('OK', 'LOW_CONFIDENCE')
            ORDER  BY CASE WHEN days_to_full IS NULL THEN 1 ELSE 0 END,
                      days_to_full ASC,
                      cur_used DESC
            FETCH FIRST p_top_n ROWS ONLY
        ) LOOP
            v_key := r.tablespace_name;
            v_cut := r.last_day - v_hold;
            v_mh  := model_name_for('CBTT', r.dbid, r.con_dbid, v_key || '|' || c_holt);
            v_mw  := model_name_for('CBTT', r.dbid, r.con_dbid, v_key || '|' || c_addw);
            purge_twins(r.dbid, r.con_dbid, v_key, v_mh, v_mw);

            v_q := 'SELECT day_dt, used_bytes FROM capd_tbspc_daily'
                || ' WHERE dbid=' || r.dbid
                || ' AND con_dbid=' || r.con_dbid
                || ' AND tablespace_name=''' || REPLACE(v_key, '''', '''''') || ''''
                || ' AND day_dt <= DATE ''' || TO_CHAR(v_cut, 'YYYY-MM-DD') || '''';

            build_model(v_mh, 'TBSPC', r.dbid, r.con_dbid, v_key,
                        c_holt, NULL, v_q, 'USED_BYTES', v_cut, 'BACKTEST');
            build_model(v_mw, 'TBSPC', r.dbid, r.con_dbid, v_key,
                        c_addw, c_addw_seas, v_q, 'USED_BYTES', v_cut, 'BACKTEST');
        END LOOP;
    END backtest_tbspc;

    -- ----------------------------------------------------------------
    -- BACKTEST twins for the two CPU series. Single candidate
    -- (EXSM_ADDWINTERS/7 -- CPU really is weekly-seasonal), so no selection.
    -- ----------------------------------------------------------------
    PROCEDURE backtest_cpu(p_holdout_days IN NUMBER) IS
        v_hold  NUMBER := NVL(p_holdout_days, cfg_num('backtest_holdout_days', 28));
        v_model VARCHAR2(30);
        v_cut   DATE;
        v_q     CLOB;
    BEGIN
        -- host busy%
        FOR r IN (SELECT dbid, con_dbid, last_day FROM capf_cpu_trend
                  WHERE  metric = 'BUSY_PCT' AND quality IN ('OK', 'LOW_CONFIDENCE')) LOOP
            v_cut   := r.last_day - v_hold;
            v_model := model_name_for('CBTC', r.dbid, r.con_dbid, 'BUSY_PCT');
            v_q := 'SELECT day_dt, busy_pct FROM capd_cpu_daily'
                || ' WHERE dbid=' || r.dbid || ' AND con_dbid=' || r.con_dbid
                || ' AND busy_pct IS NOT NULL'
                || ' AND day_dt <= DATE ''' || TO_CHAR(v_cut, 'YYYY-MM-DD') || '''';
            build_model(v_model, 'CPU', r.dbid, r.con_dbid, 'BUSY_PCT',
                        c_addw, c_addw_seas, v_q, 'BUSY_PCT', v_cut, 'BACKTEST');
        END LOOP;

        -- DB CPU seconds/day
        FOR r IN (SELECT dbid, con_dbid, last_day FROM capf_cpu_trend
                  WHERE  metric = 'DB_CPU_SEC' AND quality IN ('OK', 'LOW_CONFIDENCE')) LOOP
            v_cut   := r.last_day - v_hold;
            v_model := model_name_for('CBTD', r.dbid, r.con_dbid, 'DB_CPU_SEC');
            v_q := 'SELECT day_dt, db_cpu_sec FROM capd_dbtime_daily'
                || ' WHERE dbid=' || r.dbid || ' AND con_dbid=' || r.con_dbid
                || ' AND db_cpu_sec IS NOT NULL'
                || ' AND day_dt <= DATE ''' || TO_CHAR(v_cut, 'YYYY-MM-DD') || '''';
            build_model(v_model, 'DBCPU', r.dbid, r.con_dbid, 'DB_CPU_SEC',
                        c_addw, c_addw_seas, v_q, 'DB_CPU_SEC', v_cut, 'BACKTEST');
        END LOOP;
    END backtest_cpu;

    -- ----------------------------------------------------------------
    -- Holdout MAPE of one candidate twin, or NULL when it did not train / did
    -- not cover a single holdout day.
    -- ----------------------------------------------------------------
    FUNCTION candidate_mape(p_dbid IN NUMBER, p_con_dbid IN NUMBER,
                            p_series_key IN VARCHAR2, p_model_type IN VARCHAR2)
             RETURN NUMBER IS
        v NUMBER;
    BEGIN
        -- Dynamic ON PURPOSE. CAPF_ESM_CANDIDATE is created in ddl/50_ml AFTER
        -- this package (it reads get_forecast(), so it cannot exist earlier); a
        -- static reference would leave the body INVALID on a fresh install and
        -- trip install.sql's compile-error trap. Resolved at first call instead.
        EXECUTE IMMEDIATE
            'SELECT mape_pct FROM capf_esm_candidate' ||
            ' WHERE dbid = :1 AND con_dbid = :2 AND series_kind = ''TBSPC''' ||
            '   AND series_key = :3 AND model_type = :4'
            INTO v USING p_dbid, p_con_dbid, p_series_key, p_model_type;
        RETURN v;
    EXCEPTION WHEN OTHERS THEN RETURN NULL;   -- no row / >1 cutoff / model gone
    END candidate_mape;

    -- ----------------------------------------------------------------
    PROCEDURE train_tablespaces(p_top_n IN NUMBER DEFAULT 20) IS
        v_model  VARCHAR2(30);
        v_q      CLOB;
        v_key    VARCHAR2(4000);
        v_min    NUMBER := cfg_num('min_train_days', 14);   -- packaged fn can't be called inside SQL
        -- M10.4 knobs: 0 = always EXSM_HOLT, 1 = always EXSM_ADDWINTERS(7),
        -- 2 = AUTO (pick by backtest). esm_select_by_backtest = 0 turns the
        -- (expensive: 2 extra models per series) selection off, leaving AUTO to
        -- fall back to the historical default, EXSM_HOLT.
        v_mode   NUMBER := cfg_num('esm_tbspc_model', 2);
        v_sel    NUMBER := cfg_num('esm_select_by_backtest', 1);
        v_auto   BOOLEAN;
        v_type   VARCHAR2(20);
        v_seas   NUMBER;
        v_chosen VARCHAR2(20);
        v_mh     NUMBER;
        v_mw     NUMBER;
    BEGIN
        v_auto := (v_mode = 2 AND v_sel = 1);

        -- AUTO: build both candidates' holdout twins first, so CAPF_ESM_CANDIDATE
        -- has a MAPE per candidate by the time we choose below.
        IF v_auto THEN
            backtest_tbspc(p_top_n, NULL);
        END IF;

        FOR r IN (
            SELECT dbid, con_dbid, tablespace_name, last_day, train_n
            FROM   capf_tbspc_forecast
            WHERE  train_n >= v_min
              -- M10.4 quality gate: FLAT / INSUFFICIENT_HISTORY series are
              -- never worth a model (and would crowd out real ones in top-N).
              AND  quality IN ('OK', 'LOW_CONFIDENCE')
            ORDER  BY CASE WHEN days_to_full IS NULL THEN 1 ELSE 0 END,
                      days_to_full ASC,
                      cur_used DESC
            FETCH FIRST p_top_n ROWS ONLY
        ) LOOP
            v_key   := r.tablespace_name;
            v_model := model_name_for('CAPT', r.dbid, r.con_dbid, v_key);
            v_mh    := NULL;
            v_mw    := NULL;

            IF v_auto THEN
                v_mh := candidate_mape(r.dbid, r.con_dbid, v_key, c_holt);
                v_mw := candidate_mape(r.dbid, r.con_dbid, v_key, c_addw);
                -- Lower MAPE wins; ties (and "no evidence") go to HOLT, the
                -- historical default and the cheaper model.
                IF v_mw IS NOT NULL AND (v_mh IS NULL OR v_mw < v_mh) THEN
                    v_type := c_addw; v_seas := c_addw_seas;
                ELSE
                    v_type := c_holt; v_seas := NULL;
                END IF;
                v_chosen := 'AUTO_BACKTEST';
            ELSIF v_mode = 1 THEN
                v_type := c_addw; v_seas := c_addw_seas; v_chosen := 'CONFIG';
            ELSE
                v_type := c_holt; v_seas := NULL;
                v_chosen := CASE WHEN v_mode = 2 THEN 'DEFAULT' ELSE 'CONFIG' END;
            END IF;

            v_q := 'SELECT day_dt, used_bytes FROM capd_tbspc_daily'
                || ' WHERE dbid=' || r.dbid
                || ' AND con_dbid=' || r.con_dbid
                || ' AND tablespace_name=''' || REPLACE(v_key, '''', '''''') || '''';
            build_model(v_model, 'TBSPC', r.dbid, r.con_dbid, v_key,
                        v_type, v_seas, v_q, 'USED_BYTES', r.last_day);

            -- Record the decision + its evidence on the production row (see
            -- CAPR_BACKTEST.esm_pick, report section 6c).
            UPDATE cap_ml_model
               SET chosen_by = v_chosen, mape_holt = v_mh, mape_addw = v_mw
             WHERE model_name = v_model;
            COMMIT;
        END LOOP;
    END train_tablespaces;

    -- ----------------------------------------------------------------
    PROCEDURE train_cpu IS
        v_model VARCHAR2(30);
        v_q     CLOB;
    BEGIN
        -- host busy% : Holt-Winters additive, weekly season. M10.4: only where
        -- the Tier 1 CPU fit is OK / LOW_CONFIDENCE.
        FOR r IN (SELECT dbid, con_dbid, last_day FROM capf_cpu_trend
                  WHERE  metric = 'BUSY_PCT' AND quality IN ('OK', 'LOW_CONFIDENCE')) LOOP
            v_model := model_name_for('CAPC', r.dbid, r.con_dbid, 'BUSY_PCT');
            v_q := 'SELECT day_dt, busy_pct FROM capd_cpu_daily'
                || ' WHERE dbid=' || r.dbid || ' AND con_dbid=' || r.con_dbid
                || ' AND busy_pct IS NOT NULL';
            build_model(v_model, 'CPU', r.dbid, r.con_dbid, 'BUSY_PCT',
                        c_addw, c_addw_seas, v_q, 'BUSY_PCT', r.last_day);
        END LOOP;

        -- DB CPU seconds/day : Holt-Winters additive, weekly season.
        FOR r IN (SELECT dbid, con_dbid, last_day FROM capf_cpu_trend
                  WHERE  metric = 'DB_CPU_SEC' AND quality IN ('OK', 'LOW_CONFIDENCE')) LOOP
            v_model := model_name_for('CAPD', r.dbid, r.con_dbid, 'DB_CPU_SEC');
            v_q := 'SELECT day_dt, db_cpu_sec FROM capd_dbtime_daily'
                || ' WHERE dbid=' || r.dbid || ' AND con_dbid=' || r.con_dbid
                || ' AND db_cpu_sec IS NOT NULL';
            build_model(v_model, 'DBCPU', r.dbid, r.con_dbid, 'DB_CPU_SEC',
                        c_addw, c_addw_seas, v_q, 'DB_CPU_SEC', r.last_day);
        END LOOP;
    END train_cpu;

    -- ----------------------------------------------------------------
    PROCEDURE train_all(p_top_n IN NUMBER DEFAULT 20) IS
    BEGIN
        train_tablespaces(p_top_n);   -- trains the candidate twins too when AUTO
        train_cpu;
    END train_all;

    -- ----------------------------------------------------------------
    -- M9.4: purpose=BACKTEST twins, trained with the holdout HIDDEN.
    -- M10.4: one twin per candidate model type for tablespaces.
    -- Distinct CBT* prefixes keep the twins' names apart from the CAP* forecast
    -- models. Note the 19c step caps in build_model: ESM may cover fewer than
    -- holdout_days forecast days; CAPF_BACKTEST scores whatever is covered.
    -- ----------------------------------------------------------------
    PROCEDURE train_backtest(p_top_n        IN NUMBER DEFAULT 20,
                             p_holdout_days IN NUMBER DEFAULT NULL) IS
    BEGIN
        backtest_tbspc(p_top_n, p_holdout_days);
        backtest_cpu(p_holdout_days);
    END train_backtest;

    -- ----------------------------------------------------------------
    PROCEDURE drop_all IS
    BEGIN
        FOR r IN (SELECT model_name FROM cap_ml_model) LOOP
            BEGIN
                DBMS_DATA_MINING.DROP_MODEL(r.model_name, force => TRUE);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
        END LOOP;
        DELETE FROM cap_ml_model;
        COMMIT;

        -- Orphan sweep: an OML model whose registry row was lost (a manual
        -- DELETE, or a pre-M10.4 twin whose name changed) would otherwise
        -- linger forever. Only this suite's own name shapes are touched --
        -- <prefix>_<16 hex> for the six prefixes the package ever mints.
        BEGIN
            FOR m IN (SELECT model_name FROM user_mining_models
                      WHERE  REGEXP_LIKE(model_name,
                             '^(CAPT|CAPC|CAPD|CBTT|CBTC|CBTD)_[0-9A-F]{16}$')) LOOP
                BEGIN
                    DBMS_DATA_MINING.DROP_MODEL(m.model_name, force => TRUE);
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END LOOP;
        EXCEPTION WHEN OTHERS THEN NULL;   -- no data-dictionary access: skip
        END;
    END drop_all;

    -- ----------------------------------------------------------------
    FUNCTION get_forecast(p_model IN VARCHAR2) RETURN cap_esm_tab PIPELINED IS
        TYPE ref_cur IS REF CURSOR;
        c      ref_cur;
        v_sql  VARCHAR2(4000);
        v_cid  DATE;
        v_val  NUMBER;
        v_pred NUMBER;
        v_low  NUMBER;
        v_up   NUMBER;
    BEGIN
        -- DM$VP<model> is the ESM result view: one row per interval with the
        -- fitted VALUE (history) or forecast PREDICTION (future) + bounds.
        -- p_model is concatenated into the view name, so validate it as a simple
        -- SQL name (defense-in-depth: CAPF_ESM_FORECAST always passes a registry
        -- name, but the function is directly callable). A bad name raises
        -- ORA-44003, caught below -> yields nothing.
        v_sql := 'SELECT case_id, value, prediction, lower, upper'
              || ' FROM DM$VP' || DBMS_ASSERT.SIMPLE_SQL_NAME(p_model) || ' ORDER BY case_id';
        OPEN c FOR v_sql;
        LOOP
            FETCH c INTO v_cid, v_val, v_pred, v_low, v_up;
            EXIT WHEN c%NOTFOUND;
            PIPE ROW(cap_esm_row(v_cid, v_val, v_pred, v_low, v_up));
        END LOOP;
        CLOSE c;
        RETURN;
    EXCEPTION
        WHEN OTHERS THEN
            -- Model not trained / view absent: yield nothing (report skips it).
            BEGIN IF c%ISOPEN THEN CLOSE c; END IF; EXCEPTION WHEN OTHERS THEN NULL; END;
            RETURN;
    END get_forecast;

END cap_forecast_ml;
/
