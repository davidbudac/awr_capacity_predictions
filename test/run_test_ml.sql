--
-- test/run_test_ml.sql -- Tier 2 (OML ESM) assertion over the fixtures.
-- =====================================================================
-- Separate from run_test.sql because it needs CREATE MINING MODEL. Trains the
-- ESM tablespace models on the fixtures and checks the FIX_LINEAR +30-day
-- forecast lands within 5% of the closed form. M10.4 adds the model-type
-- selection contract: the quality gate, the two candidate twins, the recorded
-- rationale and the single selected ESM row in CAPF_BACKTEST. Tier 2 health
-- adds: the furthest ESM step and model age in CAPF_COMPARE, CAPF_ESM_HEALTH,
-- the CPU twins train_all refreshes, a failed retrain that keeps the last good
-- model, and the AUTO tie margin.
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
    v_txt2  VARCHAR2(200);
    v_base  DATE;          -- fixture day 0
    v_last  DATE;          -- fixture last day (day 120)
    v_nd    PLS_INTEGER;   -- fixture days per full series (121)
    v_hold  NUMBER;
    v_min   NUMBER;
    v_tie   NUMBER;
    v_saved NUMBER;
    v_slope NUMBER;
    v_h     NUMBER;
    v_age   NUMBER;
    v_n2    NUMBER;
    v_model VARCHAR2(30);
    v_dbid  NUMBER;
    v_con   NUMBER;
    v_tt    DATE;
    v_tt2   DATE;
    v_d     DATE;

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

    PROCEDURE set_cfg(p VARCHAR2, v NUMBER) IS
    BEGIN
        UPDATE cap_config SET cfg_value = v WHERE cfg_name = p;
        COMMIT;
    END;

    -- build_model's step rule: LEAST(19c cap 30, esm_prediction_step, FLOOR(rows/4)).
    FUNCTION exp_step(p_rows NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN GREATEST(1, LEAST(30, NVL(cfg('esm_prediction_step'), 30), FLOOR(p_rows / 4)));
    END;

    PROCEDURE chk_num(p VARCHAR2, got NUMBER, exp NUMBER) IS
    BEGIN
        IF got = exp THEN pass(p || ' = ' || got);
        ELSE fail(p || ': got ' || NVL(TO_CHAR(got), 'NULL') || ', expected ' || exp); END IF;
    END;

    PROCEDURE chk_txt(p VARCHAR2, got VARCHAR2, exp VARCHAR2) IS
    BEGIN
        IF got = exp OR (got IS NULL AND exp IS NULL) THEN pass(p || ' = ' || NVL(got, 'NULL'));
        ELSE fail(p || ': got ' || NVL(got, 'NULL') || ', expected ' || NVL(exp, 'NULL')); END IF;
    END;
BEGIN
    v_auto := (NVL(cfg('esm_tbspc_model'), 2) = 2 AND NVL(cfg('esm_select_by_backtest'), 1) = 1);
    v_tie  := cfg('esm_auto_tie_pct');
    v_hold := cfg('backtest_holdout_days');
    v_min  := cfg('min_train_days');
    SELECT dval INTO v_base FROM cap_fixture_meta WHERE mkey = 'BASE_DAY';
    SELECT dval INTO v_last FROM cap_fixture_meta WHERE mkey = 'LAST_DAY';
    SELECT nval INTO v_slope FROM cap_fixture_meta WHERE mkey = 'LINEAR_SLOPE';
    v_nd := v_last - v_base + 1;

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
    -- Furthest ESM step + model age. FIX_LINEAR has one row per fixture day
    -- (v_nd = 121) -> step FLOOR(121/4) = 30. FIX_GAP misses days 100-102 ->
    -- 118 rows -> step 29, which an exact +30 match never showed. Both were
    -- trained through their last day -> age 0.
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('=== Furthest ESM step + model age (CAPF_COMPARE) ===');
    FOR q IN (SELECT 'FIX_LINEAR' AS ts, v_nd AS n FROM dual
              UNION ALL SELECT 'FIX_GAP', v_nd - 3 FROM dual) LOOP
        BEGIN
            SELECT esm_horizon_days, model_age_days INTO v_h, v_age
            FROM   capf_compare
            WHERE  engine = 'ESM' AND series_kind = 'TBSPC' AND series_key = q.ts;
            chk_num(q.ts || ' CAPF_COMPARE esm_horizon_days', v_h, exp_step(q.n));
            chk_num(q.ts || ' CAPF_COMPARE model_age_days', v_age, 0);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN fail(q.ts || ' has no ESM row in CAPF_COMPARE');
        END;

        SELECT MAX(esm_at), MAX(esm_age_days) INTO v_txt, v_age
        FROM   capr_esm_compare
        WHERE  series_kind = 'TBSPC' AND series_key = q.ts AND horizon_days = 30;
        chk_txt(q.ts || ' CAPR_ESM_COMPARE esm_at', v_txt,
                CASE WHEN exp_step(q.n) <> 30 THEN '+' || exp_step(q.n) END);
        chk_num(q.ts || ' CAPR_ESM_COMPARE esm_age_days', v_age, 0);

        SELECT MAX(esm_horizon_days), MAX(esm_age_days), COUNT(esm30) INTO v_h, v_age, v_n
        FROM   capr_tbspc_forecast WHERE tablespace_name = q.ts;
        chk_num(q.ts || ' CAPR_TBSPC_FORECAST esm_horizon_days', v_h, exp_step(q.n));
        chk_num(q.ts || ' CAPR_TBSPC_FORECAST esm_age_days', v_age, 0);
        chk_num(q.ts || ' CAPR_TBSPC_FORECAST esm30 present', v_n, 1);

        SELECT MAX(horizon_days), MAX(ts) INTO v_h, v_d
        FROM   capr_forecast_points
        WHERE  kind = 'TBSPC' AND method = 'ESM' AND series = q.ts;
        chk_num(q.ts || ' CAPR_FORECAST_POINTS ESM horizon_days', v_h, exp_step(q.n));
        chk_txt(q.ts || ' CAPR_FORECAST_POINTS ESM ts', TO_CHAR(v_d, 'YYYY-MM-DD'),
                TO_CHAR(v_last + exp_step(q.n), 'YYYY-MM-DD'));
    END LOOP;

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
        -- AUTO_TIE joins AUTO_BACKTEST as an AUTO outcome (esm_auto_tie_pct).
        SELECT COUNT(*) INTO v_n
        FROM   cap_ml_model
        WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC' AND status = 'OK'
          AND  (chosen_by NOT IN ('AUTO_BACKTEST', 'AUTO_TIE')
                OR mape_holt IS NULL OR mape_addw IS NULL);
        IF v_n = 0 THEN pass('AUTO recorded chosen_by + both candidate MAPEs on every model');
        ELSE fail(v_n || ' AUTO model(s) missing chosen_by / mape_holt / mape_addw'); END IF;

        -- The recorded decision must match the recorded evidence: ADDW only
        -- when it beats HOLT by at least esm_auto_tie_pct points, else HOLT.
        SELECT COUNT(*) INTO v_n
        FROM   cap_ml_model
        WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC' AND status = 'OK'
          AND  model_type <> CASE WHEN mape_addw < mape_holt
                                   AND mape_holt - mape_addw >= v_tie
                                  THEN 'EXSM_ADDWINTERS' ELSE 'EXSM_HOLT' END;
        IF v_n = 0 THEN pass('chosen model_type is the lower-MAPE candidate beyond the tie margin ' || v_tie);
        ELSE fail(v_n || ' model(s) whose model_type is not the lower-MAPE candidate'); END IF;

        SELECT COUNT(*) INTO v_n
        FROM   cap_ml_model
        WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC' AND status = 'OK'
          AND  chosen_by <> CASE WHEN ABS(mape_addw - mape_holt) < v_tie
                                 THEN 'AUTO_TIE' ELSE 'AUTO_BACKTEST' END;
        IF v_n = 0 THEN pass('chosen_by = AUTO_TIE exactly where |MAPE diff| < ' || v_tie);
        ELSE fail(v_n || ' model(s) whose chosen_by disagrees with the tie margin'); END IF;

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

    ------------------------------------------------------------------
    -- CAPF_ESM_HEALTH right after training: every registry row listed, every
    -- eligible tablespace has an OK model, nothing failed, nothing stale.
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('=== CAPF_ESM_HEALTH after train_tablespaces ===');
    SELECT COUNT(*) INTO v_n  FROM capf_esm_health;
    SELECT COUNT(*) INTO v_n2 FROM cap_ml_model;
    chk_num('CAPF_ESM_HEALTH lists every registry model', v_n, v_n2);
    -- eligible = the train_tablespaces gate (8 on the fixture: 11 minus FLAT, NEARFULL, OVERFULL)
    SELECT COUNT(*) INTO v_n2 FROM capf_tbspc_forecast
    WHERE  quality IN ('OK', 'LOW_CONFIDENCE') AND train_n >= v_min;
    SELECT NVL(SUM(n_ok), 0), NVL(SUM(n_failed), 0), NVL(SUM(n_stale), 0)
    INTO   v_n, v_h, v_age FROM capf_esm_health_summary;
    chk_num('CAPF_ESM_HEALTH_SUMMARY n_ok (eligible tablespaces)', v_n, v_n2);
    chk_num('CAPF_ESM_HEALTH_SUMMARY n_failed', v_h, 0);
    chk_num('CAPF_ESM_HEALTH_SUMMARY n_stale', v_age, 0);
    SELECT model_age_days, stale_flag, last_error INTO v_age, v_txt, v_txt2
    FROM   capf_esm_health WHERE series_key = 'FIX_LINEAR' AND purpose = 'FORECAST';
    chk_num('FIX_LINEAR health model_age_days', v_age, 0);
    chk_txt('FIX_LINEAR health stale_flag', v_txt, 'N');
    chk_txt('FIX_LINEAR health last_error', v_txt2, NULL);

    ------------------------------------------------------------------
    -- train_all refreshes the CPU backtest twins of the CPU series it trains,
    -- so CAPF_BACKTEST scores both engines over the same holdout. Eligible CPU
    -- series on the fixture: BUSY_PCT (root) + DB_CPU_SEC (root, FIXPDB1) = 3,
    -- each twin trained through LAST_DAY - backtest_holdout_days.
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('=== train_all: CPU models + CPU backtest twins ===');
    cap_forecast_ml.train_all(20);
    SELECT COUNT(*) INTO v_n2 FROM capf_cpu_trend
    WHERE  metric IN ('BUSY_PCT', 'DB_CPU_SEC') AND quality IN ('OK', 'LOW_CONFIDENCE');
    SELECT COUNT(*), COUNT(CASE WHEN trained_through = v_last - v_hold THEN 1 END)
    INTO   v_n, v_h
    FROM   cap_ml_model
    WHERE  purpose = 'BACKTEST' AND series_kind IN ('CPU', 'DBCPU') AND status = 'OK';
    chk_num('train_all built one OK CPU twin per eligible CPU series', v_n, v_n2);
    chk_num('CPU twins trained through LAST_DAY - holdout', v_h, v_n2);
    SELECT COUNT(*) INTO v_n
    FROM   capf_backtest e JOIN capf_backtest r
      ON   r.dbid = e.dbid AND r.con_dbid = e.con_dbid
     AND   r.series_kind = e.series_kind AND r.series_key = e.series_key
    WHERE  e.series_kind = 'CPU' AND e.engine = 'ESM' AND r.engine = 'REGR'
      AND  e.cutoff_day = r.cutoff_day;
    chk_num('CAPF_BACKTEST CPU ESM rows on the REGR cutoff', v_n, v_n2);
    SELECT COUNT(*) INTO v_n FROM capr_backtest
    WHERE  series_kind = 'CPU'
      AND  esm_cutoff_day = TO_CHAR(v_last - v_hold, 'YYYY-MM-DD')
      AND  cutoff_day = esm_cutoff_day;
    chk_num('CAPR_BACKTEST CPU esm_cutoff_day = cutoff_day = LAST_DAY - holdout', v_n, v_n2);
    SELECT NVL(SUM(n_ok), 0), NVL(SUM(n_failed), 0) INTO v_n, v_h FROM capf_esm_health_summary;
    SELECT v_n2 + COUNT(*) INTO v_n2 FROM capf_tbspc_forecast
    WHERE  quality IN ('OK', 'LOW_CONFIDENCE') AND train_n >= v_min;
    chk_num('CAPF_ESM_HEALTH_SUMMARY n_ok after train_all (tablespaces + CPU)', v_n, v_n2);
    chk_num('CAPF_ESM_HEALTH_SUMMARY n_failed after train_all', v_h, 0);

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

    -- Twin furthest step: FIX_LINEAR's twins train on v_nd - holdout = 93 rows
    -- -> step FLOOR(93/4) = 23, and CAPF_BACKTEST.n_days scores those 23 days.
    SELECT COUNT(DISTINCT model_name), MIN(esm_horizon_days), MAX(esm_horizon_days)
    INTO   v_n, v_h, v_age
    FROM   capf_esm_backtest WHERE series_key = 'FIX_LINEAR';
    chk_num('FIX_LINEAR backtest twins in CAPF_ESM_BACKTEST', v_n, 2);
    chk_num('FIX_LINEAR twin esm_horizon_days (min)', v_h, exp_step(v_nd - v_hold));
    chk_num('FIX_LINEAR twin esm_horizon_days (max)', v_age, exp_step(v_nd - v_hold));
    SELECT MAX(n_days) INTO v_n FROM capf_backtest
    WHERE  series_key = 'FIX_LINEAR' AND engine = 'ESM';
    chk_num('CAPF_BACKTEST FIX_LINEAR ESM n_days agrees with the twin step', v_n, exp_step(v_nd - v_hold));

    -- CAPR_BACKTEST must be able to explain the pick (section 6c's ESM_PICK).
    BEGIN
        SELECT esm_pick INTO v_txt
        FROM   capr_backtest WHERE series_key = 'FIX_LINEAR';
        IF v_txt IS NOT NULL THEN pass('CAPR_BACKTEST.esm_pick = ' || v_txt);
        ELSE fail('CAPR_BACKTEST.esm_pick is NULL for FIX_LINEAR'); END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN fail('CAPR_BACKTEST row missing for FIX_LINEAR');
    END;

    ------------------------------------------------------------------
    -- Model age. Rebuild FIX_LINEAR's forecast model through LAST_DAY - 3
    -- (118 rows -> step 29). It is then 3 days old: CAPF_COMPARE keeps it
    -- (3 <= esm_max_age_days), and its point lands on LAST_DAY - 3 + 29 =
    -- LAST_DAY + 26, so CAPR_FORECAST_POINTS gives horizon 26. FIX_LINEAR is
    -- exactly linear, so that value is the closed form PRED30 - 4 * slope
    -- (within the same 5% as the +30 check).
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('=== Model age + esm_max_age_days gate ===');
    SELECT model_name, dbid, con_dbid INTO v_model, v_dbid, v_con
    FROM   cap_ml_model WHERE series_key = 'FIX_LINEAR' AND purpose = 'FORECAST';
    cap_forecast_ml.build_model(v_model, 'TBSPC', v_dbid, v_con, 'FIX_LINEAR',
        'EXSM_HOLT', NULL,
        'SELECT day_dt, used_bytes FROM capd_tbspc_daily WHERE dbid=' || v_dbid
            || ' AND con_dbid=' || v_con || ' AND tablespace_name=''FIX_LINEAR'''
            || ' AND day_dt <= DATE ''' || TO_CHAR(v_last - 3, 'YYYY-MM-DD') || '''',
        'USED_BYTES', v_last - 3, 'FORECAST');
    SELECT status, model_age_days, stale_flag INTO v_txt, v_age, v_txt2
    FROM   capf_esm_health WHERE model_name = v_model;
    chk_txt('aged FIX_LINEAR status', v_txt, 'OK');
    chk_num('aged FIX_LINEAR model_age_days', v_age, 3);
    chk_txt('aged FIX_LINEAR stale_flag', v_txt2, 'N');
    BEGIN
        SELECT esm_horizon_days, model_age_days, value INTO v_h, v_age, v_pred
        FROM   capf_compare
        WHERE  engine = 'ESM' AND series_kind = 'TBSPC' AND series_key = 'FIX_LINEAR';
        chk_num('aged FIX_LINEAR CAPF_COMPARE esm_horizon_days', v_h, exp_step(v_nd - 3));
        chk_num('aged FIX_LINEAR CAPF_COMPARE model_age_days', v_age, 3);
        -- v_exp still holds LINEAR_PRED30 (the value at LAST_DAY + 30).
        v_exp := v_exp - (30 - (exp_step(v_nd - 3) - 3)) * v_slope;
        IF ABS(v_pred - v_exp) <= 0.05 * v_exp THEN
            pass('aged FIX_LINEAR ESM value within 5% of the closed form (pred=' || ROUND(v_pred)
                 || ' exp=' || v_exp || ')');
        ELSE
            fail('aged FIX_LINEAR ESM value off: pred=' || ROUND(v_pred) || ' exp=' || v_exp);
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN fail('aged FIX_LINEAR has no ESM row in CAPF_COMPARE');
    END;
    SELECT MAX(esm_at), MAX(esm_age_days) INTO v_txt, v_age
    FROM   capr_esm_compare
    WHERE  series_kind = 'TBSPC' AND series_key = 'FIX_LINEAR' AND horizon_days = 30;
    chk_txt('aged FIX_LINEAR CAPR_ESM_COMPARE esm_at', v_txt, '+' || exp_step(v_nd - 3));
    chk_num('aged FIX_LINEAR CAPR_ESM_COMPARE esm_age_days', v_age, 3);
    SELECT MAX(horizon_days), MAX(ts) INTO v_h, v_d
    FROM   capr_forecast_points
    WHERE  kind = 'TBSPC' AND method = 'ESM' AND series = 'FIX_LINEAR';
    chk_num('aged FIX_LINEAR CAPR_FORECAST_POINTS horizon_days', v_h, exp_step(v_nd - 3) - 3);
    chk_txt('aged FIX_LINEAR CAPR_FORECAST_POINTS ts', TO_CHAR(v_d, 'YYYY-MM-DD'),
            TO_CHAR(v_last - 3 + exp_step(v_nd - 3), 'YYYY-MM-DD'));

    -- esm_max_age_days = 2 makes the 3-day-old model stale: flagged, counted,
    -- and gone from CAPF_COMPARE. Restored even if an assertion raises.
    v_saved := cfg('esm_max_age_days');
    BEGIN
        set_cfg('esm_max_age_days', 2);
        SELECT stale_flag INTO v_txt FROM capf_esm_health WHERE model_name = v_model;
        chk_txt('max age 2: FIX_LINEAR stale_flag', v_txt, 'Y');
        SELECT NVL(SUM(n_stale), 0) INTO v_n FROM capf_esm_health_summary;
        chk_num('max age 2: CAPF_ESM_HEALTH_SUMMARY n_stale', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM capf_compare
        WHERE  engine = 'ESM' AND series_key = 'FIX_LINEAR';
        chk_num('max age 2: FIX_LINEAR ESM rows in CAPF_COMPARE', v_n, 0);
        set_cfg('esm_max_age_days', v_saved);
    EXCEPTION
        WHEN OTHERS THEN set_cfg('esm_max_age_days', v_saved); RAISE;
    END;

    ------------------------------------------------------------------
    -- A failed retrain keeps the last good model. Rebuild FIX_LINEAR with an
    -- ESM model type that does not exist: CREATE_MODEL2 fails on the <name>_N
    -- build, the registry row turns FAILED with the error, and the 3-day-old
    -- model above keeps serving (same trained_through, same forecast rows).
    ------------------------------------------------------------------
    DBMS_OUTPUT.PUT_LINE('=== Failed retrain keeps the last good model ===');
    SELECT trained_through, model_type INTO v_tt, v_type
    FROM   cap_ml_model WHERE model_name = v_model;
    SELECT COUNT(*) INTO v_n2 FROM capf_esm_forecast WHERE model_name = v_model;
    cap_forecast_ml.build_model(v_model, 'TBSPC', v_dbid, v_con, 'FIX_LINEAR',
        'EXSM_NO_SUCH_MODEL', NULL,
        'SELECT day_dt, used_bytes FROM capd_tbspc_daily WHERE dbid=' || v_dbid
            || ' AND con_dbid=' || v_con || ' AND tablespace_name=''FIX_LINEAR''',
        'USED_BYTES', v_last, 'FORECAST');
    SELECT status, trained_through, model_type, SUBSTR(last_error, 1, 120),
           CASE WHEN failed_at IS NULL THEN 'N' ELSE 'Y' END
    INTO   v_txt, v_tt2, v_type2, v_txt2, v_status
    FROM   cap_ml_model WHERE model_name = v_model;
    chk_txt('failed retrain: status', v_txt, 'FAILED');
    IF v_txt2 IS NOT NULL THEN pass('failed retrain: last_error = ' || REPLACE(v_txt2, CHR(10), ' '));
    ELSE fail('failed retrain: last_error is NULL'); END IF;
    chk_txt('failed retrain: failed_at set', v_status, 'Y');
    chk_txt('failed retrain: trained_through unchanged', TO_CHAR(v_tt2, 'YYYY-MM-DD'), TO_CHAR(v_tt, 'YYYY-MM-DD'));
    chk_txt('failed retrain: model_type unchanged', v_type2, v_type);
    SELECT COUNT(*) INTO v_n FROM all_mining_models
    WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AND model_name = v_model;
    chk_num('failed retrain: previous OML model still present', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM all_mining_models
    WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AND model_name = v_model || '_N';
    chk_num('failed retrain: no <name>_N left behind', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_esm_forecast WHERE model_name = v_model;
    chk_num('failed retrain: previous model still serves CAPF_ESM_FORECAST rows', v_n, v_n2);
    SELECT COUNT(*) INTO v_n FROM capf_compare
    WHERE  engine = 'ESM' AND series_key = 'FIX_LINEAR' AND model_age_days = 3;
    chk_num('failed retrain: CAPF_COMPARE keeps the 3-day-old ESM row', v_n, 1);
    SELECT NVL(SUM(n_failed), 0) INTO v_n FROM capf_esm_health_summary;
    chk_num('failed retrain: CAPF_ESM_HEALTH_SUMMARY n_failed', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM cap_ml_model
    WHERE  purpose = 'FORECAST' AND model_name <> v_model AND status <> 'OK';
    chk_num('failed retrain: every other forecast model still OK', v_n, 0);

    -- train_tablespace retrains just FIX_LINEAR: OK again, error cleared.
    cap_forecast_ml.train_tablespace('FIX_LINEAR');
    SELECT status, trained_through, last_error, failed_at INTO v_txt, v_tt2, v_txt2, v_d
    FROM   cap_ml_model WHERE model_name = v_model;
    chk_txt('train_tablespace(FIX_LINEAR): status', v_txt, 'OK');
    chk_txt('train_tablespace(FIX_LINEAR): trained_through = LAST_DAY',
            TO_CHAR(v_tt2, 'YYYY-MM-DD'), TO_CHAR(v_last, 'YYYY-MM-DD'));
    chk_txt('train_tablespace(FIX_LINEAR): last_error cleared', v_txt2, NULL);
    chk_txt('train_tablespace(FIX_LINEAR): failed_at cleared', TO_CHAR(v_d, 'YYYY-MM-DD'), NULL);
    SELECT NVL(SUM(n_failed), 0), NVL(SUM(n_stale), 0) INTO v_n, v_h FROM capf_esm_health_summary;
    chk_num('after retrain: CAPF_ESM_HEALTH_SUMMARY n_failed', v_n, 0);
    chk_num('after retrain: CAPF_ESM_HEALTH_SUMMARY n_stale', v_h, 0);

    -- A tablespace outside the quality gate is refused, not silently skipped.
    BEGIN
        cap_forecast_ml.train_tablespace('FIX_FLAT');
        fail('train_tablespace(FIX_FLAT) did not raise');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -20061 THEN pass('train_tablespace(FIX_FLAT) raises ORA-20061');
            ELSE fail('train_tablespace(FIX_FLAT) raised ' || SQLERRM); END IF;
    END;

    ------------------------------------------------------------------
    -- AUTO tie margin. Take the tablespace whose candidate MAPEs differ most
    -- (so it is no tie at the default margin), raise esm_auto_tie_pct above
    -- that gap and retrain it: the candidates now tie, HOLT is kept and
    -- chosen_by says AUTO_TIE. Then restore the knob and retrain once more.
    ------------------------------------------------------------------
    IF v_auto THEN
        DBMS_OUTPUT.PUT_LINE('=== AUTO tie margin (esm_auto_tie_pct) ===');
        SELECT series_key, ABS(mape_addw - mape_holt), chosen_by
        INTO   v_txt, v_h, v_txt2
        FROM   cap_ml_model
        WHERE  purpose = 'FORECAST' AND series_kind = 'TBSPC' AND status = 'OK'
          AND  mape_holt IS NOT NULL AND mape_addw IS NOT NULL
        ORDER  BY ABS(mape_addw - mape_holt) DESC, series_key
        FETCH FIRST 1 ROW ONLY;
        note('widest candidate gap: ' || v_txt || ' |W-H| = ' || ROUND(v_h, 4) || ' points');
        chk_txt(v_txt || ' chosen_by at the default margin ' || v_tie, v_txt2,
                CASE WHEN v_h < v_tie THEN 'AUTO_TIE' ELSE 'AUTO_BACKTEST' END);
        v_saved := cfg('esm_auto_tie_pct');
        BEGIN
            set_cfg('esm_auto_tie_pct', CEIL(v_h) + 1);
            cap_forecast_ml.train_tablespace(v_txt);
            SELECT chosen_by, model_type INTO v_txt2, v_type
            FROM   cap_ml_model WHERE series_key = v_txt AND purpose = 'FORECAST';
            chk_txt(v_txt || ' chosen_by with esm_auto_tie_pct=' || (CEIL(v_h) + 1), v_txt2, 'AUTO_TIE');
            chk_txt(v_txt || ' model_type with esm_auto_tie_pct=' || (CEIL(v_h) + 1), v_type, 'EXSM_HOLT');
            SELECT esm_pick INTO v_txt2 FROM capr_backtest WHERE series_key = v_txt;
            IF v_txt2 LIKE 'HOLT tie H=% W=%' THEN pass('CAPR_BACKTEST.esm_pick = ' || v_txt2);
            ELSE fail('CAPR_BACKTEST.esm_pick for a tie = ' || NVL(v_txt2, 'NULL')); END IF;
            set_cfg('esm_auto_tie_pct', v_saved);
        EXCEPTION
            WHEN OTHERS THEN set_cfg('esm_auto_tie_pct', v_saved); RAISE;
        END;
        cap_forecast_ml.train_tablespace(v_txt);
        SELECT chosen_by INTO v_txt2 FROM cap_ml_model WHERE series_key = v_txt AND purpose = 'FORECAST';
        chk_txt(v_txt || ' chosen_by after restoring the margin', v_txt2,
                CASE WHEN v_h < v_saved THEN 'AUTO_TIE' ELSE 'AUTO_BACKTEST' END);
    END IF;

    DBMS_OUTPUT.PUT_LINE('----------------------------------------');
    IF g_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20051, 'ML TESTS FAILED: ' || g_fail || ' assertion(s)');
    END IF;
    DBMS_OUTPUT.PUT_LINE('ML assertions passed.');
END;
/

PROMPT
PROMPT All ML assertions passed.
