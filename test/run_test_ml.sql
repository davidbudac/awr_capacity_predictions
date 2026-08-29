--
-- test/run_test_ml.sql -- Tier 2 (OML ESM) assertion over the fixtures.
-- =====================================================================
-- Separate from run_test.sql because it needs CREATE MINING MODEL. Trains the
-- ESM tablespace models on the fixtures and checks the FIX_LINEAR +30-day
-- forecast lands within 5% of the closed form. M10.4 adds the model-type
-- selection contract: the quality gate, the two candidate twins, the recorded
-- rationale and the single selected ESM row in CAPF_BACKTEST.
-- Exits NON-ZERO on failure.
--
-- Prereqs: fixtures installed, suite installed (seam_mode=fixture), schema has
-- CREATE MINING MODEL.
--
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF VERIFY OFF LINES 200 PAGES 0
WHENEVER SQLERROR EXIT FAILURE

DECLARE
    g_fail  PLS_INTEGER := 0;
    v_status VARCHAR2(200);
    d30     DATE;
    v_exp   NUMBER;
    v_pred  NUMBER;
    v_n     PLS_INTEGER;
    v_auto  BOOLEAN;
    v_type  VARCHAR2(20);
    v_type2 VARCHAR2(20);
    v_txt   VARCHAR2(200);

    PROCEDURE pass(p VARCHAR2) IS BEGIN DBMS_OUTPUT.PUT_LINE('  PASS  ' || p); END;
    PROCEDURE fail(p VARCHAR2) IS BEGIN g_fail := g_fail + 1; DBMS_OUTPUT.PUT_LINE('* FAIL  ' || p); END;
    PROCEDURE note(p VARCHAR2) IS BEGIN DBMS_OUTPUT.PUT_LINE('  ....  ' || p); END;

    FUNCTION cfg(p VARCHAR2) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        SELECT cfg_value INTO v FROM cap_config WHERE cfg_name = p;
        RETURN v;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
    END;
BEGIN
    v_auto := (NVL(cfg('esm_tbspc_model'), 2) = 2 AND NVL(cfg('esm_select_by_backtest'), 1) = 1);

    DBMS_OUTPUT.PUT_LINE('=== Tier 2 ESM (train + forecast) ===');
    DBMS_OUTPUT.PUT_LINE('    esm_tbspc_model=' || cfg('esm_tbspc_model')
                         || ' esm_select_by_backtest=' || cfg('esm_select_by_backtest')
                         || ' -> AUTO=' || CASE WHEN v_auto THEN 'Y' ELSE 'N' END);
    cap_forecast_ml.drop_all;
    cap_forecast_ml.train_tablespaces(20);

    SELECT status INTO v_status
    FROM   cap_ml_model WHERE series_key = 'FIX_LINEAR' AND purpose = 'FORECAST';
    IF v_status = 'OK' THEN pass('FIX_LINEAR model trained OK');
    ELSE fail('FIX_LINEAR model status = ' || v_status); END IF;

    SELECT dval, nval INTO d30, v_exp FROM cap_fixture_meta WHERE mkey = 'LINEAR_PRED30_DAY';

    BEGIN
        SELECT prediction INTO v_pred
        FROM   capf_esm_forecast
        WHERE  series_key = 'FIX_LINEAR' AND actual IS NULL AND TRUNC(day_dt) = d30;

        IF ABS(v_pred - v_exp) <= 0.05 * v_exp THEN
            pass('FIX_LINEAR ESM +30d within 5% (pred=' || ROUND(v_pred)
                 || ' exp=' || v_exp || ')');
        ELSE
            fail('FIX_LINEAR ESM +30d off: pred=' || ROUND(v_pred) || ' exp=' || v_exp);
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail('FIX_LINEAR ESM +30d row missing (day ' || TO_CHAR(d30,'YYYY-MM-DD') || ')');
    END;

    ------------------------------------------------------------------
    -- M10.4a: quality gate -- FLAT / INSUFFICIENT_HISTORY series are never
    -- trained (neither as a production model nor as a backtest twin).
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('=== M10.4 quality gate ===');
    FOR q IN (SELECT 'FIX_FLAT' AS ts FROM dual
              UNION ALL SELECT 'FIX_NEARFULL' FROM dual) LOOP
        SELECT COUNT(*) INTO v_n FROM cap_ml_model WHERE series_key = q.ts;
        SELECT MAX(quality) INTO v_txt FROM capf_tbspc_forecast WHERE tablespace_name = q.ts;
        IF v_n = 0 THEN
            pass(q.ts || ' (quality ' || v_txt || ') not trained');
        ELSE
            fail(q.ts || ' (quality ' || v_txt || ') has ' || v_n || ' model(s) -- gate leaked');
        END IF;
    END LOOP;

    -- Nothing outside the gate may be trained at all.
    SELECT COUNT(*) INTO v_n
    FROM   cap_ml_model m
    WHERE  m.series_kind = 'TBSPC'
      AND  NOT EXISTS (SELECT 1 FROM capf_tbspc_forecast f
                       WHERE f.dbid = m.dbid AND f.con_dbid = m.con_dbid
                         AND f.tablespace_name = m.series_key
                         AND f.quality IN ('OK', 'LOW_CONFIDENCE'));
    IF v_n = 0 THEN pass('every trained tablespace series is OK/LOW_CONFIDENCE');
    ELSE fail(v_n || ' trained tablespace model(s) fail the quality gate'); END IF;

    ------------------------------------------------------------------
    -- M10.4b: model-type selection recorded on every production model.
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('=== M10.4 model-type selection ===');
    SELECT COUNT(*) INTO v_n
    FROM   cap_ml_model
    WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC'
      AND  NVL(model_type, 'x') NOT IN ('EXSM_HOLT', 'EXSM_ADDWINTERS');
    IF v_n = 0 THEN pass('every tablespace model_type in (EXSM_HOLT, EXSM_ADDWINTERS)');
    ELSE fail(v_n || ' tablespace model(s) with an unexpected model_type'); END IF;

    SELECT COUNT(*) INTO v_n
    FROM   cap_ml_model
    WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC' AND status = 'OK'
      AND  model_type <> exsm_model;
    IF v_n = 0 THEN pass('model_type agrees with exsm_model on every model');
    ELSE fail(v_n || ' model(s) where model_type <> exsm_model'); END IF;

    IF v_auto THEN
        SELECT COUNT(*) INTO v_n
        FROM   cap_ml_model
        WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC' AND status = 'OK'
          AND  (chosen_by <> 'AUTO_BACKTEST'
                OR mape_holt IS NULL OR mape_addw IS NULL);
        IF v_n = 0 THEN pass('AUTO recorded chosen_by + both candidate MAPEs on every model');
        ELSE fail(v_n || ' AUTO model(s) missing chosen_by / mape_holt / mape_addw'); END IF;

        -- The recorded decision must match the recorded evidence (ties -> HOLT).
        SELECT COUNT(*) INTO v_n
        FROM   cap_ml_model
        WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC' AND status = 'OK'
          AND  model_type <> CASE WHEN mape_addw < mape_holt
                                  THEN 'EXSM_ADDWINTERS' ELSE 'EXSM_HOLT' END;
        IF v_n = 0 THEN pass('chosen model_type is the lower-MAPE candidate (ties -> HOLT)');
        ELSE fail(v_n || ' model(s) whose model_type is not the lower-MAPE candidate'); END IF;

        -- Both candidate twins must have been built and scored for FIX_LINEAR.
        SELECT COUNT(DISTINCT model_type) INTO v_n
        FROM   capf_esm_candidate
        WHERE  series_kind = 'TBSPC' AND series_key = 'FIX_LINEAR';
        IF v_n = 2 THEN pass('FIX_LINEAR scored both candidate twins in CAPF_ESM_CANDIDATE');
        ELSE fail('FIX_LINEAR has ' || v_n || ' scored candidate(s), expected 2'); END IF;
    END IF;

    -- Show the pick per fixture tablespace (informational, and what M10.4 promises
    -- the report can say).
    FOR m IN (SELECT series_key, model_type, chosen_by, mape_holt, mape_addw
              FROM   cap_ml_model
              WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC'
              ORDER  BY series_key) LOOP
        note(RPAD(m.series_key, 14) || ' -> ' || RPAD(NVL(m.model_type, '?'), 16)
             || ' by ' || RPAD(NVL(m.chosen_by, '?'), 14)
             || ' MAPE holt=' || NVL(TO_CHAR(ROUND(m.mape_holt, 4)), 'n/a')
             || '% addw=' || NVL(TO_CHAR(ROUND(m.mape_addw, 4)), 'n/a') || '%');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('=== M9.4 ESM backtest (train_backtest + CAPF_BACKTEST) ===');
    cap_forecast_ml.train_backtest(20);

    -- Backtest twins must never leak into the forecast surface.
    SELECT COUNT(*) INTO v_n FROM capf_esm_forecast WHERE model_name LIKE 'CBT%';
    IF v_n = 0 THEN pass('no BACKTEST model leaks into CAPF_ESM_FORECAST');
    ELSE fail('BACKTEST models visible in CAPF_ESM_FORECAST: ' || v_n); END IF;

    -- Holt on a perfectly linear series held out 28 days: near-exact forecast.
    -- n_days may be < 28 (19c 30-step cap and the rows/4 conservative floor).
    -- M10.4: CAPF_BACKTEST still yields exactly ONE ESM row per series (the
    -- selected candidate), even though two twins were trained and scored.
    BEGIN
        SELECT n_days, mape_pct, model_type INTO v_n, v_pred, v_type
        FROM   capf_backtest
        WHERE  series_key = 'FIX_LINEAR' AND engine = 'ESM';
        IF v_n >= 1 AND v_pred < 1 THEN
            pass('FIX_LINEAR ESM backtest MAPE < 1% over ' || v_n
                 || ' held-out day(s) (mape=' || ROUND(v_pred, 4) || '%)');
        ELSE
            fail('FIX_LINEAR ESM backtest: n_days=' || v_n || ' mape=' || v_pred);
        END IF;

        SELECT model_type INTO v_type2
        FROM   cap_ml_model WHERE series_key = 'FIX_LINEAR' AND purpose = 'FORECAST';
        IF v_type = v_type2 THEN
            pass('CAPF_BACKTEST ESM row is the selected candidate (' || v_type || ')');
        ELSE
            fail('CAPF_BACKTEST ESM model_type=' || v_type
                 || ' but production model is ' || v_type2);
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail('FIX_LINEAR ESM backtest row missing from CAPF_BACKTEST');
        WHEN TOO_MANY_ROWS THEN
            fail('CAPF_BACKTEST has >1 ESM row for FIX_LINEAR (candidate leak)');
    END;

    -- CAPR_BACKTEST must be able to explain the pick (section 6c's ESM_PICK).
    BEGIN
        SELECT esm_pick INTO v_txt
        FROM   capr_backtest WHERE series_key = 'FIX_LINEAR';
        IF v_txt IS NOT NULL THEN pass('CAPR_BACKTEST.esm_pick = ' || v_txt);
        ELSE fail('CAPR_BACKTEST.esm_pick is NULL for FIX_LINEAR'); END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN fail('CAPR_BACKTEST row missing for FIX_LINEAR');
    END;

    DBMS_OUTPUT.PUT_LINE('----------------------------------------');
    IF g_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20051, 'ML TESTS FAILED: ' || g_fail || ' assertion(s)');
    END IF;
    DBMS_OUTPUT.PUT_LINE('ML assertions passed.');
END;
/

PROMPT
PROMPT All ML assertions passed.
