--
-- test/run_test.sql -- deterministic assertions over the fixture install.
-- =====================================================================
-- Runs the CAPD_/CAPF_/CAPA_ analytics against the CAP_FIXTURE_* data and
-- checks every result against the closed forms recorded in CAP_FIXTURE_META.
-- Prints PASS/FAIL per check; exits NON-ZERO if any check fails (CI-able via
-- WHENEVER SQLERROR EXIT FAILURE + a final RAISE).
--
-- Prereqs (same schema): test/fixture_install.sql, then @install.sql with
-- seam_mode=fixture. The Tier 2 ESM assertion lives in run_test_ml.sql
-- (separate, because it needs CREATE MINING MODEL).
--
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF VERIFY OFF LINES 200 PAGES 0
WHENEVER SQLERROR EXIT FAILURE

DECLARE
    g_pass  PLS_INTEGER := 0;
    g_fail  PLS_INTEGER := 0;

    v_dbid  NUMBER;
    d_spike DATE; d_restart DATE; d_inj DATE; d_probe DATE;
    d_purge DATE; d_reset DATE; d_tstart DATE;
    n_slope NUMBER; n_dtf NUMBER;

    v_n     PLS_INTEGER;
    v_num   NUMBER;
    v_num2  NUMBER;
    v_num3  NUMBER;
    v_str   VARCHAR2(40);
    v_r2    NUMBER;

    FUNCTION meta_n(p VARCHAR2) RETURN NUMBER IS x NUMBER;
    BEGIN SELECT nval INTO x FROM cap_fixture_meta WHERE mkey = p; RETURN x; END;
    FUNCTION meta_d(p VARCHAR2) RETURN DATE IS x DATE;
    BEGIN SELECT dval INTO x FROM cap_fixture_meta WHERE mkey = p; RETURN x; END;

    PROCEDURE pass(p VARCHAR2) IS
    BEGIN g_pass := g_pass + 1; DBMS_OUTPUT.PUT_LINE('  PASS  ' || p); END;
    PROCEDURE fail(p VARCHAR2) IS
    BEGIN g_fail := g_fail + 1; DBMS_OUTPUT.PUT_LINE('* FAIL  ' || p); END;

    PROCEDURE chk_true(label VARCHAR2, cond BOOLEAN) IS
    BEGIN IF cond THEN pass(label); ELSE fail(label); END IF; END;

    PROCEDURE chk_int(label VARCHAR2, actual NUMBER, expected NUMBER) IS
    BEGIN
        IF actual = expected THEN pass(label || ' = ' || expected);
        ELSE fail(label || ' expected ' || expected || ' got ' || actual); END IF;
    END;

    PROCEDURE chk_close(label VARCHAR2, actual NUMBER, expected NUMBER, tol_frac NUMBER) IS
    BEGIN
        IF expected = 0 THEN
            IF ABS(actual) <= tol_frac THEN pass(label); ELSE fail(label || ' ~0 got ' || actual); END IF;
        ELSIF ABS(actual - expected) <= tol_frac * ABS(expected) THEN
            pass(label || ' ~= ' || expected);
        ELSE
            fail(label || ' expected ~' || expected || ' got ' || actual);
        END IF;
    END;

    PROCEDURE chk_str(label VARCHAR2, actual VARCHAR2, expected VARCHAR2) IS
    BEGIN
        IF actual = expected THEN pass(label || ' = ' || expected);
        ELSE fail(label || ' expected ' || expected || ' got ' || NVL(actual,'<null>')); END IF;
    END;
BEGIN
    v_dbid    := meta_n('DBID');
    d_spike   := meta_d('SPIKE_DAY');
    d_restart := meta_d('RESTART_DAY');
    d_inj     := meta_d('INJECTED_TUE');
    d_probe   := meta_d('PROBE_DAY');
    n_slope   := meta_n('LINEAR_SLOPE');
    n_dtf     := meta_n('LINEAR_DTF');

    DBMS_OUTPUT.PUT_LINE('=== FIX_LINEAR forecast ===');
    SELECT slope_bpd, r2, days_to_full, quality
      INTO v_num, v_r2, v_n, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('LINEAR slope_bpd (bytes/day)', v_num, n_slope, 0.000001);
    chk_true ('LINEAR r2 > 0.999', v_r2 > 0.999);
    chk_int  ('LINEAR days_to_full',  v_n, n_dtf);
    chk_str  ('LINEAR quality', v_str, 'OK');
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_LINEAR' AND anomaly_flag IS NOT NULL;
    chk_int('LINEAR anomaly count', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_SPIKE anomaly ===');
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_SPIKE' AND anomaly_flag = 'HIGH';
    chk_int('SPIKE HIGH count (total)', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_SPIKE' AND anomaly_flag = 'HIGH' AND day_dt = d_spike;
    chk_int('SPIKE HIGH on spike day', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_SPIKE' AND anomaly_flag = 'LOW';
    chk_int('SPIKE LOW count', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_FLAT ===');
    SELECT quality INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FLAT';
    chk_str('FLAT quality', v_str, 'FLAT');
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_FLAT' AND anomaly_flag IS NOT NULL;
    chk_int('FLAT anomaly count', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_GAP (AWR-gap rate normalization) ===');
    SELECT MAX(day_gap) INTO v_n FROM capd_tbspc_delta WHERE tablespace_name = 'FIX_GAP';
    chk_int('GAP recorded (max day_gap)', v_n, 4);
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_GAP' AND anomaly_flag IS NOT NULL;
    chk_int('GAP no false anomaly (rate-normalized)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_NEARFULL (M7.1: near-full now, unreliable fit) ===');
    SELECT pct_used, quality INTO v_num, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_NEARFULL';
    chk_close('NEARFULL pct_used', v_num, meta_n('NEARFULL_PCT'), 0.001);
    chk_str  ('NEARFULL quality', v_str, 'FLAT');
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_NEARFULL' AND severity = 'CRIT';
    chk_int('NEARFULL CRIT alert raised', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_NEARFULL' AND series_key <> 'FIX_NEARFULL';
    chk_int('NEARFULL alerts only for FIX_NEARFULL', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_FILLING (M8.1: TBSPC_FULL alert) ===');
    SELECT days_to_full, pct_used, quality INTO v_n, v_num, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FILLING';
    chk_int  ('FILLING days_to_full', v_n, meta_n('FILLING_DTF'));
    chk_close('FILLING pct_used', v_num, meta_n('FILLING_PCT'), 0.001);
    chk_str  ('FILLING quality', v_str, 'OK');
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_FILLING' AND severity = 'CRIT';
    chk_int('FILLING TBSPC_FULL CRIT alert raised', v_n, 1);
    -- FIX_OVERRIDE also lands inside the dtf_warn window, but only BECAUSE of
    -- its M9.5 override (2 GiB ceiling -> 74 days); on its raw 50 GiB maxsize
    -- it would be 4990 days away. So the "no other series alerts" check names
    -- both rather than counting to 1.
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_FULL' AND series_key NOT IN ('FIX_FILLING','FIX_OVERRIDE');
    chk_int('no TBSPC_FULL alerts beyond FILLING/OVERRIDE', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M9.1 intervals: FIX_LINEAR (zero residuals -> bands collapse) ===');
    SELECT proj_30_bytes, proj_30_lo, proj_30_hi
      INTO v_num, v_num2, v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('LINEAR proj_30_lo = proj_30', v_num2, v_num, 0.000001);
    chk_close('LINEAR proj_30_hi = proj_30', v_num3, v_num, 0.000001);
    SELECT days_to_full_lo, days_to_full_hi INTO v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    -- headroom/slope is EXACTLY 4990.0 here, so a rounding epsilon on the
    -- collapsed slope CI may legitimately FLOOR the worst case to 4989.
    chk_true('LINEAR days_to_full_lo in [4989,4990] (got ' || v_num || ')',
             v_num BETWEEN n_dtf - 1 AND n_dtf);
    chk_true('LINEAR days_to_full_hi in [4990,4991] (got ' || v_num2 || ')',
             v_num2 BETWEEN n_dtf AND n_dtf + 1);

    DBMS_OUTPUT.PUT_LINE('=== M9.1 intervals: FIX_ZIGZAG (closed-form residuals) ===');
    SELECT slope_bpd, proj_30_bytes, quality INTO v_num, v_num2, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_close('ZIGZAG slope_bpd',       v_num,  meta_n('ZZ_SLOPE'),  0.000001);
    chk_close('ZIGZAG proj_30_bytes',   v_num2, meta_n('ZZ_P30'),    0.000001);
    chk_str  ('ZIGZAG quality', v_str, 'OK');
    SELECT proj_30_lo, proj_30_hi INTO v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_close('ZIGZAG proj_30_lo',      v_num,  meta_n('ZZ_P30_LO'), 0.000001);
    chk_close('ZIGZAG proj_30_hi',      v_num2, meta_n('ZZ_P30_HI'), 0.000001);
    SELECT days_to_full, days_to_full_lo, days_to_full_hi INTO v_num, v_num2, v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_int('ZIGZAG days_to_full',    v_num,  meta_n('ZZ_DTF'));
    chk_int('ZIGZAG days_to_full_lo', v_num2, meta_n('ZZ_DTF_LO'));
    chk_int('ZIGZAG days_to_full_hi', v_num3, meta_n('ZZ_DTF_HI'));
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_ZIGZAG' AND anomaly_flag IS NOT NULL;
    chk_int('ZIGZAG anomaly count', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M9.4 backtest (REGR engine, pure SQL) ===');
    SELECT n_train, n_days, mape_pct, bias_pct INTO v_n, v_num, v_num2, v_num3
      FROM capf_backtest
      WHERE series_key = 'FIX_LINEAR' AND engine = 'REGR';
    chk_int ('LINEAR backtest n_train', v_n, 90);
    chk_int ('LINEAR backtest n_days', v_num, 28);
    chk_true('LINEAR backtest MAPE ~ 0 (got ' || v_num2 || ')', ABS(v_num2) < 0.000001);
    chk_true('LINEAR backtest bias ~ 0 (got ' || v_num3 || ')', ABS(v_num3) < 0.000001);
    SELECT n_days, mape_pct, bias_pct INTO v_n, v_num, v_num2
      FROM capf_backtest
      WHERE series_key = 'FIX_ZIGZAG' AND engine = 'REGR';
    chk_int  ('ZIGZAG backtest n_days', v_n, 28);
    chk_close('ZIGZAG backtest MAPE%', v_num,  meta_n('ZZ_BT_MAPE'), 0.0001);
    chk_close('ZIGZAG backtest BIAS%', v_num2, meta_n('ZZ_BT_BIAS'), 0.0001);

    DBMS_OUTPUT.PUT_LINE('=== CAPR_CONTAINER labels (M7.2) ===');
    SELECT db_pdb INTO v_str FROM capr_container
      WHERE dbid = v_dbid AND con_dbid = v_dbid;
    chk_str('root label = db name alone', v_str, 'FIXCDB');
    SELECT db_pdb INTO v_str FROM capr_container
      WHERE dbid = v_dbid AND con_dbid = v_dbid + 1;
    chk_str('PDB label = DB/PDB', v_str, 'FIXCDB/FIXPDB1');
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_NEARFULL' AND db_pdb <> 'FIXCDB';
    chk_int('alerts resolve db_pdb', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== CAPR_ALERTS anomaly kinds (M8.1) ===');
    -- SPIKE_DAY is 10 days before LAST_DAY, INJECTED_TUE at most 6 days
    -- before -- both inside the default 14-day anomaly_report_days window.
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE'
        AND severity = 'WARN' AND day_dt = d_spike;
    chk_int('SPIKE raises TBSPC_ANOM WARN', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'CPU_ANOM' AND severity = 'WARN' AND day_dt = d_inj;
    chk_int('injected Tuesday raises CPU_ANOM WARN', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'CPU_SAT';
    chk_int('no CPU_SAT alert (flat CPU trend)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M8.2 CAPR_* report views ===');
    -- Section 1a: FIX_FILLING fills soonest, so it ranks 1 and carries CRIT.
    SELECT days_to_full, rank_dtf, sev_dtf INTO v_n, v_num, v_str
      FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_FILLING';
    chk_int('CAPR_TBSPC_DAYS_TO_FULL FILLING days_to_full', v_n, meta_n('FILLING_DTF'));
    chk_int('CAPR_TBSPC_DAYS_TO_FULL FILLING rank_dtf', v_num, 1);
    chk_str('CAPR_TBSPC_DAYS_TO_FULL FILLING sev_dtf', v_str, 'CRIT');
    -- Section 1b: FIX_NEARFULL is the fullest RIGHT NOW (97%), any fit quality.
    SELECT rank_nearfull, sev_nearfull INTO v_num, v_str
      FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_NEARFULL';
    chk_int('CAPR_TBSPC_DAYS_TO_FULL NEARFULL rank_nearfull', v_num, 1);
    chk_str('CAPR_TBSPC_DAYS_TO_FULL NEARFULL sev_nearfull', v_str, 'CRIT');
    SELECT COUNT(*) INTO v_n FROM capr_tbspc_days_to_full WHERE db_pdb <> 'FIXCDB';
    chk_int('CAPR section views resolve db_pdb', v_n, 0);

    -- Section 2: one row per tablespace, GiB conversion done in the view.
    SELECT COUNT(*) INTO v_n   FROM capr_tbspc_forecast;
    SELECT COUNT(*) INTO v_num FROM capf_tbspc_forecast;
    chk_int('CAPR_TBSPC_FORECAST row count = CAPF_TBSPC_FORECAST', v_n, v_num);
    SELECT cur_gb INTO v_num FROM capr_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('CAPR_TBSPC_FORECAST LINEAR cur_gb', v_num,
              meta_n('LINEAR_CUR') / 1073741824, 0.000001);

    -- Section 3: flagged rows only; days_ago is measured from the last
    -- collected day, so the report window is a plain WHERE days_ago < N.
    SELECT days_ago INTO v_num FROM capr_tbspc_anomalies
      WHERE tablespace_name = 'FIX_SPIKE' AND day_dt = d_spike;
    chk_int('CAPR_TBSPC_ANOMALIES SPIKE days_ago', v_num, meta_d('LAST_DAY') - d_spike);
    SELECT COUNT(*) INTO v_n FROM capr_tbspc_anomalies WHERE anomaly_flag IS NULL;
    chk_int('CAPR_TBSPC_ANOMALIES holds flagged rows only', v_n, 0);

    -- Section 4: the six CPU metrics (M10.1/M10.2) for the fixture ROOT
    -- container. Scoped by con_dbid because the M10.3 fixture adds a second
    -- container (FIXPDB1) carrying the three time-model metrics of its own.
    SELECT COUNT(*) INTO v_n FROM capr_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = v_dbid;
    chk_int('CAPR_CPU_TREND metric count', v_n, 6);

    -- Section 5: the injected Tuesday, same days_ago contract.
    SELECT days_ago INTO v_num FROM capr_cpu_anomalies WHERE day_dt = d_inj;
    chk_int('CAPR_CPU_ANOMALIES injected day days_ago', v_num, meta_d('LAST_DAY') - d_inj);

    -- Section 6: the Tier 2 report views compile and answer even with no
    -- ESM models trained (REGR backtest is pure SQL, so it always scores).
    SELECT COUNT(*) INTO v_n FROM capr_esm_compare;
    chk_true('CAPR_ESM_COMPARE queryable (' || v_n || ' rows)', v_n >= 0);
    SELECT COUNT(*) INTO v_n FROM capr_backtest WHERE regr_mape IS NOT NULL;
    chk_true('CAPR_BACKTEST scores REGR (' || v_n || ' series)', v_n >= 1);

    DBMS_OUTPUT.PUT_LINE('=== CPU restart guard + busy% ===');
    SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
      WHERE dbid = v_dbid AND day_dt = d_restart;
    chk_int('CPU restart day excluded', v_n, 0);
    SELECT busy_pct INTO v_num FROM capd_cpu_daily
      WHERE dbid = v_dbid AND day_dt = d_probe;
    chk_true('CPU probe weekday busy% in [39,41] (got ' || ROUND(v_num,3) || ')',
             v_num BETWEEN 39 AND 41);

    DBMS_OUTPUT.PUT_LINE('=== M10.1 peak busy% (p95 / max / peak window) ===');
    SELECT busy_pct, busy_p95, busy_max INTO v_num, v_num2, v_num3
      FROM capd_cpu_daily WHERE dbid = v_dbid AND day_dt = d_probe;
    chk_close('CPU probe busy_pct (time-weighted avg)', v_num,  meta_n('CPU_PROBE_AVG'), 0.000001);
    chk_close('CPU probe busy_p95 of 2 intervals',      v_num2, meta_n('CPU_PROBE_P95'), 0.000001);
    chk_close('CPU probe busy_max',                     v_num3, meta_n('CPU_PROBE_MAX'), 0.000001);
    SELECT busy_peak_pct, peak_intervals, n_intervals, host_busy_sec
      INTO v_num, v_n, v_num2, v_num3
      FROM capd_cpu_daily WHERE dbid = v_dbid AND day_dt = d_probe;
    chk_close('CPU probe busy_peak_pct (18:00 interval only)', v_num, meta_n('CPU_PROBE_PEAK'), 0.000001);
    chk_int('CPU probe peak_intervals', v_n, 1);
    chk_int('CPU probe n_intervals', v_num2, 2);
    chk_close('CPU probe host_busy_sec', v_num3, meta_n('CPU_PROBE_HOST_BUSY_SEC'), 0.000001);
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = v_dbid
        AND metric IN ('BUSY_P95','BUSY_PEAK','DB_CPU_PCT','DB_CPU_P95');
    chk_int('CAPF_CPU_TREND carries the four new metrics', v_n, 4);
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE dbid = v_dbid AND metric = 'DB_CPU_SEC' AND days_to_sat IS NOT NULL;
    chk_int('DB_CPU_SEC has no days_to_sat (no ceiling)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M10.2 DB CPU as % of core capacity ===');
    SELECT db_cpu_sec, db_cpu_pct, db_cpu_peak_pct, host_share_pct
      INTO v_num, v_num2, v_num3, v_r2
      FROM capd_dbtime_daily
      WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
    chk_close('DB CPU probe db_cpu_sec',      v_num,  meta_n('DBCPU_PROBE_SEC'),        0.000001);
    chk_close('DB CPU probe db_cpu_pct',      v_num2, meta_n('DBCPU_PROBE_PCT'),        0.000001);
    chk_close('DB CPU probe db_cpu_peak_pct', v_num3, meta_n('DBCPU_PROBE_PEAK_PCT'),   0.000001);
    chk_close('DB CPU probe host_share_pct',  v_r2,   meta_n('DBCPU_PROBE_HOST_SHARE'), 0.000001);
    SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'DBCPU_SAT';
    chk_int('no DBCPU_SAT alert (flat DB CPU)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== CPU same-DOW anomaly ===');
    SELECT anomaly_flag INTO v_str FROM capa_cpu_anom
      WHERE dbid = v_dbid AND day_dt = d_inj;
    chk_str('CPU injected Tuesday flag', v_str, 'HIGH');
    SELECT COUNT(*) INTO v_n FROM capa_cpu_anom
      WHERE dbid = v_dbid AND anomaly_flag = 'HIGH';
    chk_int('CPU HIGH count (only injected)', v_n, 1);

    DBMS_OUTPUT.PUT_LINE('=== M9.5 overrides (CAP_TBSPC_OVERRIDE) ===');
    -- FIX_OVERRIDE is FIX_LINEAR's data with a 2 GiB override instead of the
    -- 50 GiB autoextend maxsize, so every difference between the two below is
    -- attributable to the override alone.
    SELECT limit_bytes, days_to_full, quality INTO v_num, v_n, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_OVERRIDE';
    chk_int('OVERRIDE limit_bytes (2 GiB, exact key beats wildcard decoy)',
            v_num, meta_n('OVERRIDE_LIMIT'));
    chk_int('OVERRIDE days_to_full', v_n, meta_n('OVERRIDE_DTF'));
    chk_str('OVERRIDE quality', v_str, 'OK');
    SELECT limit_source INTO v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_OVERRIDE';
    chk_str('OVERRIDE limit_source', v_str, 'OVERRIDE');
    -- The two un-overridden limit_source branches, for contrast.
    SELECT limit_source INTO v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_str('LINEAR limit_source (autoextend maxsize)', v_str, 'AUTOEXTEND');
    SELECT limit_source INTO v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FLAT';
    chk_str('FLAT limit_source (no autoextend)', v_str, 'ALLOCATED');
    -- FIX_EXCLUDED is 99% full: if the exclusion leaked, it would be loud.
    SELECT COUNT(*) INTO v_n FROM capd_tbspc_daily
      WHERE tablespace_name = 'FIX_EXCLUDED';
    chk_int('EXCLUDED absent from CAPD_TBSPC_DAILY', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_EXCLUDED';
    chk_int('EXCLUDED absent from CAPF_TBSPC_FORECAST', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE series_key = 'FIX_EXCLUDED';
    chk_int('EXCLUDED raises no CAPR_ALERTS', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M7.4 report bound / M7.7 accel floor ===');
    -- M7.7: accel_ratio is meaningless when the baseline slope is ~0, so it is
    -- NULL below accel_slope_floor_bpd (1 MiB/day) instead of an absurd ratio.
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'accel_slope_floor_bpd';
    chk_int('knob accel_slope_floor_bpd (1 MiB/day)', v_num, 1048576);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_FLAT' AND accel_ratio IS NULL;
    chk_int('FIX_FLAT accel_ratio IS NULL (slope 0)', v_n, 1);
    SELECT accel_ratio INTO v_num FROM capf_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_LINEAR';
    chk_close('FIX_LINEAR accel_ratio (10 MiB/day recent = full)', v_num, 1, 0.000001);

    -- M7.4: sections 2 and 6a print only reportable rows -- growing, or
    -- near-full, or >= report_min_gb GiB -- capped at top_n by rank_report.
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'report_min_gb';
    chk_int('knob report_min_gb', v_num, 1);
    SELECT is_reportable INTO v_str FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_FLAT';
    chk_str('FIX_FLAT not reportable (flat, 0.39 GiB, 67% used)', v_str, 'N');
    SELECT is_reportable INTO v_str FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_NEARFULL';
    chk_str('FIX_NEARFULL reportable (flat + under 1 GiB, but 97% full)', v_str, 'Y');
    SELECT is_reportable INTO v_str FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_LINEAR';
    chk_str('FIX_LINEAR reportable (growing)', v_str, 'Y');
    SELECT rank_report INTO v_num  FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_GAP';
    SELECT rank_report INTO v_num2 FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_NEARFULL';
    SELECT rank_report INTO v_num3 FROM capr_tbspc_forecast
      WHERE dbid = v_dbid AND tablespace_name = 'FIX_FLAT';
    chk_true('rank_report: growing FIX_GAP before flat FIX_NEARFULL', v_num < v_num2);
    chk_true('rank_report: reportable FIX_NEARFULL before unreportable FIX_FLAT',
             v_num2 < v_num3);
    SELECT COUNT(*) INTO v_n FROM capr_esm_compare
      WHERE series_kind = 'TBSPC' AND series_key = 'FIX_FLAT' AND is_reportable <> 'N';
    chk_int('CAPR_ESM_COMPARE inherits FIX_FLAT is_reportable=N', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_esm_compare
      WHERE series_kind = 'CPU' AND (is_reportable <> 'Y' OR rank_report <> 0);
    chk_int('CAPR_ESM_COMPARE never bounds CPU rows', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== M9.2 Theil-Sen robust slope (knob slope_method) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'slope_method';
    chk_int('knob slope_method default (0 = OLS, 1 = THEILSEN)', v_num, 0);
    SELECT slope_method, slope_bpd, ols_slope_bpd, ts_slope_bpd
      INTO v_str, v_num, v_num2, v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_str  ('LINEAR slope_method label', v_str, 'OLS');
    chk_close('LINEAR slope_bpd = ols_slope_bpd under the default', v_num, v_num2, 0.000001);
    chk_close('LINEAR ts_slope_bpd (exactly 10 MiB/day)', v_num3, n_slope, 0.000001);
    SELECT ts_slope_bpd INTO v_num
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_close('ZIGZAG ts_slope_bpd = median of the ' || meta_n('ZZ_TS_PAIRS')
              || ' pairwise slopes', v_num, meta_n('ZZ_TS_SLOPE'), 0.000001);
    -- The whole point of M9.2: ONE +2 GiB step drags the OLS slope ~4x off the
    -- true 5 MiB/day rate, while the pairwise median does not move at all.
    SELECT ts_slope_bpd, ols_slope_bpd INTO v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
    chk_close('SPIKE ts_slope_bpd within 1% of the true 5 MiB/day',
              v_num, meta_n('SPIKE_RATE'), 0.01);
    chk_true ('SPIKE ols_slope_bpd > 3x the true rate ('
              || ROUND(v_num2 / meta_n('SPIKE_RATE'), 2) || 'x)',
              v_num2 > 3 * meta_n('SPIKE_RATE'));

    -- Flip the knob for real (uncommitted, this session only) and check the
    -- views switch estimator on the spot -- then put it back and COMMIT.
    SELECT days_to_full INTO v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
    UPDATE cap_config SET cfg_value = 1 WHERE cfg_name = 'slope_method';
    BEGIN
        SELECT slope_method, slope_bpd INTO v_str, v_num
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
        chk_str  ('SPIKE slope_method with knob=1', v_str, 'THEILSEN');
        chk_close('SPIKE slope_bpd with knob=1 (robust 5 MiB/day)',
                  v_num, meta_n('SPIKE_RATE'), 0.01);
        SELECT days_to_full INTO v_num2
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
        chk_true('SPIKE days_to_full with knob=1 > 3x the OLS answer ('
                 || v_num2 || ' vs ' || v_num3 || ')',
                 v_num2 > 3 * v_num3);
        -- M9.2 covers CAPF_CPU_TREND too: every metric row must switch.
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
          WHERE dbid = v_dbid AND slope_method <> 'THEILSEN';
        chk_int('CAPF_CPU_TREND rows all switch to THEILSEN', v_n, 0);
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
            COMMIT;
            RAISE;
    END;
    UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
    COMMIT;
    SELECT slope_method INTO v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
    chk_str('slope_method knob restored to OLS', v_str, 'OLS');

    DBMS_OUTPUT.PUT_LINE('=== M9.3 change-point reset (FIX_PURGE) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'reset_on_shrink';
    chk_int('knob reset_on_shrink default', v_num, 1);
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'shrink_mad_k';
    chk_int('knob shrink_mad_k default', v_num, 6);
    d_purge := meta_d('PURGE_DAY');
    SELECT reset_day, train_start, train_n, slope_bpd, days_to_full, quality
      INTO d_reset, d_tstart, v_n, v_num, v_num2, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE';
    chk_int  ('PURGE reset_day - purge day (0 = the cliff day itself)',
              d_reset - d_purge, 0);
    -- Contract: the reset day IS the first fitted day -- its used_bytes is
    -- already the post-purge level, so including it costs nothing and gives
    -- the new window one extra point.
    chk_int  ('PURGE train_start - reset_day (0 = cliff day is in the window)',
              d_tstart - d_reset, 0);
    chk_int  ('PURGE train_n (post-purge rows)', v_n, meta_n('PURGE_TRAIN_N'));
    chk_close('PURGE slope_bpd = 10 MiB/day (not the across-the-cliff slope)',
              v_num, n_slope, 0.000001);
    chk_int  ('PURGE days_to_full off the post-purge line', v_num2, meta_n('PURGE_DTF'));
    chk_str  ('PURGE quality', v_str, 'OK');
    -- Contrast: a POSITIVE step is not a cliff, a clean line has none, and
    -- FIX_ZIGZAG's -30 MiB dips sit well inside 6*MAD_sigma.
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_SPIKE' AND reset_day IS NULL;
    chk_int('SPIKE reset_day IS NULL (a +2 GiB step is not a shrink)', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_LINEAR' AND reset_day IS NULL;
    chk_int('LINEAR reset_day IS NULL', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_ZIGZAG' AND reset_day IS NULL;
    chk_int('ZIGZAG reset_day IS NULL (dips inside 6*MAD)', v_n, 1);
    SELECT train_n INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_LINEAR';
    chk_int('LINEAR train_n still the full train_days window', v_n, 90);
    -- The purge day is a genuine LOW anomaly, but it sits 30 days back --
    -- outside anomaly_report_days (14) -- so it raises no alert, and it stays
    -- confined to its own tablespace (the FIX_SPIKE LOW check above holds).
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_PURGE' AND anomaly_flag = 'LOW' AND day_dt = d_purge;
    chk_int('PURGE day flags a LOW anomaly', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capa_tbspc_anom
      WHERE tablespace_name = 'FIX_PURGE' AND anomaly_flag IS NOT NULL;
    chk_int('PURGE has exactly one anomaly', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE series_key = 'FIX_PURGE';
    chk_int('PURGE raises no CAPR_ALERTS (cliff predates the alert window)', v_n, 0);

    -- M11 uses a local DATE for the last collected day: meta_d() is a nested
    -- PL/SQL function and cannot be called from inside a SQL statement
    -- (PLS-00231), so the value is resolved once here.
    DECLARE
        d_last DATE := meta_d('LAST_DAY');
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== M11 seam (CAPV_RESOURCE_LIMIT / CAPV_SYSSTAT) ===');
        -- 241 snapshots exist (two a day for 121 days, minus the missing 06:00 of
        -- the restart day) x 2 resource names.
        SELECT COUNT(*) INTO v_n FROM capv_resource_limit;
        chk_int('CAPV_RESOURCE_LIMIT rows (241 snaps x 2 resources)', v_n, 482);
        SELECT COUNT(*) INTO v_n FROM capv_resource_limit
          WHERE resource_name NOT IN ('sessions','processes');
        chk_int('CAPV_RESOURCE_LIMIT carries only sessions/processes', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capv_sysstat WHERE stat_name = 'redo size';
        chk_int('CAPV_SYSSTAT redo-size rows', v_n, 241);

        DBMS_OUTPUT.PUT_LINE('=== M11.1 processes / sessions vs their limits ===');
        SELECT value, limit_value, unit INTO v_num, v_num2, v_str
          FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'SESSIONS' AND day_dt = d_last;
        chk_int('SESSIONS last-day value (max_utilization)', v_num,  meta_n('SESS_CUR'));
        chk_int('SESSIONS last-day limit_value',            v_num2, meta_n('SESS_LIMIT'));
        chk_str('SESSIONS unit', v_str, 'COUNT');
        SELECT slope_per_day, days_to_limit, quality INTO v_num, v_n, v_str
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
        chk_close('SESSIONS slope/day', v_num, 2, 0.000001);
        chk_int  ('SESSIONS days_to_limit (90% of 500)', v_n, meta_n('SESS_DTL'));
        chk_str  ('SESSIONS quality', v_str, 'OK');
        SELECT pct_of_limit, r2 INTO v_num, v_r2
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
        chk_close('SESSIONS pct_of_limit (440/500)', v_num, 88, 0.000001);
        chk_true ('SESSIONS r2 > 0.999', v_r2 > 0.999);
        SELECT cur_val, cur_limit, quality INTO v_num, v_num2, v_str
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'PROCESSES';
        chk_int('PROCESSES cur_val',   v_num,  meta_n('PROC_CUR'));
        chk_int('PROCESSES cur_limit', v_num2, meta_n('PROC_LIMIT'));
        chk_str('PROCESSES quality (constant -> FLAT)', v_str, 'FLAT');
        SELECT COUNT(*) INTO v_n FROM capf_series_forecast
          WHERE dbid = v_dbid AND series = 'PROCESSES' AND days_to_limit IS NULL;
        chk_int('PROCESSES has no days_to_limit (not growing)', v_n, 1);

        DBMS_OUTPUT.PUT_LINE('=== M11.2 redo GiB/day ===');
        SELECT value, unit INTO v_num, v_str FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_probe;
        chk_close('REDO probe-day GiB (2 x 1 GiB intervals)', v_num, meta_n('REDO_PROBE_GB'), 0.000001);
        chk_str  ('REDO unit', v_str, 'GIB_PER_DAY');
        -- Same restart guard as the CPU counters: that day's only interval spans
        -- the restart, so the day drops out entirely rather than reading -240 GiB.
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_restart;
        chk_int('REDO restart day excluded', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND limit_value IS NOT NULL;
        chk_int('REDO has no ceiling', v_n, 0);
        SELECT quality, days_to_limit INTO v_str, v_num
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
        chk_str ('REDO quality (2 GiB/day flat)', v_str, 'FLAT');
        chk_true('REDO days_to_limit IS NULL (no ceiling)', v_num IS NULL);

        DBMS_OUTPUT.PUT_LINE('=== M11.3 total DB size ===');
        -- The identity, re-derived here rather than pre-computed: DB_SIZE_GB is
        -- exactly the sum of what CAPD_TBSPC_DAILY reports that day (so excluded
        -- and UNDO/TEMP tablespaces are out of it by construction).
        SELECT value, limit_value INTO v_num, v_num2 FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'DB_SIZE_GB' AND day_dt = d_last;
        SELECT SUM(used_bytes) / 1073741824, SUM(limit_bytes) / 1073741824
          INTO v_num3, v_r2
          FROM capd_tbspc_daily WHERE dbid = v_dbid AND day_dt = d_last;
        chk_close('DB_SIZE_GB = SUM(used_bytes)/2^30',        v_num,  v_num3, 0.000001);
        chk_close('DB_SIZE_GB limit = SUM(limit_bytes)/2^30', v_num2, v_r2,   0.000001);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'DB_SIZE_GB' AND day_dt = d_last;
        chk_int('DB_SIZE_GB one row per container-day', v_n, 1);
        SELECT slope_per_day, quality INTO v_num, v_str
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'DB_SIZE_GB';
        chk_true('DB_SIZE_GB slope > 0 (got ' || ROUND(v_num, 4) || ' GiB/day)', v_num > 0);
        -- The fixture total is the sum of several linear series plus FIX_SPIKE's
        -- step, FIX_GAP's missing days and FIX_PURGE's cliff, so it is growing but
        -- not perfectly straight: assert the grade is fittable, not that it is OK.
        chk_true('DB_SIZE_GB quality fittable (got ' || v_str || ')',
                 v_str IN ('OK','LOW_CONFIDENCE'));

        DBMS_OUTPUT.PUT_LINE('=== M11 alerts + CAPR_SERIES ===');
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_LIMIT' AND series_key = 'SESSIONS'
            AND severity = 'CRIT' AND db_pdb = 'FIXCDB';
        chk_int('SESSIONS raises SERIES_LIMIT CRIT (db_pdb FIXCDB)', v_n, 1);
        SELECT value INTO v_num FROM capr_alerts
          WHERE kind = 'SERIES_LIMIT' AND series_key = 'SESSIONS';
        chk_int('SERIES_LIMIT value = days_to_limit', v_num, meta_n('SESS_DTL'));
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_LIMIT' AND series_key <> 'SESSIONS';
        chk_int('no SERIES_LIMIT for PROCESSES / REDO_GB_DAY / DB_SIZE_GB', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'SERIES_NEARLIMIT';
        chk_int('no SERIES_NEARLIMIT (sessions at 88%, under 90)', v_n, 0);
        SELECT COUNT(*) INTO v_n   FROM capr_series;
        SELECT COUNT(*) INTO v_num FROM capf_series_forecast;
        chk_int('CAPR_SERIES row count = CAPF_SERIES_FORECAST', v_n, v_num);
        SELECT sev, rank_series INTO v_str, v_num
          FROM capr_series WHERE dbid = v_dbid AND series = 'SESSIONS';
        chk_str('CAPR_SERIES SESSIONS sev', v_str, 'CRIT');
        chk_int('CAPR_SERIES SESSIONS ranks first', v_num, 1);
        SELECT COUNT(*) INTO v_n FROM capr_series WHERE db_pdb <> 'FIXCDB';
        chk_int('CAPR_SERIES resolves db_pdb', v_n, 0);
    END;

    DECLARE
        d_gap   DATE := meta_d('CPUGAP_DAY');
        d_gnext DATE := meta_d('CPUGAP_NEXT');
        n_pdb   NUMBER := meta_n('PDB_CON_DBID');
        v_gflag VARCHAR2(1);
        v_lbl   VARCHAR2(100);
        v_key   VARCHAR2(60);
        v_dev   NUMBER;
        v_thr   NUMBER;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== M10.5 CPU gap handling ===');
        -- The gap day's two snapshots exist but carry no OSSTAT rows, so the
        -- day itself has no CPU row at all -- exactly like a real AWR outage.
        SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gap;
        chk_int('CPU gap day absent from CAPD_CPU_DAILY', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND gap_flag = 'Y';
        chk_int('exactly one gap-flagged CPU day', v_n, 1);

        -- The day AFTER it absorbs the whole outage in ONE 36 h interval.
        SELECT gap_flag, max_interval_hours, day_gap, busy_pct, busy_p95
          INTO v_gflag, v_num, v_num2, v_num3, v_r2
          FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gnext;
        chk_str  ('CPU post-gap day gap_flag', v_gflag, 'Y');
        chk_close('CPU post-gap day max_interval_hours', v_num,  meta_n('CPUGAP_HOURS'),    0.000001);
        chk_int  ('CPU post-gap day day_gap',            v_num2, meta_n('CPUGAP_DAYGAP'));
        chk_close('CPU post-gap day busy_pct',           v_num3, meta_n('CPUGAP_BUSY_PCT'), 0.000001);
        -- busy_p95 = 60 means the 36 h interval (a 20% three-half-day average)
        -- was left out; including it would give PERCENTILE_CONT(.95) = 58.
        chk_close('CPU post-gap day busy_p95 (long interval excluded)',
                  v_r2, meta_n('CPUGAP_P95'), 0.000001);

        -- A normal day is untouched: 12 h intervals, no flag, consecutive.
        SELECT gap_flag, max_interval_hours, day_gap INTO v_gflag, v_num, v_num2
          FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_str  ('CPU probe day gap_flag', v_gflag, 'N');
        chk_close('CPU probe day max_interval_hours', v_num, 12, 0.000001);
        chk_int  ('CPU probe day day_gap', v_num2, 1);

        -- The post-gap day deviates by 10 points against a 9-point threshold,
        -- so ONLY the gap guard keeps it unflagged. Assert both halves.
        SELECT anomaly_flag, gap_flag, ABS(dev_pct), threshold_pct
          INTO v_str, v_gflag, v_dev, v_thr
          FROM capa_cpu_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gnext;
        chk_str ('CPU post-gap day exposes gap_flag', v_gflag, 'Y');
        chk_true('CPU post-gap day WOULD have flagged (|dev| ' || ROUND(v_dev,2)
                 || ' > thr ' || ROUND(v_thr,2) || ')', v_dev > v_thr);
        chk_true('CPU post-gap day anomaly_flag IS NULL (gap guard)', v_str IS NULL);

        -- ...and it is not allowed to poison the next week's baseline either.
        SELECT n_hist INTO v_n FROM capa_cpu_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gnext + 7;
        chk_true('gap day excluded from next-week same-weekday baseline (n_hist '
                 || v_n || ' < 8)', v_n < 8);
        -- ...but the injected Tuesday's own baseline must be untouched. Both
        -- gap days are a different weekday by construction, so neither can be
        -- one of its dow_weeks priors. (n_hist can still be 7 rather than 8
        -- without the gap having anything to do with it: depending on where
        -- SYSDATE falls, the day-60 restart is sometimes a same-weekday prior
        -- of the injected Tuesday, and that day has no CPU row either.)
        chk_true('gap days are not same-weekday priors of the injected Tuesday',
                 MOD(d_inj - d_gap, 7) <> 0 AND MOD(d_inj - d_gnext, 7) <> 0);
        SELECT n_hist INTO v_n FROM capa_cpu_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_inj;
        chk_true('injected Tuesday n_hist unaffected by the gap (got ' || v_n
                 || ', >= 7)', v_n >= 7);

        DBMS_OUTPUT.PUT_LINE('=== M10.3 level-shift detection (CAPA_CPU_SHIFT) ===');
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'shift_days';
        chk_int('knob shift_days', v_num, 7);
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'shift_baseline_days';
        chk_int('knob shift_baseline_days', v_num, 28);
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'shift_min_pct';
        chk_int('knob shift_min_pct', v_num, 15);
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cpu_gap_hours';
        chk_int('knob cpu_gap_hours', v_num, 12);

        -- One row per (container, metric): root has BUSY_PCT / BUSY_P95 /
        -- DB_CPU_PCT, FIXPDB1 (time-model only) has DB_CPU_PCT alone.
        SELECT COUNT(*) INTO v_n FROM capa_cpu_shift WHERE dbid = v_dbid;
        chk_int('CAPA_CPU_SHIFT row count (3 root + 1 PDB)', v_n, 4);

        -- The FIXPDB1 step: +18 points sustained over the last 7 days.
        SELECT shift_flag, shift_pct, recent_med, base_med
          INTO v_str, v_num, v_num2, v_num3
          FROM capa_cpu_shift
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT';
        chk_str  ('PDB DB_CPU_PCT shift_flag', v_str, 'UP');
        chk_close('PDB DB_CPU_PCT shift_pct',  v_num,  meta_n('SHIFT_EXPECTED_PTS'), 0.01);
        chk_close('PDB DB_CPU_PCT recent_med', v_num2, meta_n('SHIFT_RECENT_MED'),   0.01);
        chk_close('PDB DB_CPU_PCT base_med',   v_num3, meta_n('SHIFT_BASE_MED'),     0.01);
        SELECT n_recent, n_base, n_above, base_mad_sigma
          INTO v_n, v_num, v_num2, v_num3
          FROM capa_cpu_shift
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT';
        chk_int  ('PDB shift n_recent (full window)', v_n, 7);
        chk_int  ('PDB shift n_base', v_num, 28);
        chk_int  ('PDB shift n_above (N-of-M: all 7)', v_num2, 7);
        chk_close('PDB shift base_mad_sigma', v_num3, meta_n('SHIFT_BASE_SIGMA'), 0.0001);

        -- ...and the step is invisible to the DAILY layers: the PDB has no
        -- host busy% at all, so no CAPA_CPU_ANOM row, let alone a HIGH.
        SELECT COUNT(*) INTO v_n FROM capa_cpu_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb;
        chk_int('PDB raises no daily CPU anomalies', v_n, 0);
        -- The flat root container must NOT shift (no false positives).
        SELECT COUNT(*) INTO v_n FROM capa_cpu_shift
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND shift_flag IS NOT NULL;
        chk_int('root container raises no level shift', v_n, 0);

        -- Alert + report view.
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'CPU_SHIFT';
        chk_int('exactly one CPU_SHIFT alert', v_n, 1);
        SELECT severity, db_pdb, series_key INTO v_str, v_lbl, v_key
          FROM capr_alerts WHERE kind = 'CPU_SHIFT';
        chk_str('CPU_SHIFT alert severity (UP -> WARN)', v_str, 'WARN');
        chk_str('CPU_SHIFT alert db_pdb', v_lbl, 'FIXCDB/FIXPDB1');
        chk_str('CPU_SHIFT alert series_key', v_key, 'DB_CPU_PCT');
        SELECT COUNT(*) INTO v_n FROM capr_cpu_shifts;
        chk_int('CAPR_CPU_SHIFTS holds the one flagged row', v_n, 1);
        SELECT sev, rank_shift, db_pdb INTO v_str, v_num, v_lbl
          FROM capr_cpu_shifts;
        chk_str('CAPR_CPU_SHIFTS sev', v_str, 'WARN');
        chk_int('CAPR_CPU_SHIFTS rank_shift', v_num, 1);
        chk_str('CAPR_CPU_SHIFTS resolves db_pdb', v_lbl, 'FIXCDB/FIXPDB1');
    EXCEPTION
        WHEN OTHERS THEN
            fail('M10.3/M10.5 block raised ' || SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('----------------------------------------');
    DBMS_OUTPUT.PUT_LINE('RESULT: ' || g_pass || ' passed, ' || g_fail || ' failed');
    IF g_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20050, 'FIXTURE TESTS FAILED: ' || g_fail || ' assertion(s)');
    END IF;
END;
/

PROMPT
PROMPT All fixture assertions passed.
