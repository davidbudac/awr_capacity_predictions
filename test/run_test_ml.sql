--
-- test/run_test_ml.sql -- Tier 2 (OML ESM) assertion over the fixtures.
-- =====================================================================
-- Separate from run_test.sql because it needs CREATE MINING MODEL. Trains the
-- ESM tablespace models on the fixtures and checks the FIX_LINEAR +30-day
-- forecast lands within 5% of the closed form. Exits NON-ZERO on failure.
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

    PROCEDURE pass(p VARCHAR2) IS BEGIN DBMS_OUTPUT.PUT_LINE('  PASS  ' || p); END;
    PROCEDURE fail(p VARCHAR2) IS BEGIN g_fail := g_fail + 1; DBMS_OUTPUT.PUT_LINE('* FAIL  ' || p); END;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Tier 2 ESM (train + forecast) ===');
    cap_forecast_ml.drop_all;
    cap_forecast_ml.train_tablespaces(20);

    SELECT status INTO v_status FROM cap_ml_model WHERE series_key = 'FIX_LINEAR';
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

    DBMS_OUTPUT.PUT_LINE('----------------------------------------');
    IF g_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20051, 'ML TESTS FAILED: ' || g_fail || ' assertion(s)');
    END IF;
    DBMS_OUTPUT.PUT_LINE('ML assertions passed.');
END;
/

PROMPT
PROMPT All ML assertions passed.
