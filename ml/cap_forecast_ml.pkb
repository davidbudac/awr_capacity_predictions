--
-- ml/cap_forecast_ml.pkb -- Tier 2 OML exponential-smoothing forecaster (body).
-- =====================================================================
-- See the spec for the contract. Design notes:
--   * One OML model per series (19c has no partitioned ESM). Model name is a
--     stable MD5 of (dbid | con_dbid | series_key), prefixed with a letter so
--     it is a legal identifier and re-training rebuilds the same name in place.
--     dbid is in the hash so two databases with a colliding con_dbid + series
--     name (warehouse / migration) get distinct models.
--   * data_query is built as literal-embedded text per series because
--     CREATE_MODEL2's data_query cannot bind. Series keys here are Oracle
--     identifiers (tablespace names / fixed metric strings), so simple
--     quote-doubling is sufficient and injection-safe.
--   * Every train wraps CREATE_MODEL2 so one bad series (e.g. too few points
--     for Holt-Winters) records status='FAILED:...' in CAP_ML_MODEL and the
--     rest still train.
--
CREATE OR REPLACE PACKAGE BODY cap_forecast_ml AS

    g_pred_step  CONSTANT PLS_INTEGER := 30;   -- default; overridden from CAP_CONFIG below
    -- Oracle 19c EXSM caps EXSM_PREDICTION_STEP at a HARD 30 regardless of series
    -- length (verified: 30 ok, 31 fails at 121/300/600 rows). Never request more.
    g_step_max   CONSTANT PLS_INTEGER := 30;
    g_conf       CONSTANT VARCHAR2(8) := '0.95';

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
                          p_trained_thru IN DATE) IS
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
        MERGE INTO cap_ml_model m
        USING (SELECT p_model AS model_name FROM dual) s
        ON (m.model_name = s.model_name)
        WHEN MATCHED THEN UPDATE SET
            series_kind = p_series_kind, dbid = p_dbid, con_dbid = p_con_dbid,
            series_key = p_series_key, exsm_model = p_exsm_model,
            seasonality = p_seasonality, trained_through = p_trained_thru,
            trained_at = SYSDATE, status = 'TRAINING'
        WHEN NOT MATCHED THEN INSERT
            (model_name, series_kind, dbid, con_dbid, series_key, exsm_model,
             seasonality, trained_through, trained_at, status)
            VALUES
            (p_model, p_series_kind, p_dbid, p_con_dbid, p_series_key, p_exsm_model,
             p_seasonality, p_trained_thru, SYSDATE, 'TRAINING');
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
    PROCEDURE train_tablespaces(p_top_n IN NUMBER DEFAULT 20) IS
        v_model  VARCHAR2(30);
        v_q      CLOB;
        v_key    VARCHAR2(4000);
        v_min    NUMBER := cfg_num('min_train_days', 14);   -- packaged fn can't be called inside SQL
    BEGIN
        FOR r IN (
            SELECT dbid, con_dbid, tablespace_name, last_day, train_n
            FROM   capf_tbspc_forecast
            WHERE  train_n >= v_min
            ORDER  BY CASE WHEN days_to_full IS NULL THEN 1 ELSE 0 END,
                      days_to_full ASC,
                      cur_used DESC
            FETCH FIRST p_top_n ROWS ONLY
        ) LOOP
            v_key   := r.tablespace_name;
            v_model := model_name_for('CAPT', r.dbid, r.con_dbid, v_key);
            v_q := 'SELECT day_dt, used_bytes FROM capd_tbspc_daily'
                || ' WHERE dbid=' || r.dbid
                || ' AND con_dbid=' || r.con_dbid
                || ' AND tablespace_name=''' || REPLACE(v_key, '''', '''''') || '''';
            build_model(v_model, 'TBSPC', r.dbid, r.con_dbid, v_key,
                        'EXSM_HOLT', NULL, v_q, 'USED_BYTES', r.last_day);
        END LOOP;
    END train_tablespaces;

    -- ----------------------------------------------------------------
    PROCEDURE train_cpu IS
        v_model VARCHAR2(30);
        v_q     CLOB;
        v_seas  NUMBER := cfg_num('dow_weeks', 8);   -- weekly seasonality period = 7
    BEGIN
        -- host busy% : Holt-Winters additive, weekly season.
        FOR r IN (SELECT dbid, con_dbid, MAX(day_dt) last_day
                  FROM capd_cpu_daily WHERE busy_pct IS NOT NULL
                  GROUP BY dbid, con_dbid) LOOP
            v_model := model_name_for('CAPC', r.dbid, r.con_dbid, 'BUSY_PCT');
            v_q := 'SELECT day_dt, busy_pct FROM capd_cpu_daily'
                || ' WHERE dbid=' || r.dbid || ' AND con_dbid=' || r.con_dbid
                || ' AND busy_pct IS NOT NULL';
            build_model(v_model, 'CPU', r.dbid, r.con_dbid, 'BUSY_PCT',
                        'EXSM_ADDWINTERS', 7, v_q, 'BUSY_PCT', r.last_day);
        END LOOP;

        -- DB CPU seconds/day : Holt-Winters additive, weekly season.
        FOR r IN (SELECT dbid, con_dbid, MAX(day_dt) last_day
                  FROM capd_dbtime_daily WHERE db_cpu_sec IS NOT NULL
                  GROUP BY dbid, con_dbid) LOOP
            v_model := model_name_for('CAPD', r.dbid, r.con_dbid, 'DB_CPU_SEC');
            v_q := 'SELECT day_dt, db_cpu_sec FROM capd_dbtime_daily'
                || ' WHERE dbid=' || r.dbid || ' AND con_dbid=' || r.con_dbid
                || ' AND db_cpu_sec IS NOT NULL';
            build_model(v_model, 'DBCPU', r.dbid, r.con_dbid, 'DB_CPU_SEC',
                        'EXSM_ADDWINTERS', 7, v_q, 'DB_CPU_SEC', r.last_day);
        END LOOP;
    END train_cpu;

    -- ----------------------------------------------------------------
    PROCEDURE train_all(p_top_n IN NUMBER DEFAULT 20) IS
    BEGIN
        train_tablespaces(p_top_n);
        train_cpu;
    END train_all;

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
