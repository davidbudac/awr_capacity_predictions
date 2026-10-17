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
--   * build_model builds under <name>_N and swaps the result in only after
--     CREATE_MODEL2 succeeded. A failure records status 'FAILED', last_error
--     and failed_at on the registry row and leaves the previous model (and the
--     row's description of it) in place, so one bad series never aborts a
--     batch and never destroys the last good model. The public train_*
--     procedures raise ORA-20060 at the end if a FORECAST build failed.
--   * M10.4 quality gate: only series whose Tier 1 fit is OK / LOW_CONFIDENCE
--     are trained at all. A FLAT or INSUFFICIENT_HISTORY series has nothing for
--     ESM to learn, and training it only burns time and pollutes section 6.
--   * M10.4 model-type selection: with esm_tbspc_model = 2 (AUTO) and
--     esm_select_by_backtest = 1 (both defaults) each tablespace series gets
--     BOTH candidate backtest twins (EXSM_HOLT and EXSM_ADDWINTERS/7); the
--     production model is then trained with whichever candidate scored the
--     lower holdout MAPE in CAPF_ESM_CANDIDATE. MAPEs closer than
--     esm_auto_tie_pct points tie and keep HOLT (chosen_by AUTO_TIE). The
--     decision and both MAPEs are recorded on the production row (model_type /
--     chosen_by / mape_holt / mape_addw) so the report can explain the pick.
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

    -- A retrain builds <name>_N beside the serving model, then swaps it in.
    c_tmp_sfx    CONSTANT VARCHAR2(2)  := '_N';

    -- FORECAST builds attempted / failed since the last public train_* call.
    g_fc_built   PLS_INTEGER := 0;
    g_fc_failed  PLS_INTEGER := 0;

    -- Tablespaces eligible for a model, most capacity-critical first. p_name /
    -- p_con_dbid narrow it to one series for train_tablespace.
    CURSOR c_tbspc(p_top_n IN NUMBER, p_name IN VARCHAR2,
                   p_con_dbid IN NUMBER, p_min IN NUMBER) IS
        SELECT dbid, con_dbid, tablespace_name, last_day
        FROM   capf_tbspc_forecast
        WHERE  train_n >= p_min
          -- M10.4 quality gate: FLAT / INSUFFICIENT_HISTORY series are
          -- never worth a model (and would crowd out real ones in top-N).
          AND  quality IN ('OK', 'LOW_CONFIDENCE')
          AND  (p_name IS NULL OR tablespace_name = p_name)
          AND  (p_con_dbid IS NULL OR con_dbid = p_con_dbid)
        ORDER  BY CASE WHEN days_to_full IS NULL THEN 1 ELSE 0 END,
                  days_to_full ASC,
                  cur_used DESC
        FETCH FIRST p_top_n ROWS ONLY;

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

    -- AUTO model-type selection for tablespaces is on (both knobs at default).
    FUNCTION auto_select RETURN BOOLEAN IS
    BEGIN
        RETURN cfg_num('esm_tbspc_model', 2) = 2
           AND cfg_num('esm_select_by_backtest', 1) = 1;
    END;

    PROCEDURE reset_counts IS
    BEGIN
        g_fc_built  := 0;
        g_fc_failed := 0;
    END;

    PROCEDURE raise_if_failed IS
    BEGIN
        IF g_fc_failed > 0 THEN
            RAISE_APPLICATION_ERROR(-20060,
                'cap_forecast_ml: ' || g_fc_failed || ' of ' || g_fc_built
                || ' forecast model build(s) failed; see CAPF_ESM_HEALTH.last_error');
        END IF;
    END;

    -- Cleanup only: a model that cannot be dropped is not worth failing for.
    PROCEDURE drop_quiet(p_model IN VARCHAR2) IS
    BEGIN
        DBMS_DATA_MINING.DROP_MODEL(p_model, force => TRUE);
    EXCEPTION WHEN OTHERS THEN NULL;
    END drop_quiet;

    -- ----------------------------------------------------------------
    -- Drop one OML model (and any half-built <name>_N) + its registry row.
    -- Used by the twin purge below.
    -- ----------------------------------------------------------------
    PROCEDURE drop_one(p_model IN VARCHAR2) IS
    BEGIN
        drop_quiet(p_model);
        drop_quiet(p_model || c_tmp_sfx);
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
    -- Core: register + (re)build one ESM model. Never raises (see spec).
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
        l_tmp   VARCHAR2(130) := p_model || c_tmp_sfx;
        l_err   VARCHAR2(4000);
        l_rows  PLS_INTEGER;
        l_step  PLS_INTEGER;
    BEGIN
        IF p_purpose = 'FORECAST' THEN
            g_fc_built := g_fc_built + 1;
        END IF;

        -- A new series is registered up front so a failure has a row to land
        -- on (trained_through stays NULL until a model exists). An existing
        -- row is left alone until the new model is in place: until then it
        -- describes the model that is still serving.
        INSERT INTO cap_ml_model
            (model_name, series_kind, dbid, con_dbid, series_key, exsm_model,
             seasonality, status, purpose, model_type)
        SELECT p_model, p_series_kind, p_dbid, p_con_dbid, p_series_key, p_exsm_model,
               p_seasonality, 'TRAINING', p_purpose, p_exsm_model
        FROM   dual
        WHERE  NOT EXISTS (SELECT 1 FROM cap_ml_model WHERE model_name = p_model);
        COMMIT;

        -- Oracle 19c EXSM caps the horizon at a HARD 30 steps (ORA-40206 above
        -- that at any series length). Also keep it <= FLOOR(rows/4) as a
        -- conservative floor for short series. Never exceeds g_step_max, so ESM
        -- forecasts only ever reach +30 days; +90/180/365 stay REGR-only.
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (' || p_data_query || ')' INTO l_rows;
        -- CREATE_MODEL2 accepts an empty query and yields a model with no
        -- forecast (verified 19c), which would pass as OK.
        IF l_rows = 0 THEN
            RAISE_APPLICATION_ERROR(-20062, 'no training rows for ' || p_series_key);
        END IF;
        l_step := GREATEST(1, LEAST(cfg_num('esm_prediction_step', g_pred_step),
                                    g_step_max, FLOOR(l_rows / 4)));

        l_set('ALGO_NAME')             := 'ALGO_EXPONENTIAL_SMOOTHING';
        l_set('EXSM_MODEL')            := p_exsm_model;
        l_set('EXSM_INTERVAL')         := 'EXSM_INTERVAL_DAY';
        l_set('EXSM_PREDICTION_STEP')  := TO_CHAR(l_step);
        l_set('EXSM_SETMISSING')       := 'EXSM_MISS_AUTO';
        l_set('EXSM_CONFIDENCE_LEVEL') := g_conf;
        IF p_seasonality IS NOT NULL THEN
            l_set('EXSM_SEASONALITY')  := TO_CHAR(p_seasonality);
        END IF;

        -- Leftover of an interrupted build. DROP_MODEL with force is silent
        -- when the model does not exist (verified 19c).
        DBMS_DATA_MINING.DROP_MODEL(l_tmp, force => TRUE);

        DBMS_DATA_MINING.CREATE_MODEL2(
            model_name          => l_tmp,
            mining_function     => 'TIME_SERIES',
            data_query          => p_data_query,
            set_list            => l_set,
            case_id_column_name => 'DAY_DT',
            target_column_name  => p_target_col);

        -- Swap. RENAME_MODEL refuses an existing target (ORA-40204), so the
        -- old model goes first; RENAME_MODEL also renames the DM$VP view.
        DBMS_DATA_MINING.DROP_MODEL(p_model, force => TRUE);
        DBMS_DATA_MINING.RENAME_MODEL(l_tmp, p_model);

        -- model_type mirrors exsm_model: it is the M10.4 "which candidate is
        -- this" label the registry, CAPF_* views and the report all key off.
        -- chosen_by / mape_* are cleared here and (re)stamped by the caller, so
        -- a rationale can never survive a train that did not produce it.
        UPDATE cap_ml_model
           SET series_kind = p_series_kind, dbid = p_dbid, con_dbid = p_con_dbid,
               series_key = p_series_key, exsm_model = p_exsm_model,
               seasonality = p_seasonality, trained_through = p_trained_thru,
               trained_at = SYSDATE, status = 'OK', purpose = p_purpose,
               model_type = p_exsm_model, chosen_by = NULL,
               mape_holt = NULL, mape_addw = NULL,
               last_error = NULL, failed_at = NULL
         WHERE model_name = p_model;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            l_err := SUBSTR(SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            IF p_purpose = 'FORECAST' THEN
                g_fc_failed := g_fc_failed + 1;
            END IF;
            drop_quiet(l_tmp);
            UPDATE cap_ml_model
               SET status = 'FAILED', last_error = l_err, failed_at = SYSDATE
             WHERE model_name = p_model;
            l_rows := SQL%ROWCOUNT;
            COMMIT;
            -- No row to record on (the registration itself failed): raise
            -- rather than lose the error.
            IF l_rows = 0 THEN
                RAISE_APPLICATION_ERROR(-20063,
                    'build_model ' || p_model || ': ' || SUBSTR(l_err, 1, 1800));
            END IF;
    END build_model;

    -- ----------------------------------------------------------------
    -- M9.4 / M10.4: BACKTEST twins for ONE tablespace series, one per
    -- candidate model type, each data_query truncated at
    --   cutoff = series last day - holdout
    -- so the twins' forecast rows land inside the holdout window where real
    -- values exist.
    -- ----------------------------------------------------------------
    PROCEDURE twins_tbspc(p_dbid IN NUMBER, p_con_dbid IN NUMBER,
                          p_key IN VARCHAR2, p_last_day IN DATE,
                          p_holdout_days IN NUMBER) IS
        v_mh   VARCHAR2(30) := model_name_for('CBTT', p_dbid, p_con_dbid, p_key || '|' || c_holt);
        v_mw   VARCHAR2(30) := model_name_for('CBTT', p_dbid, p_con_dbid, p_key || '|' || c_addw);
        v_cut  DATE := p_last_day - p_holdout_days;
        v_q    CLOB;
    BEGIN
        purge_twins(p_dbid, p_con_dbid, p_key, v_mh, v_mw);

        v_q := 'SELECT day_dt, used_bytes FROM capd_tbspc_daily'
            || ' WHERE dbid=' || p_dbid
            || ' AND con_dbid=' || p_con_dbid
            || ' AND tablespace_name=''' || REPLACE(p_key, '''', '''''') || ''''
            || ' AND day_dt <= DATE ''' || TO_CHAR(v_cut, 'YYYY-MM-DD') || '''';

        build_model(v_mh, 'TBSPC', p_dbid, p_con_dbid, p_key,
                    c_holt, NULL, v_q, 'USED_BYTES', v_cut, 'BACKTEST');
        build_model(v_mw, 'TBSPC', p_dbid, p_con_dbid, p_key,
                    c_addw, c_addw_seas, v_q, 'USED_BYTES', v_cut, 'BACKTEST');
    END twins_tbspc;

    -- Twins for the top-N tablespaces (same selection as train_tablespaces).
    PROCEDURE backtest_tbspc(p_top_n IN NUMBER, p_holdout_days IN NUMBER) IS
        v_hold NUMBER := NVL(p_holdout_days, cfg_num('backtest_holdout_days', 28));
        v_min  NUMBER := cfg_num('min_train_days', 14);
    BEGIN
        FOR r IN c_tbspc(p_top_n, NULL, NULL, v_min) LOOP
            twins_tbspc(r.dbid, r.con_dbid, r.tablespace_name, r.last_day, v_hold);
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
                || ' AND busy_pct IS NOT NULL AND is_complete = ''Y'''
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
                || ' AND db_cpu_sec IS NOT NULL AND is_complete = ''Y'''
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
    -- Production model for ONE tablespace: pick the model type, build, and
    -- record why.
    -- ----------------------------------------------------------------
    PROCEDURE prod_tbspc(p_dbid IN NUMBER, p_con_dbid IN NUMBER,
                         p_key IN VARCHAR2, p_last_day IN DATE) IS
        -- M10.4 knobs: 0 = always EXSM_HOLT, 1 = always EXSM_ADDWINTERS(7),
        -- 2 = AUTO (pick by backtest). esm_select_by_backtest = 0 turns the
        -- (expensive: 2 extra models per series) selection off, leaving AUTO to
        -- fall back to the historical default, EXSM_HOLT.
        v_mode   NUMBER := cfg_num('esm_tbspc_model', 2);
        v_tie    NUMBER := cfg_num('esm_auto_tie_pct', 0.25);
        v_model  VARCHAR2(30) := model_name_for('CAPT', p_dbid, p_con_dbid, p_key);
        v_type   VARCHAR2(20);
        v_seas   NUMBER;
        v_chosen VARCHAR2(20);
        v_mh     NUMBER;
        v_mw     NUMBER;
        v_q      CLOB;
    BEGIN
        IF auto_select THEN
            v_mh := candidate_mape(p_dbid, p_con_dbid, p_key, c_holt);
            v_mw := candidate_mape(p_dbid, p_con_dbid, p_key, c_addw);
            -- Inside the tie margin the winner is noise and can flip between
            -- runs, so HOLT (the historical default, and cheaper) stays.
            IF v_mh IS NOT NULL AND v_mw IS NOT NULL AND ABS(v_mw - v_mh) < v_tie THEN
                v_type := c_holt; v_seas := NULL; v_chosen := 'AUTO_TIE';
            ELSIF v_mw IS NOT NULL AND (v_mh IS NULL OR v_mw < v_mh) THEN
                v_type := c_addw; v_seas := c_addw_seas; v_chosen := 'AUTO_BACKTEST';
            ELSE
                -- HOLT scored lower, or no candidate has evidence.
                v_type := c_holt; v_seas := NULL; v_chosen := 'AUTO_BACKTEST';
            END IF;
        ELSIF v_mode = 1 THEN
            v_type := c_addw; v_seas := c_addw_seas; v_chosen := 'CONFIG';
        ELSE
            v_type := c_holt; v_seas := NULL;
            v_chosen := CASE WHEN v_mode = 2 THEN 'DEFAULT' ELSE 'CONFIG' END;
        END IF;

        v_q := 'SELECT day_dt, used_bytes FROM capd_tbspc_daily'
            || ' WHERE dbid=' || p_dbid
            || ' AND con_dbid=' || p_con_dbid
            || ' AND tablespace_name=''' || REPLACE(p_key, '''', '''''') || '''';
        build_model(v_model, 'TBSPC', p_dbid, p_con_dbid, p_key,
                    v_type, v_seas, v_q, 'USED_BYTES', p_last_day);

        -- Record the decision + its evidence (CAPR_BACKTEST.esm_pick, report
        -- section 6c). Only after a successful build: after a failure the row
        -- still describes the older model that survived, with its own reasons.
        UPDATE cap_ml_model
           SET chosen_by = v_chosen, mape_holt = v_mh, mape_addw = v_mw
         WHERE model_name = v_model AND status = 'OK';
        COMMIT;
    END prod_tbspc;

    -- ----------------------------------------------------------------
    -- Tablespace training without the counters/raise of the public wrappers.
    -- ----------------------------------------------------------------
    PROCEDURE do_tablespaces(p_top_n IN NUMBER, p_name IN VARCHAR2, p_con_dbid IN NUMBER) IS
        v_min  NUMBER := cfg_num('min_train_days', 14);   -- packaged fn can't be called inside SQL
        v_hold NUMBER := cfg_num('backtest_holdout_days', 28);
        v_n    PLS_INTEGER := 0;
    BEGIN
        -- AUTO: build both candidates' holdout twins first, so CAPF_ESM_CANDIDATE
        -- has a MAPE per candidate by the time prod_tbspc chooses.
        IF auto_select THEN
            FOR r IN c_tbspc(p_top_n, p_name, p_con_dbid, v_min) LOOP
                twins_tbspc(r.dbid, r.con_dbid, r.tablespace_name, r.last_day, v_hold);
            END LOOP;
        END IF;

        FOR r IN c_tbspc(p_top_n, p_name, p_con_dbid, v_min) LOOP
            prod_tbspc(r.dbid, r.con_dbid, r.tablespace_name, r.last_day);
            v_n := v_n + 1;
        END LOOP;

        IF p_name IS NOT NULL AND v_n = 0 THEN
            RAISE_APPLICATION_ERROR(-20061,
                'train_tablespace: no eligible tablespace ' || p_name
                || ' (needs Tier 1 quality OK or LOW_CONFIDENCE and min_train_days)');
        END IF;
    END do_tablespaces;

    -- ----------------------------------------------------------------
    PROCEDURE do_cpu IS
        v_model VARCHAR2(30);
        v_q     CLOB;
    BEGIN
        -- host busy% : Holt-Winters additive, weekly season. M10.4: only where
        -- the Tier 1 CPU fit is OK / LOW_CONFIDENCE. Complete days only, as the
        -- Tier 1 fit: a partial first, restart or current day reads low.
        FOR r IN (SELECT dbid, con_dbid, last_day FROM capf_cpu_trend
                  WHERE  metric = 'BUSY_PCT' AND quality IN ('OK', 'LOW_CONFIDENCE')) LOOP
            v_model := model_name_for('CAPC', r.dbid, r.con_dbid, 'BUSY_PCT');
            v_q := 'SELECT day_dt, busy_pct FROM capd_cpu_daily'
                || ' WHERE dbid=' || r.dbid || ' AND con_dbid=' || r.con_dbid
                || ' AND busy_pct IS NOT NULL AND is_complete = ''Y''';
            build_model(v_model, 'CPU', r.dbid, r.con_dbid, 'BUSY_PCT',
                        c_addw, c_addw_seas, v_q, 'BUSY_PCT', r.last_day);
        END LOOP;

        -- DB CPU seconds/day : Holt-Winters additive, weekly season.
        FOR r IN (SELECT dbid, con_dbid, last_day FROM capf_cpu_trend
                  WHERE  metric = 'DB_CPU_SEC' AND quality IN ('OK', 'LOW_CONFIDENCE')) LOOP
            v_model := model_name_for('CAPD', r.dbid, r.con_dbid, 'DB_CPU_SEC');
            v_q := 'SELECT day_dt, db_cpu_sec FROM capd_dbtime_daily'
                || ' WHERE dbid=' || r.dbid || ' AND con_dbid=' || r.con_dbid
                || ' AND db_cpu_sec IS NOT NULL AND is_complete = ''Y''';
            build_model(v_model, 'DBCPU', r.dbid, r.con_dbid, 'DB_CPU_SEC',
                        c_addw, c_addw_seas, v_q, 'DB_CPU_SEC', r.last_day);
        END LOOP;
    END do_cpu;

    -- ----------------------------------------------------------------
    PROCEDURE train_tablespaces(p_top_n IN NUMBER DEFAULT 20) IS
    BEGIN
        reset_counts;
        do_tablespaces(p_top_n, NULL, NULL);
        raise_if_failed;
    END train_tablespaces;

    -- ----------------------------------------------------------------
    PROCEDURE train_tablespace(p_tablespace_name IN VARCHAR2,
                               p_con_dbid        IN NUMBER DEFAULT NULL) IS
    BEGIN
        reset_counts;
        -- top-N does not apply to a named series; any cap above the number of
        -- containers will do.
        do_tablespaces(1000000, p_tablespace_name, p_con_dbid);
        raise_if_failed;
    END train_tablespace;

    -- ----------------------------------------------------------------
    PROCEDURE train_cpu IS
    BEGIN
        reset_counts;
        do_cpu;
        raise_if_failed;
    END train_cpu;

    -- ----------------------------------------------------------------
    PROCEDURE train_all(p_top_n    IN NUMBER  DEFAULT 20,
                        p_backtest IN BOOLEAN DEFAULT TRUE) IS
    BEGIN
        reset_counts;
        do_tablespaces(p_top_n, NULL, NULL);   -- trains the candidate twins too when AUTO
        IF p_backtest AND NOT auto_select THEN
            backtest_tbspc(p_top_n, NULL);
        END IF;
        do_cpu;
        -- Without this the CPU twins only move on an explicit train_backtest,
        -- and CAPF_BACKTEST compares a current REGR holdout with an old ESM one.
        IF p_backtest THEN
            backtest_cpu(NULL);
        END IF;
        raise_if_failed;
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
            drop_quiet(r.model_name);
            drop_quiet(r.model_name || c_tmp_sfx);
        END LOOP;
        DELETE FROM cap_ml_model;
        COMMIT;

        -- Orphan sweep: an OML model whose registry row was lost (a manual
        -- DELETE, a pre-M10.4 twin whose name changed, or a <name>_N left by an
        -- interrupted build) would otherwise linger forever. Only this suite's
        -- own name shapes are touched -- <prefix>_<16 hex>[_N] for the six
        -- prefixes the package ever mints.
        BEGIN
            FOR m IN (SELECT model_name FROM user_mining_models
                      WHERE  REGEXP_LIKE(model_name,
                             '^(CAPT|CAPC|CAPD|CBTT|CBTC|CBTD)_[0-9A-F]{16}(_N)?$')) LOOP
                drop_quiet(m.model_name);
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
