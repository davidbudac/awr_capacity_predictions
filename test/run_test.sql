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
    v_str2  VARCHAR2(40);
    v_c1    VARCHAR2(1);
    v_msg   VARCHAR2(4000);
    v_r2    NUMBER;
    meta_last_day DATE;
    -- meta_n() cannot be called inside SQL (PLS-00231): these carry the
    -- values the new forecast assertions use in WHERE / SET clauses.
    n_aux   NUMBER;

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

    -- CAPA_ANOM lookups always name the FULL key (kind, series, baseline mode,
    -- ts, container): a bare day lookup matches one row per mode, and d_inj
    -- is also a FIXPDB1 DB_CPU_PCT step day, so it would match several.
    -- 'NOROW' (not NULL) when the key has no row, so a missing row can never
    -- pass as "not flagged".
    FUNCTION anom_flag(p_kind VARCHAR2, p_series VARCHAR2, p_mode VARCHAR2,
                       p_ts DATE, p_con NUMBER) RETURN VARCHAR2 IS
        x VARCHAR2(5);
    BEGIN
        SELECT anomaly_flag INTO x FROM capa_anom
         WHERE dbid = v_dbid AND con_dbid = p_con AND kind = p_kind
           AND series = p_series AND baseline_mode = p_mode AND ts = p_ts;
        RETURN x;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN 'NOROW';
    END;
    -- Flagged rows of one series under one mode; p_flag HIGH / LOW / ANY.
    FUNCTION anom_n(p_kind VARCHAR2, p_series VARCHAR2, p_mode VARCHAR2,
                    p_flag VARCHAR2, p_con NUMBER) RETURN NUMBER IS
        x NUMBER;
    BEGIN
        SELECT COUNT(*) INTO x FROM capa_anom
         WHERE dbid = v_dbid AND con_dbid = p_con AND kind = p_kind
           AND series = p_series AND baseline_mode = p_mode
           AND anomaly_flag = DECODE(p_flag, 'ANY', anomaly_flag, p_flag);
        RETURN x;
    END;
    PROCEDURE knob(p_name VARCHAR2, p_val NUMBER) IS
    BEGIN UPDATE cap_config SET cfg_value = p_val WHERE cfg_name = p_name; END;
BEGIN
    v_dbid    := meta_n('DBID');
    d_spike   := meta_d('SPIKE_DAY');
    d_restart := meta_d('RESTART_DAY');
    d_inj     := meta_d('INJECTED_TUE');
    d_probe   := meta_d('PROBE_DAY');
    n_slope   := meta_n('LINEAR_SLOPE');
    n_dtf     := meta_n('LINEAR_DTF');
    meta_last_day := meta_d('LAST_DAY');

    DBMS_OUTPUT.PUT_LINE('=== FIX_LINEAR forecast ===');
    SELECT slope_bpd, r2, days_to_full, quality
      INTO v_num, v_r2, v_n, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('LINEAR slope_bpd (bytes/day)', v_num, n_slope, 0.000001);
    chk_true ('LINEAR r2 > 0.999', v_r2 > 0.999);
    chk_int  ('LINEAR days_to_full',  v_n, n_dtf);
    chk_str  ('LINEAR quality', v_str, 'OK');
    chk_int('LINEAR anomaly count (TRAILING)', anom_n('TBSPC', 'FIX_LINEAR', 'TRAILING', 'ANY', v_dbid), 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_SPIKE anomaly ===');
    chk_int('SPIKE HIGH count (total, TRAILING)', anom_n('TBSPC', 'FIX_SPIKE', 'TRAILING', 'HIGH', v_dbid), 1);
    chk_str('SPIKE HIGH on spike day (TRAILING)', anom_flag('TBSPC', 'FIX_SPIKE', 'TRAILING', d_spike, v_dbid), 'HIGH');
    chk_int('SPIKE LOW count (TRAILING)', anom_n('TBSPC', 'FIX_SPIKE', 'TRAILING', 'LOW', v_dbid), 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_FLAT ===');
    SELECT quality INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FLAT';
    chk_str('FLAT quality', v_str, 'FLAT');
    chk_int('FLAT anomaly count (TRAILING)', anom_n('TBSPC', 'FIX_FLAT', 'TRAILING', 'ANY', v_dbid), 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_GAP (AWR-gap rate normalization) ===');
    SELECT MAX(day_gap) INTO v_n FROM capd_tbspc_delta WHERE tablespace_name = 'FIX_GAP';
    chk_int('GAP recorded (max day_gap)', v_n, 4);
    chk_int('GAP no false anomaly (rate-normalized, TRAILING)', anom_n('TBSPC', 'FIX_GAP', 'TRAILING', 'ANY', v_dbid), 0);

    DBMS_OUTPUT.PUT_LINE('=== FIX_NEARFULL (M7.1: near-full now, unreliable fit) ===');
    SELECT pct_used, quality INTO v_num, v_str
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_NEARFULL';
    chk_close('NEARFULL pct_used', v_num, meta_n('NEARFULL_PCT'), 0.001);
    chk_str  ('NEARFULL quality', v_str, 'FLAT');
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_NEARFULL' AND severity = 'CRIT';
    chk_int('NEARFULL CRIT alert raised', v_n, 1);
    -- FIX_OVERFULL (limit under its usage, 150%) is the only other series at
    -- or over nearfull_warn_pct, so the "nobody else" check names both.
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_NEARFULL' AND series_key NOT IN ('FIX_NEARFULL', 'FIX_OVERFULL');
    chk_int('NEARFULL alerts only for FIX_NEARFULL / FIX_OVERFULL', v_n, 0);

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
    -- Anchoring leaves FIX_LINEAR unchanged by construction: its fitted line
    -- passes through cur_used, so cur + 30 * slope and the fitted-line value
    -- icept + slope * (last_day_n + 30) are the same closed form.
    chk_close('LINEAR proj_30_bytes = cur + 30 * slope (anchored)',
              v_num, meta_n('LINEAR_PRED30_DAY'), 0.000000001);
    SELECT icept + slope_bpd * (last_day - DATE '2020-01-01' + 30) INTO v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_close('LINEAR fitted-line +30 = anchored +30 (line passes through cur_used)',
              v_num2, meta_n('LINEAR_PRED30_DAY'), 0.000000001);
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
    -- The anchor is the last actual (an even day, +20 MiB off the line); icept
    -- is still the fitted intercept, so the fitted line still reaches the old
    -- +30 value and the gap between the two is the last day's residual.
    SELECT cur_used, icept + slope_bpd * (last_day - DATE '2020-01-01' + 30)
      INTO v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_int  ('ZIGZAG cur_used (anchor)', v_num, meta_n('ZZ_CUR'));
    chk_close('ZIGZAG fitted-line +30 (icept unchanged)', v_num2, meta_n('ZZ_P30_FIT'), 0.000001);
    chk_true ('ZIGZAG anchored +30 differs from the fitted-line +30 ('
              || ROUND((meta_n('ZZ_P30') - meta_n('ZZ_P30_FIT')) / 1048576, 3) || ' MiB)',
              ABS(meta_n('ZZ_P30') - meta_n('ZZ_P30_FIT')) > 1048576);
    -- Every TBSPC row: proj_h = cur_used + slope * h, and the band is
    -- symmetric around it.
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE slope_bpd IS NOT NULL
        AND (ABS(proj_30_bytes  - (cur_used + slope_bpd * 30))  > 1
          OR ABS(proj_90_bytes  - (cur_used + slope_bpd * 90))  > 1
          OR ABS(proj_180_bytes - (cur_used + slope_bpd * 180)) > 1
          OR ABS(proj_365_bytes - (cur_used + slope_bpd * 365)) > 1
          OR ABS((proj_30_hi - proj_30_bytes) - (proj_30_bytes - proj_30_lo)) > 1);
    chk_int('TBSPC rows off the anchored projection', v_n, 0);
    SELECT days_to_full, days_to_full_lo, days_to_full_hi INTO v_num, v_num2, v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
    chk_int('ZIGZAG days_to_full',    v_num,  meta_n('ZZ_DTF'));
    chk_int('ZIGZAG days_to_full_lo', v_num2, meta_n('ZZ_DTF_LO'));
    chk_int('ZIGZAG days_to_full_hi', v_num3, meta_n('ZZ_DTF_HI'));
    chk_int('ZIGZAG anomaly count (TRAILING)', anom_n('TBSPC', 'FIX_ZIGZAG', 'TRAILING', 'ANY', v_dbid), 0);

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
    -- Section 1b: FIX_OVERFULL (150%) is the fullest RIGHT NOW, then
    -- FIX_NEARFULL (97%), any fit quality.
    SELECT rank_nearfull, sev_nearfull INTO v_num, v_str
      FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_OVERFULL';
    chk_int('CAPR_TBSPC_DAYS_TO_FULL OVERFULL rank_nearfull', v_num, 1);
    chk_str('CAPR_TBSPC_DAYS_TO_FULL OVERFULL sev_nearfull', v_str, 'CRIT');
    SELECT rank_nearfull, sev_nearfull INTO v_num, v_str
      FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_NEARFULL';
    chk_int('CAPR_TBSPC_DAYS_TO_FULL NEARFULL rank_nearfull', v_num, 2);
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
      WHERE tablespace_name = 'FIX_SPIKE' AND day_dt = d_spike AND baseline_mode = 'TRAILING';
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
    SELECT days_ago INTO v_num FROM capr_cpu_anomalies
      WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT'
        AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
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

    DBMS_OUTPUT.PUT_LINE('=== M10.2 DB CPU as % of logical-CPU capacity ===');
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
    chk_str('CPU injected Tuesday flag (SAME_DOW)', anom_flag('CPU', 'BUSY_PCT', 'SAME_DOW', d_inj, v_dbid), 'HIGH');
    chk_int('CPU HIGH count (only injected, SAME_DOW)', anom_n('CPU', 'BUSY_PCT', 'SAME_DOW', 'HIGH', v_dbid), 1);

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
    SELECT slope_method, slope_bpd, ols_slope_bpd
      INTO v_str, v_num, v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
    chk_str  ('LINEAR slope_method label', v_str, 'OLS');
    chk_close('LINEAR slope_bpd = ols_slope_bpd under the default', v_num, v_num2, 0.000001);
    -- Theil-Sen is computed only when slope_method = 1: under the default
    -- every ts_* column is NULL.
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE ts_slope_bpd IS NOT NULL OR ts_icept IS NOT NULL;
    chk_int('TBSPC ts_slope_bpd / ts_icept IS NULL under slope_method = 0', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE ts_slope_per_day IS NOT NULL OR ts_icept IS NOT NULL;
    chk_int('CPU ts_slope_per_day / ts_icept IS NULL under slope_method = 0', v_n, 0);
    -- The whole point of M9.2: ONE +2 GiB step drags the OLS slope ~4x off the
    -- true 5 MiB/day rate (the knob flip below shows the median does not move).
    SELECT ols_slope_bpd INTO v_num2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
    chk_true ('SPIKE ols_slope_bpd > 3x the true rate ('
              || ROUND(v_num2 / meta_n('SPIKE_RATE'), 2) || 'x)',
              v_num2 > 3 * meta_n('SPIKE_RATE'));

    -- Flip the knob for real (uncommitted, this session only) and check the
    -- views switch estimator on the spot -- then put it back and COMMIT.
    SELECT days_to_full INTO v_num3
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
    UPDATE cap_config SET cfg_value = 1 WHERE cfg_name = 'slope_method';
    BEGIN
        SELECT ts_slope_bpd INTO v_num
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
        chk_close('LINEAR ts_slope_bpd with knob=1 (exactly 10 MiB/day)', v_num, n_slope, 0.000001);
        SELECT ts_slope_bpd INTO v_num
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
        chk_close('ZIGZAG ts_slope_bpd with knob=1 = median of the ' || meta_n('ZZ_TS_PAIRS')
                  || ' pairwise slopes', v_num, meta_n('ZZ_TS_SLOPE'), 0.000001);
        SELECT ts_slope_bpd INTO v_num
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_SPIKE';
        chk_close('SPIKE ts_slope_bpd with knob=1 within 1% of the true 5 MiB/day',
                  v_num, meta_n('SPIKE_RATE'), 0.01);
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
    chk_str('PURGE day flags a LOW anomaly (TRAILING)', anom_flag('TBSPC', 'FIX_PURGE', 'TRAILING', d_purge, v_dbid), 'LOW');
    chk_int('PURGE has exactly one anomaly (TRAILING)', anom_n('TBSPC', 'FIX_PURGE', 'TRAILING', 'ANY', v_dbid), 1);
    SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE series_key = 'FIX_PURGE';
    chk_int('PURGE raises no CAPR_ALERTS (cliff predates the alert window)', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== clamp + limit_below_used (FIX_OVERFULL) ===');
    -- Flat at 1.5 GiB under a 1 GiB override: FLAT, so days_to_full is NULL
    -- (no growth to count with), not 0. limit_below_used and pct_used say
    -- the tablespace is over its ceiling, and the near-full alert fires.
    SELECT pct_used, quality, limit_below_used, limit_bytes, cur_used, limit_source
      INTO v_num, v_str, v_c1, v_num2, v_num3, v_str2
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_OVERFULL';
    chk_close('OVERFULL pct_used', v_num, meta_n('OVERFULL_PCT'), 0.000001);
    chk_str  ('OVERFULL quality', v_str, 'FLAT');
    chk_str  ('OVERFULL limit_below_used', v_c1, 'Y');
    chk_int  ('OVERFULL limit_bytes (override)', v_num2, meta_n('OVERFULL_LIMIT'));
    chk_int  ('OVERFULL cur_used', v_num3, meta_n('OVERFULL_CUR'));
    chk_str  ('OVERFULL limit_source', v_str2, 'OVERRIDE');
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name = 'FIX_OVERFULL'
        AND days_to_full IS NULL AND days_to_full_lo IS NULL AND days_to_full_hi IS NULL;
    chk_int('OVERFULL days_to_full / _lo / _hi NULL (FLAT)', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_NEARFULL' AND series_key = 'FIX_OVERFULL' AND severity = 'CRIT';
    chk_int('OVERFULL raises TBSPC_NEARFULL CRIT', v_n, 1);
    SELECT COUNT(*) INTO v_n FROM capr_alerts
      WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_OVERFULL';
    chk_int('OVERFULL raises no TBSPC_FULL (flat)', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE limit_below_used = 'Y' AND tablespace_name <> 'FIX_OVERFULL';
    chk_int('no other row has limit_below_used = Y', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast WHERE days_to_full < 0
       OR days_to_full_lo < 0 OR days_to_full_hi < 0;
    chk_int('no negative days_to_full / _lo / _hi', v_n, 0);
    SELECT limit_below_used INTO v_c1 FROM capr_tbspc_days_to_full
      WHERE tablespace_name = 'FIX_OVERFULL';
    chk_str('CAPR_TBSPC_DAYS_TO_FULL passes limit_below_used', v_c1, 'Y');
    SELECT limit_below_used INTO v_num FROM capr_fit
      WHERE kind = 'TBSPC' AND series = 'FIX_OVERFULL';
    chk_int('CAPR_FIT limit_below_used = 1 for OVERFULL', v_num, 1);
    -- The clamp on a GROWING series: an override at 1 GiB under FIX_LINEAR's
    -- 1.27 GiB would give FLOOR(-26.0) = -26 days without it. Rolled back.
    SAVEPOINT u4a_clamp;
    BEGIN
        INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note)
        VALUES (v_dbid, v_dbid, 'FIX_LINEAR', 1073741824, 'N', 'run_test clamp probe');
        SELECT days_to_full, days_to_full_lo, days_to_full_hi, limit_below_used
          INTO v_num, v_num2, v_num3, v_c1
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
        chk_int('clamp probe LINEAR days_to_full (limit < cur)', v_num, 0);
        chk_int('clamp probe LINEAR days_to_full_lo', v_num2, 0);
        chk_int('clamp probe LINEAR days_to_full_hi', v_num3, 0);
        chk_str('clamp probe LINEAR limit_below_used', v_c1, 'Y');
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u4a_clamp; RAISE;
    END;
    ROLLBACK TO SAVEPOINT u4a_clamp;

    DBMS_OUTPUT.PUT_LINE('=== staleness (stale_days / is_current, FIX_DROPPED) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'stale_days';
    chk_int('knob stale_days default', v_num, 3);
    SELECT last_day, newest_day, is_current, quality, train_n, cur_used
      INTO d_tstart, d_reset, v_c1, v_str, v_n, v_num
      FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_DROPPED';
    chk_int  ('DROPPED last_day', d_tstart - meta_d('DROPPED_LAST_DAY'), 0);
    chk_int  ('DROPPED newest_day = LAST_DAY', d_reset - meta_d('LAST_DAY'), 0);
    chk_int  ('DROPPED newest_day - last_day', d_reset - d_tstart, meta_n('DROPPED_STALE_GAP'));
    chk_str  ('DROPPED is_current', v_c1, 'N');
    chk_str  ('DROPPED quality (still fits)', v_str, 'OK');
    chk_int  ('DROPPED train_n', v_n, meta_n('DROPPED_TRAIN_N'));
    chk_int  ('DROPPED cur_used (its last row)', v_num, meta_n('DROPPED_CUR'));
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE tablespace_name <> 'FIX_DROPPED' AND is_current <> 'Y';
    chk_int('every other TBSPC row is_current = Y', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
      WHERE newest_day <> meta_last_day;
    chk_int('TBSPC newest_day = LAST_DAY on every row', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE is_current <> 'Y' OR newest_day <> meta_last_day;
    chk_int('CPU rows is_current = Y, newest_day = LAST_DAY', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capf_series_forecast
      WHERE is_current <> 'Y' OR newest_day <> meta_last_day;
    chk_int('SERIES rows is_current = Y, newest_day = LAST_DAY', v_n, 0);
    SELECT is_current INTO v_c1 FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_DROPPED';
    chk_str('CAPR_TBSPC_DAYS_TO_FULL passes is_current', v_c1, 'N');
    SELECT is_current INTO v_num FROM capr_fit WHERE kind = 'TBSPC' AND series = 'FIX_DROPPED';
    chk_int('CAPR_FIT is_current = 0 for DROPPED', v_num, 0);
    SELECT COUNT(*) INTO v_n FROM capr_fit WHERE is_current IS NULL
       OR (kind = 'TBSPC' AND limit_below_used IS NULL)
       OR (kind <> 'TBSPC' AND limit_below_used IS NOT NULL);
    chk_int('CAPR_FIT flags set per kind', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_cpu_trend WHERE is_current <> 'Y';
    chk_int('CAPR_CPU_TREND passes is_current', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM capr_series WHERE is_current <> 'Y';
    chk_int('CAPR_SERIES passes is_current', v_n, 0);
    -- The boundary is last_day >= newest_day - stale_days: 30 days behind is
    -- stale at stale_days = 29 and current at 30. Uncommitted, then reset.
    BEGIN
        n_aux := meta_n('DROPPED_STALE_GAP');
        UPDATE cap_config SET cfg_value = n_aux - 1 WHERE cfg_name = 'stale_days';
        SELECT is_current INTO v_c1 FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_DROPPED';
        chk_str('DROPPED is_current with stale_days = gap - 1', v_c1, 'N');
        UPDATE cap_config SET cfg_value = n_aux WHERE cfg_name = 'stale_days';
        SELECT is_current INTO v_c1 FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_DROPPED';
        chk_str('DROPPED is_current with stale_days = gap', v_c1, 'Y');
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'stale_days';
            COMMIT;
            RAISE;
    END;
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'stale_days';
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('=== anchoring on CPU and SERIES fits ===');
    -- FIXPDB1 DB_CPU_PCT: the +18 step in the last 7 days leaves the last
    -- point above the fitted line, so anchored and fitted-line +30 differ.
    -- CPU projections start at anchor_value (the median of the last
    -- shift_days complete days, 58 here), and the slope is the deseasoned
    -- one (cpu_deseason = 1 by default): both recomputed by the installer.
    n_aux := meta_n('PDB_CON_DBID');
    SELECT train_n, cur_val, slope_per_day, proj_30,
           icept + slope_per_day * (last_day - DATE '2020-01-01' + 30)
      INTO v_n, v_num, v_num2, v_num3, v_r2
      FROM capf_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = n_aux AND metric = 'DB_CPU_PCT';
    chk_int  ('PDB DB_CPU_PCT train_n (restart day has no row)', v_n, meta_n('PDB_DBCPU_TRAIN_N'));
    chk_close('PDB DB_CPU_PCT cur_val', v_num, meta_n('PDB_DBCPU_CUR'), 0.000001);
    chk_close('PDB DB_CPU_PCT slope (deseasoned)', v_num2, meta_n('PDB_DBCPU_SLOPE'), 0.000001);
    chk_close('PDB DB_CPU_PCT proj_30 = anchor_value + 30 * slope', v_num3, meta_n('PDB_DBCPU_P30'), 0.000001);
    chk_close('PDB DB_CPU_PCT fitted-line +30 (deseasoned icept)', v_r2, meta_n('PDB_DBCPU_P30_FIT'), 0.000001);
    SELECT anchor_value, days_to_sat INTO v_num, v_n
      FROM capf_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = n_aux AND metric = 'DB_CPU_PCT';
    chk_close('PDB DB_CPU_PCT anchor_value (median of the last 7 days)', v_num, meta_n('PDB_DBCPU_ANCHOR'), 0.000001);
    chk_int  ('PDB DB_CPU_PCT days_to_sat from the anchor', v_n, meta_n('PDB_DBCPU_DTS'));
    SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
      WHERE slope_per_day IS NOT NULL
        AND (ABS(proj_30 - (anchor_value + slope_per_day * 30)) > 0.000001
          OR ABS(proj_90 - (anchor_value + slope_per_day * 90)) > 0.000001);
    chk_int('CPU rows off the anchored projection (anchor_value)', v_n, 0);
    -- SESSIONS is exactly linear, so anchoring changes nothing: 440 + 2 * 30.
    SELECT proj_30 INTO v_num FROM capf_series_forecast
      WHERE dbid = v_dbid AND series = 'SESSIONS';
    chk_close('SESSIONS proj_30 = 440 + 2 * 30', v_num, meta_n('SESS_CUR') + 2 * 30, 0.000001);
    SELECT COUNT(*) INTO v_n FROM capf_series_forecast
      WHERE slope_per_day IS NOT NULL
        AND (ABS(proj_30 - (cur_val + slope_per_day * 30)) > 0.000001
          OR ABS(proj_90 - (cur_val + slope_per_day * 90)) > 0.000001);
    chk_int('SERIES rows off the anchored projection', v_n, 0);

    DBMS_OUTPUT.PUT_LINE('=== complete-day fits (is_complete = Y only) ===');
    SELECT train_n, train_start INTO v_n, d_tstart FROM capf_cpu_trend
      WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT';
    chk_int('BUSY_PCT train_n, train_days 90 (no partial day in the window)', v_n, meta_n('CPU_TRAIN_N'));
    SELECT train_n INTO v_n FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
    chk_int('REDO_GB_DAY train_n, train_days 90', v_n, meta_n('REDO_TRAIN_N'));
    SELECT train_n INTO v_n FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
    chk_int('SESSIONS train_n, train_days 90 (level series, every day)', v_n, meta_n('SESS_TRAIN_N'));
    -- Widen the window to 120 days so it holds the partial day (and day 1):
    -- the fits must skip the partial day. Uncommitted, then reset.
    BEGIN
        UPDATE cap_config SET cfg_value = 120 WHERE cfg_name = 'train_days';
        SELECT COUNT(*) INTO v_num FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND busy_pct IS NOT NULL
            AND day_dt > meta_last_day - 120;
        SELECT train_n, train_start INTO v_n, d_tstart FROM capf_cpu_trend
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT';
        chk_int('BUSY_PCT train_n, train_days 120 (partial day skipped; '
                || v_num || ' rows in the window)', v_n, meta_n('CPU_TRAIN_N_120'));
        chk_int('BUSY_PCT rows in the 120-day window = train_n + the partial day',
                v_num, meta_n('CPU_TRAIN_N_120') + 1);
        chk_int('BUSY_PCT train_start = day 1', d_tstart - meta_d('BASE_DAY'), 1);
        n_aux := meta_n('CPU_TRAIN_N_120');
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
          WHERE dbid = v_dbid AND con_dbid = v_dbid
            AND metric IN ('BUSY_P95', 'BUSY_PEAK', 'DB_CPU_SEC', 'DB_CPU_PCT', 'DB_CPU_P95')
            AND train_n <> n_aux;
        chk_int('every root CPU metric skips the partial day', v_n, 0);
        SELECT train_n INTO v_n FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
        chk_int('REDO_GB_DAY train_n, train_days 120 (partial day skipped)', v_n, meta_n('REDO_TRAIN_N_120'));
        SELECT train_n INTO v_n FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
        chk_int('SESSIONS train_n, train_days 120', v_n, meta_n('SESS_TRAIN_N_120'));
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'train_days';
            COMMIT;
            RAISE;
    END;
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'train_days';
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('=== CYCLIC grade (FIX_CYCLIC / FIX_CYCLIC_UP) ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cyclic_min_cliffs';
    chk_int('knob cyclic_min_cliffs default', v_num, 2);
    DECLARE
        v_cn NUMBER; v_cd NUMBER; v_pk NUMBER; v_pp NUMBER; v_ps NUMBER;
        v_rd DATE; v_dtf NUMBER; v_lo NUMBER; v_hi NUMBER; v_acc NUMBER;
    BEGIN
        FOR g IN 0 .. 1 LOOP
            v_str2 := CASE g WHEN 0 THEN 'FIX_CYCLIC' ELSE 'FIX_CYCLIC_UP' END;
            SELECT quality, cycle_n, cycle_days, cycle_peak_bytes, cycle_peak_pct,
                   peak_slope_bpd, reset_day, days_to_full, days_to_full_lo,
                   days_to_full_hi, accel_ratio, train_n, cur_used
              INTO v_str, v_cn, v_cd, v_pk, v_pp, v_ps, v_rd, v_dtf, v_lo, v_hi, v_acc, v_n, v_num
              FROM capf_tbspc_forecast WHERE tablespace_name = v_str2;
            chk_str  (v_str2 || ' quality', v_str, 'CYCLIC');
            chk_int  (v_str2 || ' cycle_n (cliffs in the window)', v_cn, meta_n('CYC' || g || '_N'));
            chk_int  (v_str2 || ' cycle_days', v_cd, meta_n('CYC' || g || '_DAYS'));
            chk_int  (v_str2 || ' cycle_peak_bytes', v_pk, meta_n('CYC' || g || '_PEAK'));
            chk_close(v_str2 || ' cycle_peak_pct', v_pp, meta_n('CYC' || g || '_PCT'), 0.000001);
            chk_int  (v_str2 || ' cur_used', v_num, meta_n('CYC' || g || '_CUR'));
            chk_true (v_str2 || ' reset_day IS NULL (no reset on a cyclic series)', v_rd IS NULL);
            chk_int  (v_str2 || ' train_n = the full window', v_n, 90);
            chk_true (v_str2 || ' days_to_full_lo / _hi / accel_ratio NULL',
                      v_lo IS NULL AND v_hi IS NULL AND v_acc IS NULL);
            IF g = 0 THEN
                chk_close(v_str2 || ' peak_slope_bpd = 0 (peaks do not grow)', v_ps, 0, 0.000001);
                chk_true (v_str2 || ' days_to_full IS NULL', v_dtf IS NULL);
            ELSE
                chk_close(v_str2 || ' peak_slope_bpd = 1 GiB / 30 days', v_ps, meta_n('CYC1_PSLOPE'), 0.000001);
                chk_int  (v_str2 || ' days_to_full off the peak line', v_dtf, meta_n('CYC1_DTF'));
            END IF;
        END LOOP;
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'TBSPC_FULL' AND series_key IN ('FIX_CYCLIC', 'FIX_CYCLIC_UP');
        chk_int('CYCLIC raises no TBSPC_FULL', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
          WHERE quality = 'CYCLIC' AND tablespace_name NOT IN ('FIX_CYCLIC', 'FIX_CYCLIC_UP');
        chk_int('no other row is CYCLIC', v_n, 0);
        SELECT cycle_n INTO v_n FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE';
        chk_int('FIX_PURGE cycle_n = 1 (one purge: M9.3 reset, not CYCLIC)', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
          WHERE quality <> 'CYCLIC'
            AND (cycle_days IS NOT NULL OR cycle_peak_bytes IS NOT NULL
                 OR cycle_peak_pct IS NOT NULL OR peak_slope_bpd IS NOT NULL);
        chk_int('cycle_* columns NULL off CYCLIC rows', v_n, 0);
        SELECT quality, cycle_n, cycle_days, cycle_peak_pct, days_to_full
          INTO v_str, v_cn, v_cd, v_pp, v_dtf
          FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_CYCLIC';
        chk_true('CAPR_TBSPC_DAYS_TO_FULL passes the CYCLIC columns',
                 v_str = 'CYCLIC' AND v_cn = meta_n('CYC0_N') AND v_cd = meta_n('CYC0_DAYS')
                 AND v_pp = meta_n('CYC0_PCT') AND v_dtf IS NULL);
        SELECT cycle_peak_gb, peak_slope_mb INTO v_pk, v_ps
          FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_CYCLIC_UP';
        chk_close('CAPR_TBSPC_DAYS_TO_FULL cycle_peak_gb', v_pk, meta_n('CYC1_PEAK') / 1073741824, 0.000001);
        chk_close('CAPR_TBSPC_DAYS_TO_FULL peak_slope_mb', v_ps, meta_n('CYC1_PSLOPE') / 1048576, 0.000001);
        SELECT quality, cycle_n, cycle_days, cycle_peak_pct, peak_slope_per_day, days_to_full
          INTO v_str, v_cn, v_cd, v_pp, v_ps, v_dtf
          FROM capr_fit WHERE kind = 'TBSPC' AND series = 'FIX_CYCLIC_UP';
        chk_true('CAPR_FIT passes the CYCLIC columns',
                 v_str = 'CYCLIC' AND v_cn = meta_n('CYC1_N') AND v_cd = meta_n('CYC1_DAYS')
                 AND v_pp = meta_n('CYC1_PCT') AND ABS(v_ps - meta_n('CYC1_PSLOPE')) < 0.001
                 AND v_dtf = meta_n('CYC1_DTF'));
        -- The grade off (cyclic_min_cliffs = 0): the M9.3 reset restarts at
        -- the last cliff, the current rise reads 2.5 GiB/day, and FIX_CYCLIC
        -- falls inside dtf_warn: the false page the grade exists to stop.
        BEGIN
            UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'cyclic_min_cliffs';
            SELECT quality, reset_day, train_n, slope_bpd, days_to_full, cycle_n
              INTO v_str, v_rd, v_n, v_ps, v_dtf, v_cn
              FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_CYCLIC';
            chk_str  ('cyclic_min_cliffs = 0: FIX_CYCLIC quality', v_str, 'OK');
            chk_int  ('cyclic_min_cliffs = 0: reset_day = the last cliff', v_rd - meta_d('CYC0_LAST_CLIFF'), 0);
            chk_int  ('cyclic_min_cliffs = 0: train_n (the current rise)', v_n, meta_n('CYC0_LEGACY_N'));
            chk_close('cyclic_min_cliffs = 0: slope_bpd = 2.5 GiB/day', v_ps, meta_n('CYC0_RISE'), 0.000001);
            chk_int  ('cyclic_min_cliffs = 0: days_to_full', v_dtf, meta_n('CYC0_LEGACY_DTF'));
            chk_int  ('cyclic_min_cliffs = 0: cycle_n still counted', v_cn, meta_n('CYC0_N'));
            SELECT COUNT(*) INTO v_n FROM capr_alerts
              WHERE kind = 'TBSPC_FULL' AND series_key = 'FIX_CYCLIC';
            chk_int('cyclic_min_cliffs = 0: FIX_CYCLIC raises the TBSPC_FULL false page', v_n, 1);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'cyclic_min_cliffs';
                COMMIT;
                RAISE;
        END;
        UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'cyclic_min_cliffs';
        COMMIT;
    END;

    DBMS_OUTPUT.PUT_LINE('=== DRIFT estimator (slope_method = 2) ===');
    -- Closed forms from the installer's own rates (DR_*). Flipped for this
    -- block only, then restored and committed.
    DECLARE
        v_sd NUMBER; v_ci NUMBER; v_p NUMBER; v_lo NUMBER; v_hi NUMBER;
        v_d NUMBER; v_dlo NUMBER; v_dhi NUMBER; v_m VARCHAR2(10);
    BEGIN
        -- Under the default the drift columns are there, the estimator is not.
        SELECT drift_slope_bpd, drift_sd_bpd, slope_method INTO v_num, v_sd, v_m
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
        chk_close('LINEAR drift_slope_bpd under slope_method 0', v_num, meta_n('DR_LINEAR_SLOPE'), 0.000001);
        chk_close('LINEAR drift_sd_bpd under slope_method 0 (0)', v_sd, 0, 0.000001);
        chk_str  ('LINEAR slope_method under 0', v_m, 'OLS');
        UPDATE cap_config SET cfg_value = 2 WHERE cfg_name = 'slope_method';
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast WHERE slope_method <> 'DRIFT';
            chk_int('every TBSPC row uses DRIFT', v_n, 0);
            FOR r IN (SELECT 'LINEAR' AS k FROM dual UNION ALL SELECT 'SPIKE' FROM dual
                      UNION ALL SELECT 'ZIGZAG' FROM dual UNION ALL SELECT 'PURGE' FROM dual) LOOP
                SELECT slope_bpd, drift_sd_bpd, slope_ci_bpd, proj_30_bytes, proj_30_lo, proj_30_hi,
                       days_to_full, days_to_full_lo, days_to_full_hi, quality
                  INTO v_num, v_sd, v_ci, v_p, v_lo, v_hi, v_d, v_dlo, v_dhi, v_str
                  FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_' || r.k;
                chk_close('DRIFT ' || r.k || ' slope_bpd (median rate)', v_num, meta_n('DR_' || r.k || '_SLOPE'), 0.000001);
                chk_close('DRIFT ' || r.k || ' drift_sd_bpd', v_sd, meta_n('DR_' || r.k || '_SD'), 0.000001);
                chk_close('DRIFT ' || r.k || ' slope_ci_bpd = t * sd / sqrt(n)', v_ci, meta_n('DR_' || r.k || '_CI'), 0.000001);
                chk_close('DRIFT ' || r.k || ' proj_30_bytes', v_p,  meta_n('DR_' || r.k || '_P30'),    0.000001);
                chk_close('DRIFT ' || r.k || ' proj_30_lo',    v_lo, meta_n('DR_' || r.k || '_P30_LO'), 0.000001);
                chk_close('DRIFT ' || r.k || ' proj_30_hi',    v_hi, meta_n('DR_' || r.k || '_P30_HI'), 0.000001);
                chk_int  ('DRIFT ' || r.k || ' days_to_full',    v_d,   meta_n('DR_' || r.k || '_DTF'));
                chk_true ('DRIFT ' || r.k || ' days_to_full_lo = ' || meta_n('DR_' || r.k || '_DTF_LO')
                          || ' (got ' || v_dlo || ')', v_dlo = meta_n('DR_' || r.k || '_DTF_LO'));
                chk_true ('DRIFT ' || r.k || ' days_to_full_hi = ' || NVL(TO_CHAR(meta_n('DR_' || r.k || '_DTF_HI')), 'NULL')
                          || ' (got ' || NVL(TO_CHAR(v_dhi), 'NULL') || ')',
                          (v_dhi IS NULL AND meta_n('DR_' || r.k || '_DTF_HI') IS NULL)
                          OR v_dhi = meta_n('DR_' || r.k || '_DTF_HI'));
                SELECT sval INTO v_str2 FROM cap_fixture_meta WHERE mkey = 'DR_' || r.k || '_Q';
                chk_str  ('DRIFT ' || r.k || ' quality', v_str, v_str2);
            END LOOP;
            -- The named closed forms behind those rows.
            chk_close('DRIFT LINEAR slope = 10 MiB/day', meta_n('DR_LINEAR_SLOPE'), n_slope, 0.000001);
            chk_int  ('DRIFT LINEAR days_to_full = LINEAR_DTF', meta_n('DR_LINEAR_DTF'), n_dtf);
            chk_close('DRIFT SPIKE slope = 5 MiB/day (the step is 1 of 89 rates)',
                      meta_n('DR_SPIKE_SLOPE'), meta_n('SPIKE_RATE'), 0.000001);
            chk_close('DRIFT SPIKE sd = 2 GiB / sqrt(89)', meta_n('DR_SPIKE_SD'), 2147483648 / SQRT(89), 0.000001);
            chk_close('DRIFT ZIGZAG slope = +50 MiB/day (45 of 89 rates)', meta_n('DR_ZIGZAG_SLOPE'), 50 * 1048576, 0.000001);
            chk_close('DRIFT PURGE slope = 10 MiB/day (post-reset rates)', meta_n('DR_PURGE_SLOPE'), n_slope, 0.000001);
            chk_int  ('DRIFT PURGE days_to_full = PURGE_DTF', meta_n('DR_PURGE_DTF'), meta_n('PURGE_DTF'));
            SELECT reset_day INTO d_reset FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_PURGE';
            chk_int('DRIFT PURGE reset_day unchanged', d_reset - meta_d('PURGE_DAY'), 0);
            SELECT proj_30_lo, proj_30_hi, proj_30_bytes INTO v_lo, v_hi, v_p
              FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
            chk_true('DRIFT LINEAR bands collapse (sd 0)', ABS(v_hi - v_lo) < 1 AND ABS(v_p - meta_n('LINEAR_PRED30_DAY')) < 1);
            SELECT icept + slope_bpd * (last_day - DATE '2020-01-01'), cur_used INTO v_num, v_num2
              FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_ZIGZAG';
            chk_close('DRIFT icept: the anchored line passes through cur_used', v_num, v_num2, 0.000000001);
            SELECT quality INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FLAT';
            chk_str('DRIFT FLAT quality (median rate 0)', v_str, 'FLAT');
            SELECT quality INTO v_str FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_CYCLIC';
            chk_str('DRIFT FIX_CYCLIC still CYCLIC', v_str, 'CYCLIC');
            -- CPU and SERIES follow the knob.
            SELECT COUNT(*) INTO v_n FROM capf_cpu_trend WHERE slope_method <> 'DRIFT';
            chk_int('every CPU row uses DRIFT', v_n, 0);
            SELECT slope_method, slope_per_day, drift_sd_per_day, days_to_limit, quality, proj_30_lo, proj_30_hi
              INTO v_m, v_num, v_sd, v_n, v_str, v_lo, v_hi
              FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'SESSIONS';
            chk_str  ('DRIFT SESSIONS slope_method', v_m, 'DRIFT');
            chk_close('DRIFT SESSIONS slope = 2/day', v_num, 2, 0.000001);
            chk_close('DRIFT SESSIONS sd = 0', v_sd, 0, 0.000001);
            chk_int  ('DRIFT SESSIONS days_to_limit', v_n, meta_n('SESS_DTL'));
            chk_str  ('DRIFT SESSIONS quality', v_str, 'OK');
            chk_true ('DRIFT SESSIONS bands collapse', ABS(v_hi - v_lo) < 0.000001);
            -- CAPF_BACKTEST's REGR replay follows the knob.
            SELECT slope_method, mape_pct, bias_pct INTO v_m, v_num, v_num2
              FROM capf_backtest WHERE series_key = 'FIX_ZIGZAG' AND engine = 'REGR';
            chk_str  ('DRIFT backtest ZIGZAG slope_method', v_m, 'DRIFT');
            chk_close('DRIFT backtest ZIGZAG MAPE%', v_num,  meta_n('ZZ_BT_DR_MAPE'), 0.0001);
            chk_close('DRIFT backtest ZIGZAG BIAS%', v_num2, meta_n('ZZ_BT_DR_BIAS'), 0.0001);
            SELECT mape_pct INTO v_num FROM capf_backtest WHERE series_key = 'FIX_LINEAR' AND engine = 'REGR';
            chk_true('DRIFT backtest LINEAR MAPE ~ 0 (got ' || v_num || ')', ABS(v_num) < 0.000001);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
                COMMIT;
                RAISE;
        END;
        -- THEILSEN in the backtest replay as well.
        UPDATE cap_config SET cfg_value = 1 WHERE cfg_name = 'slope_method';
        BEGIN
            SELECT slope_method, mape_pct, bias_pct INTO v_m, v_num, v_num2
              FROM capf_backtest WHERE series_key = 'FIX_ZIGZAG' AND engine = 'REGR';
            chk_str  ('THEILSEN backtest ZIGZAG slope_method', v_m, 'THEILSEN');
            chk_close('THEILSEN backtest ZIGZAG MAPE%', v_num,  meta_n('ZZ_BT_TS_MAPE'), 0.0001);
            chk_close('THEILSEN backtest ZIGZAG BIAS%', v_num2, meta_n('ZZ_BT_TS_BIAS'), 0.0001);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
                COMMIT;
                RAISE;
        END;
        UPDATE cap_config SET cfg_value = 0 WHERE cfg_name = 'slope_method';
        COMMIT;
        SELECT slope_method INTO v_m FROM capf_backtest WHERE series_key = 'FIX_ZIGZAG' AND engine = 'REGR';
        chk_str('backtest slope_method back to OLS', v_m, 'OLS');
    END;

    DBMS_OUTPUT.PUT_LINE('=== CPU gate, deseasoning, anchor, hot_now ===');
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cpu_quality_gate';
    chk_int('knob cpu_quality_gate default (1 = slope significance)', v_num, 1);
    SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'cpu_deseason';
    chk_int('knob cpu_deseason default (1 = weekday / weekend demeaning)', v_num, 1);
    DECLARE
        n_p2 NUMBER := meta_n('PDB2_CON_DBID');
        n_p1 NUMBER := meta_n('PDB_CON_DBID');
        v_ci NUMBER; v_sig VARCHAR2(1); v_ds VARCHAR2(1); v_anc NUMBER; v_hot VARCHAR2(1);
    BEGIN
        -- Root: no trend by construction. Deseasoned, the slope is the pull
        -- of the injected Tuesday alone, inside its own CI.
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
          WHERE dbid = v_dbid AND con_dbid = v_dbid
            AND slope_sig = 'N' AND deseasoned = 'Y' AND quality IN ('LOW_CONFIDENCE', 'FLAT');
        chk_int('root: all 6 metrics slope_sig N, deseasoned, LOW_CONFIDENCE / FLAT', v_n, 6);
        SELECT slope_per_day, slope_ci_per_day, anchor_value, proj_30, cur_val
          INTO v_num, v_ci, v_anc, v_num2, v_num3
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT';
        chk_close('root BUSY_PCT deseasoned slope', v_num, meta_n('ROOT_BUSY_SLOPE'), 0.000001);
        chk_close('root BUSY_PCT slope_ci', v_ci, meta_n('ROOT_BUSY_CI'), 0.000001);
        chk_close('root BUSY_PCT anchor_value = 40 (median of the last 7 days)', v_anc, meta_n('ROOT_BUSY_ANCHOR'), 0.000001);
        chk_close('root BUSY_PCT anchor_value closed form', meta_n('ROOT_BUSY_ANCHOR'), 40, 0.000001);
        chk_close('root BUSY_PCT proj_30 = anchor + 30 * slope', v_num2, meta_n('ROOT_BUSY_P30'), 0.000001);
        chk_true ('root BUSY_PCT cur_val is the raw last day (got ' || v_num3 || ')', v_num3 IN (20, 40, 70));
        -- FIXPDB1: the +18 step makes the deseasoned slope significant.
        SELECT slope_ci_per_day, slope_sig, quality INTO v_ci, v_sig, v_str
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p1 AND metric = 'DB_CPU_PCT';
        chk_close('PDB DB_CPU_PCT slope_ci', v_ci, meta_n('PDB_DBCPU_CI'), 0.000001);
        chk_str  ('PDB DB_CPU_PCT slope_sig', v_sig, 'Y');
        chk_str  ('PDB DB_CPU_PCT quality (gate 1)', v_str, 'OK');
        -- FIXPDB2: weekday 60 / weekend 20 plus a +1/12 per day ramp.
        SELECT train_n, slope_per_day, slope_ci_per_day, r2, slope_sig, deseasoned, quality,
               anchor_value, proj_30, days_to_sat
          INTO v_n, v_num, v_ci, v_r2, v_sig, v_ds, v_str, v_anc, v_num2, v_num3
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p2 AND metric = 'DB_CPU_PCT';
        chk_int  ('PDB2 DB_CPU_PCT train_n', v_n, meta_n('PDB2_TRAIN_N'));
        chk_close('PDB2 DB_CPU_PCT deseasoned slope', v_num, meta_n('PDB2_PCT_SLOPE'), 0.000001);
        chk_close('PDB2 DB_CPU_PCT slope near the 1/12 ramp', v_num, 1/12, 0.01);
        chk_close('PDB2 DB_CPU_PCT slope_ci', v_ci, meta_n('PDB2_PCT_CI'), 0.00001);
        chk_close('PDB2 DB_CPU_PCT r2 (deseasoned)', v_r2, meta_n('PDB2_PCT_R2'), 0.000001);
        chk_str  ('PDB2 DB_CPU_PCT slope_sig', v_sig, 'Y');
        chk_str  ('PDB2 DB_CPU_PCT deseasoned', v_ds, 'Y');
        chk_str  ('PDB2 DB_CPU_PCT quality (deseason 1, gate 1)', v_str, 'OK');
        chk_close('PDB2 DB_CPU_PCT anchor_value', v_anc, meta_n('PDB2_PCT_ANCHOR'), 0.000001);
        chk_close('PDB2 DB_CPU_PCT proj_30', v_num2, meta_n('PDB2_PCT_P30'), 0.000001);
        chk_int  ('PDB2 DB_CPU_PCT days_to_sat', v_num3, meta_n('PDB2_PCT_DTS'));
        chk_true ('PDB2 DB_CPU_PCT days_to_sat beyond dtf_warn (no DBCPU_SAT)', v_num3 > 90);
        -- hot_now: only FIXPDB2's busy-hour DB CPU sits at or above 80%.
        SELECT recent_p95_med, hot_now, days_to_sat INTO v_anc, v_hot, v_n
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p2 AND metric = 'DB_CPU_P95';
        chk_close('PDB2 DB_CPU_P95 recent_p95_med', v_anc, meta_n('PDB2_P95_RECENT_MED'), 0.000001);
        chk_str  ('PDB2 DB_CPU_P95 hot_now', v_hot, 'Y');
        chk_int  ('PDB2 DB_CPU_P95 days_to_sat (already past 80)', v_n, 0);
        SELECT hot_now, recent_p95_med INTO v_hot, v_anc
          FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_P95';
        chk_str  ('root BUSY_P95 hot_now (58 never reaches 80)', v_hot, 'N');
        chk_close('root BUSY_P95 recent_p95_med = 58', v_anc, meta_n('CPU_PROBE_P95'), 0.000001);
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend WHERE hot_now = 'Y';
        chk_int('exactly one hot_now = Y row', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
          WHERE (metric IN ('BUSY_P95', 'DB_CPU_P95') AND (hot_now IS NULL OR recent_p95_med IS NULL))
             OR (metric NOT IN ('BUSY_P95', 'DB_CPU_P95') AND (hot_now IS NOT NULL OR recent_p95_med IS NOT NULL));
        chk_int('hot_now / recent_p95_med on the two p95 metrics only', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_cpu_trend t JOIN capf_cpu_trend f
            ON f.dbid = t.dbid AND f.con_dbid = t.con_dbid AND f.metric = t.metric
          WHERE NVL(t.hot_now, '-') <> NVL(f.hot_now, '-') OR t.slope_sig <> f.slope_sig
             OR t.deseasoned <> f.deseasoned OR t.anchor_value <> f.anchor_value
             OR NVL(t.recent_p95_med, -1) <> NVL(f.recent_p95_med, -1);
        chk_int('CAPR_CPU_TREND passes slope_sig / deseasoned / anchor_value / hot_now', v_n, 0);
        SELECT hot_now, slope_sig INTO v_num, v_num2 FROM capr_fit
          WHERE kind = 'CPU' AND con_dbid = n_p2 AND series = 'DB_CPU_P95';
        chk_true('CAPR_FIT hot_now = 1, slope_sig = 1 for PDB2 DB_CPU_P95', v_num = 1 AND v_num2 = 1);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind IN ('CPU_SAT', 'DBCPU_SAT');
        chk_int('no CPU_SAT / DBCPU_SAT alert (hot now is not a forecast)', v_n, 0);

        -- Legacy: deseason off and the R^2 gate reproduce the old answers.
        BEGIN
            UPDATE cap_config SET cfg_value = 0 WHERE cfg_name IN ('cpu_deseason', 'cpu_quality_gate');
            SELECT slope_per_day, r2, quality, deseasoned INTO v_num, v_r2, v_str, v_ds
              FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p2 AND metric = 'DB_CPU_PCT';
            chk_close('legacy PDB2 DB_CPU_PCT raw slope', v_num, meta_n('PDB2_PCT_SLOPE_RAW'), 0.000001);
            chk_close('legacy PDB2 DB_CPU_PCT raw r2', v_r2, meta_n('PDB2_PCT_R2_RAW'), 0.000001);
            chk_true ('legacy PDB2 DB_CPU_PCT r2 below r2_gate (' || ROUND(v_r2, 4) || ')', v_r2 < 0.6);
            chk_str  ('legacy PDB2 DB_CPU_PCT quality', v_str, 'LOW_CONFIDENCE');
            chk_str  ('legacy PDB2 DB_CPU_PCT deseasoned', v_ds, 'N');
            SELECT slope_per_day, r2, proj_30 INTO v_num, v_r2, v_num2
              FROM capf_cpu_trend WHERE dbid = v_dbid AND con_dbid = n_p1 AND metric = 'DB_CPU_PCT';
            chk_close('legacy PDB DB_CPU_PCT raw slope', v_num, meta_n('PDB_DBCPU_SLOPE_RAW'), 0.000001);
            chk_close('legacy PDB DB_CPU_PCT raw r2', v_r2, meta_n('PDB_DBCPU_R2_RAW'), 0.000001);
            chk_close('legacy PDB DB_CPU_PCT proj_30 = anchor + 30 * raw slope', v_num2, meta_n('PDB_DBCPU_P30_RAW'), 0.000001);
            SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
              WHERE quality <> CASE WHEN train_n < 14 THEN 'INSUFFICIENT_HISTORY'
                                    WHEN slope_per_day = 0 OR r2 IS NULL THEN 'FLAT'
                                    WHEN r2 < 0.6 THEN 'LOW_CONFIDENCE' ELSE 'OK' END;
            chk_int('legacy gate: every CPU quality is the R^2 ladder', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capf_cpu_trend
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND quality <> 'LOW_CONFIDENCE';
            chk_int('legacy gate: root metrics LOW_CONFIDENCE', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN
                UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name IN ('cpu_deseason', 'cpu_quality_gate');
                COMMIT;
                RAISE;
        END;
        UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name IN ('cpu_deseason', 'cpu_quality_gate');
        COMMIT;
        SELECT quality INTO v_str FROM capf_cpu_trend
          WHERE dbid = v_dbid AND con_dbid = n_p2 AND metric = 'DB_CPU_PCT';
        chk_str('PDB2 DB_CPU_PCT quality back to OK after the restore', v_str, 'OK');
    END;

    DBMS_OUTPUT.PUT_LINE('=== anomaly deviation as % of baseline (median / train_days avg) ===');
    -- FIX_SPIKE: 640 blocks/day (SPIKE_RATE = 5 MiB/day) every day, plus a
    -- 262144-block (2 GiB) step on the spike day, so that day's rate is
    -- SPIKE_RATE + 2 GiB and both baselines are exactly SPIKE_RATE:
    -- 100 * 2 GiB / 5 MiB = 40960.
    -- The step is written as the NUMBER literal 2147483648: 262144 * 8192 as
    -- integer literals overflows PLS_INTEGER (2^31) in PL/SQL.
    DECLARE
        n_train NUMBER;
        n_rate  NUMBER := meta_n('SPIKE_RATE');
        n_pct   NUMBER := 100 * 2147483648 / meta_n('SPIKE_RATE');
        n_avgd  NUMBER;
        n_capa  NUMBER;
    BEGIN
        SELECT cfg_value INTO n_train FROM cap_config WHERE cfg_name = 'train_days';
        -- Deltas exist from day index 1 (index 0 has no predecessor) with no
        -- gaps, and the window is [day - train_days, day - 1], so it covers
        -- LEAST(train_days, spike index - 1) one-day gaps.
        n_avgd := LEAST(n_train, (d_spike - meta_d('BASE_DAY')) - 1);
        SELECT avg_value, avg_days, pct_vs_expected, pct_vs_avg
          INTO v_num, v_n, v_num2, v_num3
          FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'TBSPC' AND series = 'FIX_SPIKE'
            AND baseline_mode = 'TRAILING' AND ts = d_spike;
        chk_close('SPIKE avg_value = SPIKE_RATE', v_num, n_rate, 0.000001);
        chk_int  ('SPIKE avg_days (calendar days the average covers)', v_n, n_avgd);
        chk_close('SPIKE pct_vs_expected (TRAILING)', v_num2, n_pct, 0.000001);
        chk_close('SPIKE pct_vs_avg',    v_num3, n_pct, 0.000001);

        -- Injected Tuesday: 70% busy vs the 40% weekday median -> +75%.
        SELECT pct_vs_expected INTO v_num FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
        chk_close('CPU injected Tuesday pct_vs_expected (SAME_DOW)', v_num, 100 * (70 - 40) / 40, 0.000001);

        -- FIX_PURGE cliff: baseline growth LINEAR_SLOPE (1280 blocks = 10
        -- MiB/day); the cliff day's delta is that growth minus the 76800-block
        -- (600 MiB) purge. Closed form 100 * (-76800 * 8192) / LINEAR_SLOPE = -6000.
        SELECT pct_vs_avg INTO v_num FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'TBSPC' AND series = 'FIX_PURGE'
            AND baseline_mode = 'TRAILING' AND ts = d_purge;
        chk_close('PURGE cliff day pct_vs_avg',
                  v_num, 100 * ((n_slope - 76800 * 8192) - n_slope) / n_slope, 0.000001);

        -- CAPR_ALERTS messages carry the percentages.
        SELECT message INTO v_msg FROM capr_alerts
          WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE' AND day_dt = d_spike;
        chk_true('SPIKE TBSPC_ANOM message has "+' || n_pct || '% vs ' || n_train
                 || '-day avg rate" (got: ' || v_msg || ')',
                 INSTR(v_msg, '+' || TO_CHAR(n_pct, 'FM999999990') || '% vs '
                              || TO_CHAR(n_train, 'FM9990') || '-day avg rate') > 0);
        SELECT message INTO v_msg FROM capr_alerts
          WHERE kind = 'CPU_ANOM' AND series_key = 'BUSY_PCT' AND day_dt = d_inj;
        chk_true('CPU_ANOM message has "+75% vs median" (got: ' || v_msg || ')',
                 INSTR(v_msg, '(+75% vs median)') > 0);

        -- Report views pass the CAPA numbers through unchanged.
        SELECT r.avg_mb, r.avg_days, r.pct_vs_med, r.pct_vs_avg, a.pct_vs_expected, a.pct_vs_avg
          INTO v_num, v_n, v_num2, v_num3, v_r2, n_capa
          FROM capr_tbspc_anomalies r
          JOIN capa_anom a
            ON a.dbid = r.dbid AND a.con_dbid = r.con_dbid AND a.kind = 'TBSPC'
           AND a.series = r.tablespace_name AND a.ts = r.day_dt
           AND a.baseline_mode = r.baseline_mode
          WHERE r.tablespace_name = 'FIX_SPIKE' AND r.day_dt = d_spike
            AND r.baseline_mode = 'TRAILING';
        chk_close('CAPR_TBSPC_ANOMALIES SPIKE avg_mb = 5', v_num, n_rate / 1048576, 0.000001);
        chk_int  ('CAPR_TBSPC_ANOMALIES SPIKE avg_days', v_n, n_avgd);
        chk_close('CAPR_TBSPC_ANOMALIES SPIKE pct_vs_med = CAPA', v_num2, v_r2, 0.000001);
        chk_close('CAPR_TBSPC_ANOMALIES SPIKE pct_vs_avg = CAPA', v_num3, n_capa, 0.000001);
        SELECT r.pct_vs_med, a.pct_vs_expected INTO v_num, v_num2
          FROM capr_cpu_anomalies r
          JOIN capa_anom a
            ON a.dbid = r.dbid AND a.con_dbid = r.con_dbid AND a.kind = 'CPU'
           AND a.series = r.metric AND a.baseline_mode = r.baseline_mode AND a.ts = r.ts
          WHERE r.dbid = v_dbid AND r.con_dbid = v_dbid AND r.metric = 'BUSY_PCT'
            AND r.baseline_mode = 'SAME_DOW' AND r.ts = d_inj;
        chk_close('CAPR_CPU_ANOMALIES Tuesday pct_vs_med = CAPA', v_num, v_num2, 0.000001);
    EXCEPTION
        WHEN OTHERS THEN
            fail('anomaly-% block raised ' || SQLERRM);
    END;

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
        -- ASM_DG:+DATA (20 days to 90%) is the one other SERIES_LIMIT and
        -- TEMP_PEAK:FIX_TEMP (97.5% now) the one SERIES_NEARLIMIT. Both are
        -- asserted in the seam-extension block below.
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_LIMIT' AND series_key IN ('PROCESSES','REDO_GB_DAY','DB_SIZE_GB');
        chk_int('no SERIES_LIMIT for PROCESSES / REDO_GB_DAY / DB_SIZE_GB', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_LIMIT' AND series_key NOT IN ('SESSIONS','ASM_DG:+DATA');
        chk_int('SERIES_LIMIT only for SESSIONS and ASM_DG:+DATA', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_NEARLIMIT' AND series_key = 'SESSIONS';
        chk_int('no SERIES_NEARLIMIT for SESSIONS (88%, under 90)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_NEARLIMIT' AND series_key <> 'TEMP_PEAK:FIX_TEMP';
        chk_int('SERIES_NEARLIMIT only for TEMP_PEAK:FIX_TEMP', v_n, 0);
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

    -- Seam extensions: CAPV_PARAMETER and the cpu_count ceiling, FRA days on
    -- REDO_GB_DAY, the ASM_DG / TEMP_PEAK / UNDO_PEAK series and the
    -- tablespace sizing ask. Closed forms recorded by fixture_install.sql.
    DECLARE
        d_last  DATE   := meta_d('LAST_DAY');
        n_probe NUMBER := meta_n('PROBE_DAY');
        n_caged NUMBER := meta_n('CPU_COUNT_CAGED');
        n_pdbc  NUMBER := meta_n('PDB_CON_DBID');
        n_snaps NUMBER := 2 * (meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1) - 1;
        n_days  NUMBER := meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1;
        v_c     VARCHAR2(1);
        v_q     VARCHAR2(30);
        v_dt    DATE;
        v_dt2   DATE;
        v_a     NUMBER;
        v_b     NUMBER;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== CAPV_PARAMETER and the cpu_count ceiling ===');
        SELECT COUNT(*) INTO v_n FROM capv_parameter WHERE parameter_name = 'cpu_count';
        chk_int('CAPV_PARAMETER cpu_count rows (one per snapshot)', v_n, n_snaps);
        SELECT COUNT(DISTINCT parameter_name) INTO v_n FROM capv_parameter;
        chk_int('CAPV_PARAMETER parameter names', v_n, 9);
        SELECT COUNT(*) INTO v_n FROM capv_parameter WHERE con_dbid <> dbid;
        chk_int('CAPV_PARAMETER rows with con_dbid <> dbid', v_n, 0);
        SELECT cpu_count, cpu_ceiling, num_cpus, db_cpu_pct INTO v_num, v_num2, v_num3, v_a
          FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_int  ('DBTIME probe cpu_count', v_num, meta_n('CPU_COUNT'));
        chk_int  ('DBTIME probe cpu_ceiling = LEAST(num_cpus 8, cpu_count 8)', v_num2, meta_n('NUM_CPUS'));
        chk_int  ('DBTIME probe num_cpus stays the host count', v_num3, meta_n('NUM_CPUS'));
        chk_close('DBTIME probe db_cpu_pct unchanged (cpu_count = NUM_CPUS)',
                  v_a, meta_n('DBCPU_PROBE_PCT'), 0.000001);
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND (cpu_ceiling IS NULL OR cpu_ceiling <> num_cpus);
        chk_int('DBTIME cpu_ceiling = num_cpus on every day (all containers)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_interval
          WHERE dbid = v_dbid
            AND (cpu_ceiling IS NULL OR cpu_ceiling <> num_cpus OR cap_sec <> num_cpus * ivl_sec);
        chk_int('DBTIME_INTERVAL cpu_ceiling = num_cpus, cap_sec = num_cpus * ivl_sec', v_n, 0);
        -- A cage of half the host on the probe day: both of its intervals
        -- end on a snapshot with cpu_count 4, so every percentage doubles.
        SAVEPOINT u8_cage;
        BEGIN
            UPDATE cap_fixture_parameter SET value_num = n_caged
             WHERE parameter_name = 'cpu_count'
               AND snap_id IN (2000 + 2 * n_probe, 2001 + 2 * n_probe);
            SELECT cpu_count, cpu_ceiling, num_cpus INTO v_num, v_num2, v_num3
              FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
            chk_int('caged probe day cpu_count', v_num, n_caged);
            chk_int('caged probe day cpu_ceiling = LEAST(8, 4)', v_num2, n_caged);
            chk_int('caged probe day num_cpus unchanged', v_num3, meta_n('NUM_CPUS'));
            SELECT db_cpu_pct, db_cpu_peak_pct, db_cpu_max_pct INTO v_num, v_num2, v_num3
              FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
            chk_close('caged probe day db_cpu_pct (400 s over 4 CPUs)',
                      v_num, meta_n('DBCPU_PROBE_PCT_CAGED'), 0.000001);
            chk_close('caged probe day db_cpu_pct = 2 x uncaged',
                      v_num, 2 * meta_n('DBCPU_PROBE_PCT'), 0.000001);
            chk_close('caged probe day db_cpu_peak_pct (300 s over 4 * 43200)',
                      v_num2, meta_n('DBCPU_PROBE_PEAK_PCT_CAGED'), 0.000001);
            chk_close('caged probe day db_cpu_max_pct (the 18:00 interval)',
                      v_num3, meta_n('DBCPU_PROBE_PEAK_PCT_CAGED'), 0.000001);
            SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND cpu_ceiling = n_caged;
            chk_int('only the probe day is caged', v_n, 1);
            -- The cage lives in CAPD_DBTIME_INTERVAL, so the hour grain (and
            -- the HOUR_OF_WEEK baseline) reads against it too, and it serves
            -- every container: cpu_count is instance level.
            SELECT cpu_count, cpu_ceiling, cap_sec INTO v_num, v_num2, v_num3
              FROM capd_dbtime_interval
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND snap_id = 2001 + 2 * n_probe;
            chk_int  ('caged probe 18:00 interval cpu_count', v_num, n_caged);
            chk_int  ('caged probe 18:00 interval cpu_ceiling', v_num2, n_caged);
            chk_close('caged probe 18:00 interval cap_sec = 4 * 43200', v_num3, n_caged * 43200, 0.000001);
            SELECT value INTO v_num FROM capd_cpu_hourly
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'DB_CPU_PCT' AND hour_ts = d_probe + 18/24;
            chk_close('caged probe 18:00 root hourly DB_CPU_PCT (300 s over 4 * 43200)',
                      v_num, meta_n('DBCPU_PROBE_PEAK_PCT_CAGED'), 0.000001);
            SELECT MIN(value), MAX(value) INTO v_num, v_num2 FROM capd_cpu_hourly
              WHERE dbid = v_dbid AND con_dbid = n_pdbc AND metric = 'DB_CPU_PCT'
                AND hour_ts IN (d_probe + 6/24, d_probe + 18/24);
            chk_close('caged probe PDB hourly DB_CPU_PCT 06:00 = 2 x pdb_pct(probe)',
                      v_num,  2 * meta_n('PDB_PROBE_PCT'), 0.000001);
            chk_close('caged probe PDB hourly DB_CPU_PCT 18:00 = 2 x pdb_pct(probe)',
                      v_num2, 2 * meta_n('PDB_PROBE_PCT'), 0.000001);
            SELECT db_cpu_pct INTO v_num FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = n_pdbc AND day_dt = d_probe;
            chk_close('caged probe PDB db_cpu_pct = 2 x pdb_pct(probe)',
                      v_num, 2 * meta_n('PDB_PROBE_PCT'), 0.000001);
            -- cpu_count over the host: the host stays the ceiling.
            v_b := 2 * meta_n('NUM_CPUS');
            UPDATE cap_fixture_parameter SET value_num = v_b
             WHERE parameter_name = 'cpu_count'
               AND snap_id IN (2000 + 2 * n_probe, 2001 + 2 * n_probe);
            SELECT cpu_count, cpu_ceiling, db_cpu_pct INTO v_num, v_num2, v_num3
              FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
            chk_int  ('cpu_count 16 on the probe day', v_num, 2 * meta_n('NUM_CPUS'));
            chk_int  ('cpu_count 16 -> cpu_ceiling = num_cpus 8', v_num2, meta_n('NUM_CPUS'));
            chk_close('cpu_count 16 -> db_cpu_pct unchanged', v_num3, meta_n('DBCPU_PROBE_PCT'), 0.000001);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u8_cage; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u8_cage;

        DBMS_OUTPUT.PUT_LINE('=== FRA days on REDO_GB_DAY ===');
        SELECT fra_size_gb, fra_days_at_cur INTO v_num, v_num2
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
        chk_close('REDO fra_size_gb (100 GiB)', v_num, meta_n('FRA_SIZE_GB'), 0.000001);
        chk_close('REDO fra_days_at_cur (100 GiB / 2.0 GiB/day)', v_num2, meta_n('FRA_DAYS'), 0.000001);
        SELECT COUNT(*) INTO v_n FROM capf_series_forecast
          WHERE series <> 'REDO_GB_DAY' AND (fra_size_gb IS NOT NULL OR fra_days_at_cur IS NOT NULL);
        chk_int('FRA columns NULL off REDO_GB_DAY', v_n, 0);
        SELECT fra_size_gb, fra_days_at_cur INTO v_num, v_num2
          FROM capr_series WHERE dbid = v_dbid AND series = 'REDO_GB_DAY';
        chk_close('CAPR_SERIES passes fra_size_gb',     v_num,  meta_n('FRA_SIZE_GB'), 0.000001);
        chk_close('CAPR_SERIES passes fra_days_at_cur', v_num2, meta_n('FRA_DAYS'),    0.000001);
        SAVEPOINT u8_fra;
        BEGIN
            UPDATE cap_fixture_parameter SET value_num = 0
             WHERE parameter_name = 'db_recovery_file_dest_size';
            SELECT COUNT(*) INTO v_n FROM capf_series_forecast
              WHERE dbid = v_dbid AND series = 'REDO_GB_DAY'
                AND fra_size_gb IS NULL AND fra_days_at_cur IS NULL;
            chk_int('FRA size 0 -> fra_size_gb and fra_days_at_cur NULL', v_n, 1);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u8_fra; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u8_fra;
        -- FIXPDB1 writes redo too, 1 GiB per interval on the last day only:
        -- the FRA holds the dbid's summed rate, so both REDO rows read
        -- 100 / (2 + 2) = 25 days.
        SAVEPOINT u8_fra2;
        BEGIN
            v_a := meta_n('PDB_CON_DBID');
            v_b := meta_n('FRA_SIZE_GB') / (2 * meta_n('REDO_PROBE_GB'));
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, v_a, 1, 2001 + 2 * (n_days - 2), 'redo size', 0);
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, v_a, 1, 2000 + 2 * (n_days - 1), 'redo size', 1073741824);
            INSERT INTO cap_fixture_sysstat VALUES (v_dbid, v_a, 1, 2001 + 2 * (n_days - 1), 'redo size', 2147483648);
            SELECT cur_val INTO v_num FROM capf_series_forecast
              WHERE dbid = v_dbid AND con_dbid = v_a AND series = 'REDO_GB_DAY';
            chk_close('FIXPDB1 REDO_GB_DAY cur_val (two 1 GiB intervals)', v_num, meta_n('REDO_PROBE_GB'), 0.000001);
            SELECT COUNT(*) INTO v_n FROM capf_series_forecast
              WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND ABS(fra_days_at_cur - v_b) < 0.000001;
            chk_int('two containers: both REDO rows fra_days_at_cur = 100 / (2 + 2)', v_n, 2);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u8_fra2; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u8_fra2;

        DBMS_OUTPUT.PUT_LINE('=== ASM diskgroups (ASM_DG series) ===');
        SELECT COUNT(*) INTO v_n FROM capv_asm_diskgroup;
        chk_int('CAPV_ASM_DISKGROUP rows (2 groups x every snapshot)', v_n, 2 * n_snaps);
        SELECT value, limit_value, unit, covered_sec, is_complete INTO v_num, v_num2, v_str, v_num3, v_c
          FROM capd_series_daily WHERE dbid = v_dbid AND series = 'ASM_DG:+DATA' AND day_dt = d_last;
        chk_close('ASM_DG:+DATA last-day value (GiB used)', v_num,  meta_n('ASM_DATA_CUR'),   0.000001);
        chk_close('ASM_DG:+DATA limit_value (total GiB)',   v_num2, meta_n('ASM_DATA_LIMIT'), 0.000001);
        chk_str  ('ASM_DG:+DATA unit', v_str, 'GIB');
        chk_true ('ASM_DG:+DATA covered_sec NULL, is_complete Y (level series)',
                  v_num3 IS NULL AND v_c = 'Y');
        SELECT value INTO v_num FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'ASM_DG:+DATA' AND day_dt = d_probe;
        chk_close('ASM_DG:+DATA probe day = the 18:00 (last) sample, not 06:00',
                  v_num, meta_n('ASM_DATA_PROBE'), 0.000001);
        SELECT slope_per_day, days_to_limit, quality, pct_of_limit, proj_30
          INTO v_num, v_n, v_str, v_num2, v_num3
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'ASM_DG:+DATA';
        chk_close('ASM_DG:+DATA slope (GiB/day)', v_num, meta_n('ASM_DATA_SLOPE'), 0.000001);
        chk_int  ('ASM_DG:+DATA days_to_limit (90% of 1000 GiB)', v_n, meta_n('ASM_DATA_DTL'));
        chk_str  ('ASM_DG:+DATA quality', v_str, 'OK');
        chk_close('ASM_DG:+DATA pct_of_limit', v_num2, meta_n('ASM_DATA_PCT'), 0.000001);
        chk_close('ASM_DG:+DATA proj_30 = 800 + 5 * 30', v_num3, meta_n('ASM_DATA_P30'), 0.000001);
        SELECT COUNT(*), MAX(value), MAX(severity) INTO v_n, v_num, v_str
          FROM capr_alerts WHERE kind = 'SERIES_LIMIT' AND series_key = 'ASM_DG:+DATA';
        chk_int('ASM_DG:+DATA raises one SERIES_LIMIT', v_n, 1);
        chk_int('ASM_DG:+DATA SERIES_LIMIT value = days_to_limit', v_num, meta_n('ASM_DATA_DTL'));
        chk_str('ASM_DG:+DATA SERIES_LIMIT severity (20 <= dtf_crit)', v_str, 'CRIT');
        SELECT sev INTO v_str FROM capr_series WHERE dbid = v_dbid AND series = 'ASM_DG:+DATA';
        chk_str('CAPR_SERIES ASM_DG:+DATA sev', v_str, 'CRIT');
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'SERIES' AND series = 'ASM_DG:+DATA';
        chk_int('CAPR_SERIES_POINTS one ASM_DG:+DATA point per day', v_n, n_days);
        SELECT value INTO v_num FROM capr_forecast_points
          WHERE kind = 'SERIES' AND series = 'ASM_DG:+DATA' AND method = 'REGR' AND horizon_days = 30;
        chk_close('CAPR_FORECAST_POINTS ASM_DG:+DATA +30', v_num, meta_n('ASM_DATA_P30'), 0.000001);
        SELECT cur_val, cur_limit, quality, days_to_limit INTO v_num, v_num2, v_str, v_n
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'ASM_DG:+FRA';
        chk_close('ASM_DG:+FRA cur_val',   v_num,  meta_n('ASM_FRA_CUR'),   0.000001);
        chk_close('ASM_DG:+FRA cur_limit', v_num2, meta_n('ASM_FRA_LIMIT'), 0.000001);
        chk_str  ('ASM_DG:+FRA quality (constant -> FLAT)', v_str, 'FLAT');
        chk_true ('ASM_DG:+FRA days_to_limit IS NULL', v_n IS NULL);

        DBMS_OUTPUT.PUT_LINE('=== TEMP / UNDO peaks ===');
        SELECT value, limit_value, unit INTO v_num, v_num2, v_str
          FROM capd_series_daily WHERE dbid = v_dbid AND series = 'TEMP_PEAK:FIX_TEMP' AND day_dt = d_last;
        chk_close('TEMP_PEAK last day = the 06:00 peak (the 18:00 sample reads 1 GiB)',
                  v_num, meta_n('TEMP_CUR'), 0.000001);
        chk_close('TEMP_PEAK limit_value (allocated, no autoextend)', v_num2, meta_n('TEMP_LIMIT'), 0.000001);
        chk_str  ('TEMP_PEAK unit', v_str, 'GIB');
        SELECT value INTO v_num FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'TEMP_PEAK:FIX_TEMP' AND day_dt = d_probe;
        chk_close('TEMP_PEAK probe day peak', v_num, meta_n('TEMP_PROBE'), 0.000001);
        SELECT cur_val, pct_of_limit, slope_per_day, r2, quality, days_to_limit
          INTO v_num, v_num2, v_num3, v_r2, v_q, v_n
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'TEMP_PEAK:FIX_TEMP';
        chk_close('TEMP_PEAK cur_val', v_num, meta_n('TEMP_CUR'), 0.000001);
        chk_close('TEMP_PEAK pct_of_limit', v_num2, meta_n('TEMP_PCT'), 0.000001);
        chk_close('TEMP_PEAK slope (OLS, i = 31..120)', v_num3, meta_n('TEMP_SLOPE'), 0.000001);
        chk_close('TEMP_PEAK r2', v_r2, meta_n('TEMP_R2'), 0.000001);
        SELECT sval INTO v_str FROM cap_fixture_meta WHERE mkey = 'TEMP_Q';
        chk_str  ('TEMP_PEAK quality', v_q, v_str);
        chk_true ('TEMP_PEAK days_to_limit IS NULL (slope < 0)', v_n IS NULL AND meta_n('TEMP_SLOPE') < 0);
        SELECT COUNT(*), MAX(value), MAX(severity) INTO v_n, v_num, v_str
          FROM capr_alerts WHERE kind = 'SERIES_NEARLIMIT' AND series_key = 'TEMP_PEAK:FIX_TEMP';
        chk_int  ('TEMP_PEAK raises one SERIES_NEARLIMIT', v_n, 1);
        chk_close('TEMP_PEAK SERIES_NEARLIMIT value = pct_of_limit', v_num, meta_n('TEMP_PCT'), 0.000001);
        chk_str  ('TEMP_PEAK SERIES_NEARLIMIT severity (97.5 >= nearfull_crit_pct)', v_str, 'CRIT');
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_LIMIT' AND series_key LIKE 'TEMP!_PEAK:%' ESCAPE '!';
        chk_int('TEMP_PEAK raises no SERIES_LIMIT (not growing)', v_n, 0);
        SELECT cur_val, cur_limit, pct_of_limit, quality INTO v_num, v_num2, v_num3, v_str
          FROM capf_series_forecast WHERE dbid = v_dbid AND series = 'UNDO_PEAK:FIX_UNDO';
        chk_close('UNDO_PEAK cur_val (18:00 peak)',             v_num,  meta_n('UNDO_CUR'),   0.000001);
        chk_close('UNDO_PEAK cur_limit (autoextend maxsize)',   v_num2, meta_n('UNDO_LIMIT'), 0.000001);
        chk_close('UNDO_PEAK pct_of_limit',                     v_num3, meta_n('UNDO_PCT'),   0.000001);
        chk_str  ('UNDO_PEAK quality (constant -> FLAT)', v_str, 'FLAT');
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE series_key = 'UNDO_PEAK:FIX_UNDO';
        chk_int('UNDO_PEAK raises no alert', v_n, 0);
        -- CAPD_TBSPC_DAILY keeps its contents exclusion: neither tablespace
        -- reaches the tablespace layers, DB_SIZE_GB included.
        SELECT COUNT(*) INTO v_n FROM capd_tbspc_daily WHERE tablespace_name IN ('FIX_TEMP','FIX_UNDO');
        chk_int('no FIX_TEMP / FIX_UNDO rows in CAPD_TBSPC_DAILY', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast WHERE tablespace_name IN ('FIX_TEMP','FIX_UNDO');
        chk_int('no FIX_TEMP / FIX_UNDO rows in CAPF_TBSPC_FORECAST', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'SERIES' AND series IN ('TEMP_PEAK:FIX_TEMP','UNDO_PEAK:FIX_UNDO');
        chk_int('CAPR_SERIES_POINTS one TEMP / UNDO point per day each', v_n, 2 * n_days);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE (series LIKE 'ASM!_DG:%' ESCAPE '!' OR series LIKE 'TEMP!_PEAK:%' ESCAPE '!'
                 OR series LIKE 'UNDO!_PEAK:%' ESCAPE '!')
            AND (covered_sec IS NOT NULL OR is_complete <> 'Y' OR unit <> 'GIB');
        chk_int('ASM / TEMP / UNDO series: unit GIB, covered_sec NULL, is_complete Y', v_n, 0);
        -- The anomaly engine scores only the series in its registry (sreg in
        -- CAPA_OBS: the four M11 names), so the new series are never scored:
        -- no observation, no SERIES_ANOM, no verdict on their points.
        SELECT COUNT(*) INTO v_n FROM capa_obs
          WHERE kind = 'SERIES'
            AND (series LIKE 'ASM!_DG:%' ESCAPE '!' OR series LIKE 'TEMP!_PEAK:%' ESCAPE '!'
                 OR series LIKE 'UNDO!_PEAK:%' ESCAPE '!');
        chk_int('ASM / TEMP / UNDO series have no CAPA_OBS rows (not in the registry)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_ANOM'
            AND (series_key LIKE 'ASM!_DG:%' ESCAPE '!' OR series_key LIKE 'TEMP!_PEAK:%' ESCAPE '!'
                 OR series_key LIKE 'UNDO!_PEAK:%' ESCAPE '!');
        chk_int('ASM / TEMP / UNDO series raise no SERIES_ANOM', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'SERIES'
            AND (series LIKE 'ASM!_DG:%' ESCAPE '!' OR series LIKE 'TEMP!_PEAK:%' ESCAPE '!'
                 OR series LIKE 'UNDO!_PEAK:%' ESCAPE '!')
            AND (anomaly_flag IS NOT NULL OR z IS NOT NULL OR expected IS NOT NULL
                 OR anomaly_modes IS NOT NULL);
        chk_int('ASM / TEMP / UNDO points carry no anomaly verdict', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== sizing ask (need_gib_h, add_by_day) ===');
        SELECT need_gib_30, need_gib_90, need_gib_180 INTO v_num, v_num2, v_num3
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FILLING';
        chk_close('FILLING need_gib_30',  v_num,  meta_n('FILLING_NEED_30'),  0.000001);
        chk_close('FILLING need_gib_90',  v_num2, meta_n('FILLING_NEED_90'),  0.000001);
        chk_close('FILLING need_gib_180', v_num3, meta_n('FILLING_NEED_180'), 0.000001);
        SELECT add_by_day, last_day, days_to_full_lo INTO v_dt, v_dt2, v_a
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_FILLING';
        chk_true('FILLING add_by_day = last_day + days_to_full_lo', v_dt = v_dt2 + v_a);
        -- headroom / slope is exactly 20.0, so a rounding epsilon on the
        -- collapsed slope CI may FLOOR the worst case to 19 (as for FIX_LINEAR).
        chk_true('FILLING add_by_day in last_day + [19, 20] (got +' || (v_dt - v_dt2) || ')',
                 v_dt - v_dt2 BETWEEN meta_n('FILLING_DTF') - 1 AND meta_n('FILLING_DTF'));
        SELECT need_gib_30, need_gib_90, need_gib_180 INTO v_num, v_num2, v_num3
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_LINEAR';
        chk_int('LINEAR need_gib_30 (4990 days of headroom)', v_num,  0);
        chk_int('LINEAR need_gib_90',                         v_num2, 0);
        chk_int('LINEAR need_gib_180',                        v_num3, 0);
        -- A ceiling under the usage asks for the overage at every horizon,
        -- with no date (FLAT: no days_to_full_lo).
        SELECT need_gib_30, need_gib_180, add_by_day INTO v_num, v_num2, v_dt
          FROM capf_tbspc_forecast WHERE tablespace_name = 'FIX_OVERFULL';
        chk_close('OVERFULL need_gib_30 = (1.5 - 1) GiB', v_num,
                  (meta_n('OVERFULL_CUR') - meta_n('OVERFULL_LIMIT')) / 1073741824, 0.000001);
        chk_close('OVERFULL need_gib_180 = (1.5 - 1) GiB', v_num2,
                  (meta_n('OVERFULL_CUR') - meta_n('OVERFULL_LIMIT')) / 1073741824, 0.000001);
        chk_true ('OVERFULL add_by_day IS NULL (FLAT)', v_dt IS NULL);
        SELECT COUNT(*) INTO v_n FROM capf_tbspc_forecast
          WHERE quality = 'CYCLIC' AND (need_gib_90 IS NOT NULL OR add_by_day IS NOT NULL);
        chk_int('CYCLIC rows carry no sizing ask', v_n, 0);
        SELECT need_gib_90, add_by_day INTO v_num, v_dt
          FROM capr_tbspc_days_to_full WHERE tablespace_name = 'FIX_FILLING';
        chk_close('CAPR_TBSPC_DAYS_TO_FULL passes need_gib_90', v_num, meta_n('FILLING_NEED_90'), 0.000001);
        chk_true ('CAPR_TBSPC_DAYS_TO_FULL passes add_by_day', v_dt = v_dt2 + v_a);
        SELECT need_gib_90, add_by_day INTO v_num, v_dt
          FROM capr_fit WHERE kind = 'TBSPC' AND series = 'FIX_FILLING';
        chk_close('CAPR_FIT passes need_gib_90', v_num, meta_n('FILLING_NEED_90'), 0.000001);
        chk_true ('CAPR_FIT passes add_by_day', v_dt = v_dt2 + v_a);
        SELECT COUNT(*) INTO v_n FROM capr_fit
          WHERE kind <> 'TBSPC' AND (need_gib_30 IS NOT NULL OR need_gib_90 IS NOT NULL
                                     OR need_gib_180 IS NOT NULL OR add_by_day IS NOT NULL);
        chk_int('CAPR_FIT sizing ask NULL for CPU / SERIES', v_n, 0);
    EXCEPTION
        WHEN OTHERS THEN
            fail('seam-extension block raised ' || SQLERRM);
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
        SELECT anomaly_flag, gap_flag, ABS(dev), threshold
          INTO v_str, v_gflag, v_dev, v_thr
          FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_gnext;
        chk_str ('CPU post-gap day exposes gap_flag', v_gflag, 'Y');
        chk_true('CPU post-gap day WOULD have flagged (|dev| ' || ROUND(v_dev,2)
                 || ' > thr ' || ROUND(v_thr,2) || ')', v_dev > v_thr);
        chk_true('CPU post-gap day anomaly_flag IS NULL (gap guard)', v_str IS NULL);

        -- ...and it is not allowed to poison the next week's baseline either.
        SELECT n_hist INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_gnext + 7;
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
        SELECT n_hist INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
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
        -- DB_CPU_PCT, FIXPDB1 and FIXPDB2 (time-model only) DB_CPU_PCT alone.
        SELECT COUNT(*) INTO v_n FROM capa_cpu_shift WHERE dbid = v_dbid;
        chk_int('CAPA_CPU_SHIFT row count (3 root + 1 per PDB, 2 PDBs)', v_n, 5);

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

        -- The PDB has no host busy% at all (OSSTAT is CDB-level), so no
        -- BUSY_PCT row; its step days are scored on DB_CPU_PCT instead, where
        -- each is 18 points over its identical same-weekday priors.
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND series = 'BUSY_PCT';
        chk_int('PDB has no BUSY_PCT anomaly rows', v_n, 0);
        chk_int('PDB DB_CPU_PCT SAME_DOW HIGH = the 7 step days',
                anom_n('CPU', 'DB_CPU_PCT', 'SAME_DOW', 'HIGH', n_pdb), 7);
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

    -- Seam / daily-layer contract: one counter-delta view, coverage columns,
    -- the logical-CPU denominator and CAPV_CONTRACT. Every expectation is a
    -- closed form recorded by fixture_install.sql.
    DECLARE
        d_part  DATE   := meta_d('PARTIAL_DAY');
        d_base  DATE   := meta_d('BASE_DAY');
        d_last  DATE   := meta_d('LAST_DAY');
        d_gap   DATE   := meta_d('CPUGAP_DAY');
        d_gnext DATE   := meta_d('CPUGAP_NEXT');
        n_pdb   NUMBER := meta_n('PDB_CON_DBID');
        n_full  NUMBER := meta_n('FULL_COVERED_SEC');
        n_half  NUMBER := meta_n('PARTIAL_COVERED_SEC');
        n_snaps NUMBER := 2 * (meta_d('LAST_DAY') - meta_d('BASE_DAY') + 1) - 1;
        v_c     VARCHAR2(1);
        v_g     VARCHAR2(1);
        v_a     NUMBER;
        v_b     NUMBER;
        v_cnt0  NUMBER;
        v_ts    DATE;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== logical-CPU denominator (NUM_CPUS 8, NUM_CPU_CORES 4) ===');
        SELECT num_cpus, num_cpu_cores, db_cpu_per_core, db_cpu_pct, host_share_pct
          INTO v_num, v_num2, v_num3, v_a, v_b
          FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_int  ('DBTIME probe num_cpus (logical)', v_num,  meta_n('NUM_CPUS'));
        chk_int  ('DBTIME probe num_cpu_cores',      v_num2, meta_n('NUM_CPU_CORES'));
        chk_close('DBTIME probe db_cpu_per_core stays on cores (400 s / 4)',
                  v_num3, meta_n('DBCPU_PROBE_PER_CORE'), 0.000001);
        SELECT busy_pct INTO v_num FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_close('db_cpu_pct = busy_pct * host_share_pct / 100 (same scale as host busy%)',
                  v_a, v_num * v_b / 100, 0.000001);
        SELECT db_cpu_pct INTO v_num FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND day_dt = d_probe;
        chk_close('PDB probe db_cpu_pct (sawtooth level of 8 logical CPUs)',
                  v_num, meta_n('PDB_PROBE_PCT'), 0.000001);
        -- The gap day has no OSSTAT row at all, but FIXPDB1 still has its
        -- time model there: NUM_CPUS comes from the previous snapshot.
        SELECT db_cpu_pct, num_cpus INTO v_num, v_num2 FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND day_dt = d_gap;
        chk_close('PDB gap-day db_cpu_pct (NUM_CPUS carried forward)',
                  v_num, meta_n('PDB_GAP_PCT'), 0.000001);
        chk_int  ('PDB gap-day num_cpus carried forward', v_num2, meta_n('NUM_CPUS'));
        -- No NUM_CPUS at all: the denominator falls back to NUM_CPU_CORES.
        SAVEPOINT u3_ncpu;
        BEGIN
            DELETE FROM cap_fixture_osstat WHERE stat_name = 'NUM_CPUS';
            SELECT db_cpu_pct INTO v_num FROM capd_dbtime_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
            chk_close('db_cpu_pct with NUM_CPUS missing (falls back to 4 cores)',
                      v_num, meta_n('DBCPU_PROBE_PCT_CORES'), 0.000001);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u3_ncpu; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u3_ncpu;

        DBMS_OUTPUT.PUT_LINE('=== day coverage (covered_sec / is_complete) ===');
        SELECT cfg_value INTO v_num FROM cap_config WHERE cfg_name = 'complete_day_pct';
        chk_int('knob complete_day_pct default', v_num, 80);
        -- The partial day: its noon restart drops the 18:00 interval, so only
        -- the 12 h night interval is left. No long interval, so no gap flag.
        SELECT covered_sec, is_complete, gap_flag, max_interval_hours, n_intervals, busy_pct
          INTO v_num, v_c, v_g, v_num2, v_n, v_num3
          FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_part;
        chk_int  ('CPU partial day covered_sec (12 h)', v_num, n_half);
        chk_str  ('CPU partial day is_complete', v_c, 'N');
        chk_str  ('CPU partial day gap_flag stays N', v_g, 'N');
        chk_close('CPU partial day max_interval_hours', v_num2, 12, 0.000001);
        chk_int  ('CPU partial day n_intervals', v_n, 1);
        chk_close('CPU partial day busy_pct (night interval only)',
                  v_num3, meta_n('PARTIAL_BUSY_PCT'), 0.000001);
        SELECT covered_sec, is_complete, db_cpu_pct INTO v_num, v_c, v_num2
          FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_part;
        chk_int  ('DBTIME partial day covered_sec', v_num, n_half);
        chk_str  ('DBTIME partial day is_complete', v_c, 'N');
        chk_close('DBTIME partial day db_cpu_pct (over the 12 h covered)',
                  v_num2, meta_n('PARTIAL_DBCPU_PCT'), 0.000001);
        SELECT covered_sec, is_complete, db_cpu_pct INTO v_num, v_c, v_num2
          FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND day_dt = d_part;
        chk_int  ('PDB partial day covered_sec', v_num, n_half);
        chk_str  ('PDB partial day is_complete', v_c, 'N');
        chk_close('PDB partial day db_cpu_pct (level unchanged by coverage)',
                  v_num2, meta_n('PDB_PARTIAL_PCT'), 0.000001);
        SELECT value, covered_sec, is_complete INTO v_num, v_num2, v_c
          FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_part;
        chk_close('REDO partial day GiB (one 1 GiB interval)', v_num, meta_n('REDO_PARTIAL_GB'), 0.000001);
        chk_int  ('REDO partial day covered_sec', v_num2, n_half);
        chk_str  ('REDO partial day is_complete', v_c, 'N');

        -- A normal day is complete in all three flow views.
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_int('CPU probe day covered_sec', v_num, n_full);
        chk_str('CPU probe day is_complete', v_c, 'Y');
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_probe;
        chk_int('DBTIME probe day covered_sec', v_num, n_full);
        chk_str('DBTIME probe day is_complete', v_c, 'Y');
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_probe;
        chk_int('REDO probe day covered_sec', v_num, n_full);
        chk_str('REDO probe day is_complete', v_c, 'Y');

        -- The first day of history: its 06:00 snapshot has no predecessor.
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_base;
        chk_int('CPU first day covered_sec (series start)', v_num, n_half);
        chk_str('CPU first day is_complete', v_c, 'N');

        -- The post-gap day covers 48 h. It is complete, gap-flagged, and its
        -- db_cpu_pct is the average over those 48 h.
        SELECT covered_sec, is_complete INTO v_num, v_c FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gnext;
        chk_int('CPU post-gap day covered_sec (36 h + 12 h)', v_num, meta_n('CPUGAP_COVERED_SEC'));
        chk_str('CPU post-gap day is_complete', v_c, 'Y');
        SELECT covered_sec, db_cpu_pct INTO v_num, v_num2 FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND day_dt = d_gnext;
        chk_int  ('DBTIME post-gap day covered_sec', v_num, meta_n('CPUGAP_COVERED_SEC'));
        chk_close('DBTIME post-gap day db_cpu_pct (over 48 h covered)',
                  v_num2, meta_n('CPUGAP_DBCPU_PCT'), 0.000001);

        -- Exactly two incomplete days per flow series: the first day and the
        -- partial day (the restart day and the gap day have no row at all).
        SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND is_complete = 'N';
        chk_int('CPU incomplete days (first + partial)', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND is_complete = 'N';
        chk_int('DBTIME root incomplete days', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND is_complete = 'N';
        chk_int('DBTIME PDB incomplete days', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND is_complete = 'N';
        chk_int('REDO incomplete days', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY'
            AND (covered_sec IS NULL
                 OR is_complete <> CASE WHEN covered_sec >= 0.80 * 86400 THEN 'Y' ELSE 'N' END);
        chk_int('REDO is_complete agrees with covered_sec on every row', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE series IN ('PROCESSES','SESSIONS','DB_SIZE_GB')
            AND (covered_sec IS NOT NULL OR is_complete <> 'Y');
        chk_int('level series carry covered_sec NULL, is_complete Y', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== CAPD_COUNTER_DELTA (one LAG + restart rule) ===');
        -- The restart day holds one interval per counter source, and it is
        -- the restart: none survives, which is why the day has no CPU row.
        FOR r IN (SELECT 'OSSTAT' AS src, v_dbid AS con FROM dual
                  UNION ALL SELECT 'TIME_MODEL', v_dbid FROM dual
                  UNION ALL SELECT 'SYSSTAT',    v_dbid FROM dual
                  UNION ALL SELECT 'TIME_MODEL', n_pdb  FROM dual) LOOP
            SELECT COUNT(DISTINCT CASE WHEN is_restart = 'Y' THEN snap_id END),
                   COUNT(DISTINCT CASE WHEN is_restart = 'N' THEN snap_id END)
              INTO v_a, v_b
              FROM capd_counter_delta
              WHERE dbid = v_dbid AND con_dbid = r.con AND source = r.src
                AND TRUNC(end_time) = d_restart;
            chk_int(r.src || ' con ' || r.con || ' restart-day is_restart=Y intervals', v_a, 1);
            chk_int(r.src || ' con ' || r.con || ' restart-day is_restart=N intervals', v_b, 0);
        END LOOP;
        SELECT MAX(ivl_sec) INTO v_num FROM capd_counter_delta
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND source = 'OSSTAT'
            AND TRUNC(end_time) = d_restart;
        chk_int('restart interval spans 24 h (18:00 to 18:00)', v_num, 86400);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
          WHERE dbid = v_dbid AND day_dt = d_restart;
        chk_int('excluding is_restart=Y leaves no CPU row on the restart day', v_n, 0);
        -- Over the whole series: the day-60 restart and the partial day's.
        SELECT COUNT(DISTINCT snap_id) INTO v_n FROM capd_counter_delta
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND source = 'OSSTAT' AND is_restart = 'Y';
        chk_int('OSSTAT restart intervals in the series', v_n, 2);

        -- NULL startup_time (a warehouse may not fill it): the series must
        -- survive, with restarts still caught by their negative deltas.
        SELECT COUNT(*) INTO v_cnt0 FROM capd_cpu_daily WHERE dbid = v_dbid;
        SAVEPOINT u3_nullstart;
        BEGIN
            UPDATE cap_fixture_snapshot SET startup_time = NULL;
            SELECT COUNT(*) INTO v_n FROM capd_cpu_daily WHERE dbid = v_dbid;
            chk_int('CPU rows with startup_time NULL = rows with it set', v_n, v_cnt0);
            SELECT COUNT(DISTINCT snap_id) INTO v_n FROM capd_counter_delta
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND source = 'OSSTAT' AND is_restart = 'Y';
            chk_int('restarts found by negative delta with startup_time NULL', v_n, 2);
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK TO SAVEPOINT u3_nullstart; RAISE;
        END;
        ROLLBACK TO SAVEPOINT u3_nullstart;

        DBMS_OUTPUT.PUT_LINE('=== CAPV_CONTRACT ===');
        SELECT COUNT(*) INTO v_n FROM capv_contract;
        chk_int('CAPV_CONTRACT one row per seam source', v_n, 8);
        SELECT COUNT(*) INTO v_n FROM capv_contract
          WHERE (source_name IN ('TBSPC_USAGE','TIME_MODEL','SYSSTAT')       AND per_container_expected = 'Y')
             OR (source_name IN ('OSSTAT','RESOURCE_LIMIT','SNAPSHOT',
                                 'PARAMETER','ASM_DISKGROUP')                AND per_container_expected = 'N');
        chk_int('CAPV_CONTRACT per_container_expected as specified', v_n, 8);
        -- PARAMETER: 9 names on every snapshot. ASM_DISKGROUP: 2 groups.
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'PARAMETER';
        chk_int('CAPV_CONTRACT PARAMETER n_rows', v_num, 9 * n_snaps);
        chk_int('CAPV_CONTRACT PARAMETER n_con_dbid (instance level)', v_num2, 1);
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'ASM_DISKGROUP';
        chk_int('CAPV_CONTRACT ASM_DISKGROUP n_rows', v_num, 2 * n_snaps);
        chk_int('CAPV_CONTRACT ASM_DISKGROUP n_con_dbid (host level)', v_num2, 1);
        -- 121 days x 2 snapshots, minus the restart day's missing 06:00.
        SELECT n_rows, max_snap_id, CAST(max_end_time AS DATE) INTO v_num, v_num2, v_ts
          FROM capv_contract WHERE source_name = 'SNAPSHOT';
        chk_int('CAPV_CONTRACT SNAPSHOT n_rows', v_num, n_snaps);
        chk_int('CAPV_CONTRACT SNAPSHOT max_snap_id', v_num2, 2001 + 2 * (d_last - d_base));
        chk_true('CAPV_CONTRACT SNAPSHOT max_end_time = last day 18:00',
                 v_ts = d_last + 18/24);
        -- OSSTAT: 4 names on every snapshot but the two of the gap day.
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'OSSTAT';
        chk_int('CAPV_CONTRACT OSSTAT n_rows', v_num, 4 * (n_snaps - 2));
        chk_int('CAPV_CONTRACT OSSTAT n_con_dbid (host level)', v_num2, 1);
        -- TIME_MODEL: 3 names, root on the OSSTAT snapshots, FIXPDB1 and
        -- FIXPDB2 on all.
        SELECT n_rows, n_con_dbid INTO v_num, v_num2
          FROM capv_contract WHERE source_name = 'TIME_MODEL';
        chk_int('CAPV_CONTRACT TIME_MODEL n_rows', v_num, 3 * (n_snaps - 2) + 2 * 3 * n_snaps);
        chk_int('CAPV_CONTRACT TIME_MODEL n_con_dbid (root + FIXPDB1 + FIXPDB2)', v_num2, 3);
    EXCEPTION
        WHEN OTHERS THEN
            fail('seam/daily contract block raised ' || SQLERRM);
    END;

    BEGIN
        DBMS_OUTPUT.PUT_LINE('=== CAPR point feeds (grafana/API.md, elk/) ===');
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'TBSPC';
        SELECT COUNT(*) INTO v_num FROM capd_tbspc_daily;
        chk_int('CAPR_SERIES_POINTS TBSPC rows = CAPD_TBSPC_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'SERIES';
        SELECT COUNT(*) INTO v_num FROM capd_series_daily;
        chk_int('CAPR_SERIES_POINTS SERIES rows = CAPD_SERIES_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'CPU' AND series = 'BUSY_PCT';
        SELECT COUNT(*) INTO v_num FROM capd_cpu_daily WHERE busy_pct IS NOT NULL;
        chk_int('CAPR_SERIES_POINTS BUSY_PCT rows = CAPD_CPU_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'CPU' AND series = 'DB_CPU_PCT';
        SELECT COUNT(*) INTO v_num FROM capd_dbtime_daily WHERE db_cpu_pct IS NOT NULL;
        chk_int('CAPR_SERIES_POINTS DB_CPU_PCT rows = CAPD_DBTIME_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n   FROM capr_series_points WHERE kind = 'TBSPC' AND anomaly = 1;
        SELECT COUNT(*) INTO v_num FROM capa_anom_day WHERE kind = 'TBSPC' AND anomaly = 1;
        chk_int('CAPR_SERIES_POINTS anomaly=1 on every TBSPC day any day mode flagged', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_series_points
          WHERE kind = 'CPU' AND series NOT IN ('BUSY_PCT', 'DB_CPU_PCT') AND anomaly IS NOT NULL;
        chk_int('CPU anomaly is scored on BUSY_PCT and DB_CPU_PCT only', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM capr_fit;
        SELECT (SELECT COUNT(*) FROM capf_tbspc_forecast) + (SELECT COUNT(*) FROM capf_cpu_trend)
               + (SELECT COUNT(*) FROM capf_series_forecast) INTO v_num FROM dual;
        chk_int('CAPR_FIT one row per fitted series', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_fit f JOIN capr_series r
            ON r.dbid = f.dbid AND r.con_dbid = f.con_dbid AND r.series = f.series
          WHERE f.kind = 'SERIES' AND f.sev <> NVL(UPPER(r.sev), 'OK');
        chk_int('CAPR_FIT SERIES sev matches CAPR_SERIES', v_n, 0);

        SELECT COUNT(*) INTO v_n FROM capr_forecast_points p JOIN capf_tbspc_forecast t
            ON t.dbid = p.dbid AND t.con_dbid = p.con_dbid AND t.tablespace_name = p.series
          WHERE p.kind = 'TBSPC' AND p.method = 'REGR' AND p.ts <> t.last_day + p.horizon_days;
        chk_int('CAPR_FORECAST_POINTS ts = last_day + horizon', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_forecast_points
          WHERE method = 'REGR' AND horizon_days = 0 AND quality = 'INSUFFICIENT_HISTORY';
        chk_int('CAPR_FORECAST_POINTS skips INSUFFICIENT_HISTORY', v_n, 0);

        SELECT COUNT(*) INTO v_n   FROM capr_anomalies WHERE anomaly_kind = 'TBSPC_GROWTH';
        SELECT COUNT(*) INTO v_num FROM capa_anom WHERE kind = 'TBSPC' AND anomaly_flag IS NOT NULL;
        chk_int('CAPR_ANOMALIES one TBSPC_GROWTH row per flagged (day, mode)', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capr_anomalies a JOIN capa_cpu_shift s
            ON s.dbid = a.dbid AND s.con_dbid = a.con_dbid AND s.metric = a.series
          WHERE a.anomaly_kind = 'CPU_SHIFT'
            AND a.ts = s.last_day - s.recent_days + 1 AND a.obs_day = s.last_day
            AND a.sev = 'WARN' AND a.db = 'FIXCDB/FIXPDB1';
        chk_int('CPU_SHIFT dated at the start of its recent window, obs_day = last_day', v_n, 1);
        SELECT pct_vs_expected, pct_vs_avg INTO v_num, v_num2
          FROM capr_anomalies
          WHERE anomaly_kind = 'TBSPC_GROWTH' AND series = 'FIX_SPIKE' AND obs_day = d_spike
            AND baseline_mode = 'TRAILING';
        chk_close('CAPR_ANOMALIES SPIKE pct_vs_expected', v_num,  100 * 2147483648 / meta_n('SPIKE_RATE'), 0.000001);
        chk_close('CAPR_ANOMALIES SPIKE pct_vs_avg',      v_num2, 100 * 2147483648 / meta_n('SPIKE_RATE'), 0.000001);
        SELECT a.pct_vs_expected, 100 * s.shift_pct / s.base_med INTO v_num, v_num2
          FROM capr_anomalies a JOIN capa_cpu_shift s
            ON s.dbid = a.dbid AND s.con_dbid = a.con_dbid AND s.metric = a.series
          WHERE a.anomaly_kind = 'CPU_SHIFT';
        chk_close('CAPR_ANOMALIES CPU_SHIFT pct_vs_expected = 100*shift_pct/base_med', v_num, v_num2, 0.000001);
    EXCEPTION
        WHEN OTHERS THEN
            fail('CAPR point-feed block raised ' || SQLERRM);
    END;

    DECLARE
        d_base  DATE   := meta_d('BASE_DAY');
        d_last  DATE   := meta_d('LAST_DAY');
        d_inv   DATE   := meta_d('INVERTED_WED');
        d_gnext DATE   := meta_d('CPUGAP_NEXT');
        d_purge DATE   := meta_d('PURGE_DAY');
        n_pdb   NUMBER := meta_n('PDB_CON_DBID');
        n_pdb2  NUMBER := meta_n('PDB2_CON_DBID');
        n_k     NUMBER;
        v_old   NUMBER;
        v_flag  VARCHAR2(5);
        v_gflag VARCHAR2(1);
        v_mode  VARCHAR2(12);
    BEGIN
        SELECT mad_k INTO n_k FROM cap_cfg;

        DBMS_OUTPUT.PUT_LINE('=== M15 CAPD_CPU_HOURLY (END-hour buckets) ===');
        SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT';
        SELECT SUM(n_intervals) INTO v_num FROM capd_cpu_daily
          WHERE dbid = v_dbid AND con_dbid = v_dbid;
        chk_int('root BUSY_PCT hourly rows = SUM(n_intervals) of CAPD_CPU_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT' AND gap_flag = 'Y';
        chk_int('root BUSY_PCT hourly gap rows', v_n, 1);
        SELECT gap_flag, ivl_hours, value INTO v_gflag, v_num, v_num2 FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT' AND hour_ts = d_gnext + 6/24;
        chk_str  ('post-gap Monday 06:00 bucket gap_flag', v_gflag, 'Y');
        chk_close('post-gap Monday 06:00 bucket ivl_hours', v_num, meta_n('CPUGAP_HOURS'), 0.000001);
        chk_close('post-gap Monday 06:00 bucket value (three half-days 10/30/20)', v_num2, 20, 0.000001);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT';
        SELECT SUM(n_intervals) INTO v_num FROM capd_dbtime_daily
          WHERE dbid = v_dbid AND con_dbid = n_pdb;
        chk_int('PDB DB_CPU_PCT hourly rows = SUM(n_intervals) of CAPD_DBTIME_DAILY', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'BUSY_PCT';
        chk_int('PDB has no hourly BUSY_PCT (OSSTAT is CDB-level)', v_n, 0);
        SELECT value INTO v_num FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT' AND hour_ts = d_probe + 6/24;
        chk_close('probe 06:00 BUSY_PCT (night interval)', v_num, 20, 0.000001);
        SELECT value, day_dt INTO v_num, d_tstart FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'BUSY_PCT' AND hour_ts = d_probe + 18/24;
        chk_close('probe 18:00 BUSY_PCT (day interval)', v_num, 60, 0.000001);
        chk_true ('probe 18:00 bucket day_dt = probe day', d_tstart = d_probe);
        SELECT value INTO v_num FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'DB_CPU_PCT' AND hour_ts = d_probe + 6/24;
        chk_close('probe 06:00 root DB_CPU_PCT = 100*100/(NUM_CPUS*43200)', v_num,
                  100 * 100 / (meta_n('NUM_CPUS') * 43200), 0.000001);
        SELECT value INTO v_num FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND metric = 'DB_CPU_PCT' AND hour_ts = d_probe + 18/24;
        chk_close('probe 18:00 root DB_CPU_PCT', v_num, meta_n('DBCPU_PROBE_PEAK_PCT'), 0.000001);
        SELECT MIN(value), MAX(value) INTO v_num, v_num2 FROM capd_cpu_hourly
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND metric = 'DB_CPU_PCT'
            AND hour_ts IN (d_probe + 6/24, d_probe + 18/24);
        chk_close('probe PDB DB_CPU_PCT 06:00 = pdb_pct(probe)', v_num,  meta_n('PDB_PROBE_PCT'), 0.000001);
        chk_close('probe PDB DB_CPU_PCT 18:00 = pdb_pct(probe)', v_num2, meta_n('PDB_PROBE_PCT'), 0.000001);

        DBMS_OUTPUT.PUT_LINE('=== M15 CAPA_ANOM structure ===');
        SELECT COUNT(*) INTO v_n FROM capa_anom;
        SELECT 2 * COUNT(CASE WHEN grain = 'DAY' THEN 1 END) + COUNT(CASE WHEN grain = 'HOUR' THEN 1 END)
          INTO v_num FROM capa_obs;
        chk_int('CAPA_ANOM rows = 2 x DAY obs + HOUR obs', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT 1 FROM capa_anom
            GROUP  BY dbid, con_dbid, kind, series, baseline_mode, ts HAVING COUNT(*) > 1);
        chk_int('CAPA_ANOM key (dbid, con_dbid, kind, series, baseline_mode, ts) unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capa_anom_day;
        SELECT COUNT(*) INTO v_num FROM capa_obs WHERE grain = 'DAY';
        chk_int('CAPA_ANOM_DAY one row per DAY observation', v_n, v_num);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE (grain = 'HOUR' AND baseline_mode <> 'HOUR_OF_WEEK')
             OR (grain = 'DAY'  AND baseline_mode = 'HOUR_OF_WEEK')
             OR (kind <> 'CPU'  AND grain = 'HOUR');
        chk_int('modes match grain (HOUR_OF_WEEK = CPU hour rows only)', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE anomaly_flag IS NOT NULL
            AND (ABS(robust_z) <= n_k OR gap_flag = 'Y' OR is_complete = 'N' OR n_hist < min_hist);
        chk_int('flag => |z| > mad_k, no gap, complete, n_hist >= min_hist', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE anomaly_flag IS NULL
            AND ABS(robust_z) > n_k AND gap_flag = 'N' AND is_complete = 'Y' AND n_hist >= min_hist;
        chk_int('|z| > mad_k, no gap, complete, n_hist >= min_hist => flag', v_n, 0);
        -- The partial day (and the first day) read low on a part-day: scored
        -- as an anomaly they would be instrumentation, not workload.
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE is_complete = 'N' AND anomaly_flag IS NOT NULL;
        chk_int('is_complete = N rows never flag', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT doc_key FROM capr_series_points GROUP BY doc_key HAVING COUNT(*) > 1);
        chk_int('CAPR_SERIES_POINTS doc_key unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT doc_key FROM capr_hourly_points GROUP BY doc_key HAVING COUNT(*) > 1);
        chk_int('CAPR_HOURLY_POINTS doc_key unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT doc_key FROM capr_anomalies GROUP BY doc_key HAVING COUNT(*) > 1);
        chk_int('CAPR_ANOMALIES doc_key unique', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM (
            SELECT alert_key FROM capr_alerts GROUP BY alert_key HAVING COUNT(*) > 1);
        chk_int('CAPR_ALERTS alert_key unique', v_n, 0);
        SELECT COUNT(*) INTO v_n   FROM capr_hourly_points;
        SELECT COUNT(*) INTO v_num FROM capd_cpu_hourly;
        chk_int('CAPR_HOURLY_POINTS rows = CAPD_CPU_HOURLY', v_n, v_num);

        DBMS_OUTPUT.PUT_LINE('=== M15 root BUSY_PCT across the three modes ===');
        chk_int('SAME_DOW HIGH count', anom_n('CPU', 'BUSY_PCT', 'SAME_DOW', 'HIGH', v_dbid), 1);
        chk_int('SAME_DOW LOW count',  anom_n('CPU', 'BUSY_PCT', 'SAME_DOW', 'LOW',  v_dbid), 0);
        chk_int('TRAILING HIGH count', anom_n('CPU', 'BUSY_PCT', 'TRAILING', 'HIGH', v_dbid), 1);
        chk_str('TRAILING flags the injected Tuesday', anom_flag('CPU', 'BUSY_PCT', 'TRAILING', d_inj, v_dbid), 'HIGH');
        -- A weekend day reads 20 against a weekday-dominated 28-day median of
        -- 40 (MAD 0, floored threshold 9), so TRAILING flags EVERY complete,
        -- non-gap weekend day that has trailing_min_hist such days of history
        -- -- the reason CPU alerts default to SAME_DOW.
        SELECT COUNT(*) INTO v_num
          FROM capd_cpu_daily c CROSS JOIN cap_cfg cfg
          WHERE c.dbid = v_dbid AND c.con_dbid = v_dbid AND c.gap_flag = 'N' AND c.is_complete = 'Y'
            AND MOD(c.day_dt - DATE '2020-01-06', 7) >= 5
            AND (SELECT COUNT(*) FROM capd_cpu_daily h
                  WHERE h.dbid = c.dbid AND h.con_dbid = c.con_dbid
                    AND h.gap_flag = 'N' AND h.is_complete = 'Y'
                    AND h.day_dt BETWEEN c.day_dt - cfg.mad_window_days AND c.day_dt - 1)
                >= cfg.trailing_min_hist;
        chk_int('TRAILING LOW = every weekend day with enough history',
                anom_n('CPU', 'BUSY_PCT', 'TRAILING', 'LOW', v_dbid), v_num);
        chk_int('HOUR_OF_WEEK HIGH count', anom_n('CPU', 'BUSY_PCT', 'HOUR_OF_WEEK', 'HIGH', v_dbid), 2);
        chk_int('HOUR_OF_WEEK LOW count',  anom_n('CPU', 'BUSY_PCT', 'HOUR_OF_WEEK', 'LOW',  v_dbid), 1);
        SELECT anomaly_flag, robust_z, threshold INTO v_flag, v_num, v_num2 FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_inj + 6/24;
        chk_str  ('HOW injected Tuesday 06:00 (70 vs 20)', v_flag, 'HIGH');
        chk_close('HOW injected Tuesday 06:00 z = 50/5', v_num, 10, 0.000001);
        chk_close('HOW threshold = mad_k x cpu_min_mad_pct_hour', v_num2, 15, 0.000001);
        SELECT anomaly_flag, dev, threshold INTO v_flag, v_num, v_num2 FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_inj + 18/24;
        chk_true ('HOW injected Tuesday 18:00 not flagged (70 vs 60)', v_flag IS NULL);
        chk_true ('HOW injected Tuesday 18:00 dev 10 < threshold 15 (got ' || v_num || ' / ' || v_num2 || ')',
                  ABS(v_num - 10) < 1e-9 AND ABS(v_num2 - 15) < 1e-9);
        SELECT anomaly_flag, robust_z INTO v_flag, v_num FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_inv + 6/24;
        chk_str  ('HOW inverted Wednesday 06:00 (40 vs 20)', v_flag, 'HIGH');
        chk_close('HOW inverted Wednesday 06:00 z = 20/5', v_num, 4, 0.000001);
        chk_str  ('HOW inverted Wednesday 18:00 (40 vs 60)',
                  anom_flag('CPU', 'BUSY_PCT', 'HOUR_OF_WEEK', d_inv + 18/24, v_dbid), 'LOW');
        chk_true ('inverted Wednesday invisible to TRAILING (daily avg 40)',
                  anom_flag('CPU', 'BUSY_PCT', 'TRAILING', d_inv, v_dbid) IS NULL);
        chk_true ('inverted Wednesday invisible to SAME_DOW (daily avg 40)',
                  anom_flag('CPU', 'BUSY_PCT', 'SAME_DOW', d_inv, v_dbid) IS NULL);
        SELECT anomaly_flag, gap_flag INTO v_flag, v_gflag FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_gnext + 6/24;
        chk_true ('HOW post-gap Monday 06:00 is a gap and unflagged', v_gflag = 'Y' AND v_flag IS NULL);
        SELECT n_hist INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT'
            AND baseline_mode = 'HOUR_OF_WEEK' AND ts = d_gnext + 7 + 6/24;
        chk_true ('HOW gap hour excluded from next Monday 06:00 baseline (n_hist '
                  || v_n || ' < 8)', v_n < 8);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND series = 'DB_CPU_PCT' AND anomaly_flag IS NOT NULL;
        chk_int('root DB_CPU_PCT never flags (values far under the 9 / 15 floors)', v_n, 0);

        DBMS_OUTPUT.PUT_LINE('=== M15 FIXPDB1 DB_CPU_PCT step days ===');
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND series = 'DB_CPU_PCT'
            AND baseline_mode = 'SAME_DOW' AND anomaly_flag = 'HIGH' AND ts >= d_last - 6;
        chk_int('SAME_DOW HIGH exactly on the last 7 (step) days', v_n, 7);
        SELECT sigma_floored, threshold, robust_z INTO v_gflag, v_num, v_num2 FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND kind = 'CPU' AND series = 'DB_CPU_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
        chk_str  ('SAME_DOW step day sigma_floored (identical priors, MAD 0)', v_gflag, 'Y');
        chk_close('SAME_DOW step day threshold = mad_k x cpu_min_mad_pct', v_num, 9, 0.000001);
        chk_close('SAME_DOW step day z = 18/3', v_num2, 6, 0.000001);
        chk_int('HOUR_OF_WEEK HIGH = both hours of the 7 step days',
                anom_n('CPU', 'DB_CPU_PCT', 'HOUR_OF_WEEK', 'HIGH', n_pdb), 14);
        -- TRAILING mixes the sawtooth into its window (sigma 5.93 -> 7.41), so
        -- only the step days whose deviation clears 3 sigma flag: index 115
        -- (58 vs 40, thr 17.79), 116 (60 vs 41) and 118 (64 vs 41, thr 22.24).
        SELECT COUNT(*), COUNT(CASE WHEN ts - d_base IN (115, 116, 118) THEN 1 END)
          INTO v_n, v_num FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb AND series = 'DB_CPU_PCT'
            AND baseline_mode = 'TRAILING' AND anomaly_flag = 'HIGH';
        chk_int('TRAILING HIGH count', v_n, 3);
        chk_int('TRAILING HIGH on day indexes 115, 116, 118', v_num, 3);

        DBMS_OUTPUT.PUT_LINE('=== M15 FIXPDB2 DB_CPU_PCT (weekday 60 / weekend 20 + 1/12 pt a day) ===');
        -- Weekly seasonality with a slow ramp: TRAILING (all weekdays mixed)
        -- reads every weekend as LOW, exactly like root BUSY_PCT; the weekly
        -- modes compare a slot with itself 1..8 weeks back, so each sees only
        -- the ramp, 7/12 point a week, far under the 9 / 15 point floors.
        SELECT COUNT(*) INTO v_num
          FROM capd_dbtime_daily c CROSS JOIN cap_cfg cfg
          WHERE c.dbid = v_dbid AND c.con_dbid = n_pdb2 AND c.gap_flag = 'N' AND c.is_complete = 'Y'
            AND MOD(c.day_dt - DATE '2020-01-06', 7) >= 5
            AND (SELECT COUNT(*) FROM capd_dbtime_daily h
                  WHERE h.dbid = c.dbid AND h.con_dbid = c.con_dbid
                    AND h.gap_flag = 'N' AND h.is_complete = 'Y'
                    AND h.day_dt BETWEEN c.day_dt - cfg.mad_window_days AND c.day_dt - 1)
                >= cfg.trailing_min_hist;
        chk_int('PDB2 TRAILING LOW = every weekend day with enough history',
                anom_n('CPU', 'DB_CPU_PCT', 'TRAILING', 'LOW', n_pdb2), v_num);
        chk_true('PDB2 TRAILING LOW count is the weekend set (' || v_num || ' > 20)', v_num > 20);
        chk_int('PDB2 TRAILING HIGH',     anom_n('CPU', 'DB_CPU_PCT', 'TRAILING',     'HIGH', n_pdb2), 0);
        chk_int('PDB2 SAME_DOW flags',    anom_n('CPU', 'DB_CPU_PCT', 'SAME_DOW',     'ANY',  n_pdb2), 0);
        chk_int('PDB2 HOUR_OF_WEEK flags', anom_n('CPU', 'DB_CPU_PCT', 'HOUR_OF_WEEK', 'ANY', n_pdb2), 0);
        -- Last day: its 8 same-weekday priors sit 7k/12 points lower (k = 1..8),
        -- so the median is value - (7/12) * 4.5 and the MAD sigma
        -- 1.4826 * 7/12 * 1.5 = 1.30 is floored to cpu_min_mad_pct.
        SELECT dev, n_hist, sigma_floored, threshold INTO v_num, v_n, v_gflag, v_num2 FROM capa_anom
          WHERE dbid = v_dbid AND con_dbid = n_pdb2 AND kind = 'CPU' AND series = 'DB_CPU_PCT'
            AND baseline_mode = 'SAME_DOW' AND ts = d_last;
        chk_close('PDB2 last-day SAME_DOW dev = (7/12) x 4.5', v_num, 7 / 12 * 4.5, 0.000001);
        chk_int  ('PDB2 last-day SAME_DOW n_hist', v_n, 8);
        chk_str  ('PDB2 last-day SAME_DOW sigma_floored', v_gflag, 'Y');
        chk_close('PDB2 last-day SAME_DOW threshold', v_num2, 9, 0.000001);

        DBMS_OUTPUT.PUT_LINE('=== M15 tablespaces and M11 series under SAME_DOW ===');
        chk_str('SPIKE SAME_DOW HIGH on the spike day', anom_flag('TBSPC', 'FIX_SPIKE', 'SAME_DOW', d_spike, v_dbid), 'HIGH');
        chk_str('PURGE SAME_DOW LOW on the purge day', anom_flag('TBSPC', 'FIX_PURGE', 'SAME_DOW', d_purge, v_dbid), 'LOW');
        -- FIX_CYCLIC / FIX_CYCLIC_UP: every retention cliff (CYC0_DAYS apart,
        -- the last on CYC0_LAST_CLIFF) is a -72 GiB day against +2.5 GiB/day
        -- priors, so both modes flag it LOW; the rising days never flag. The
        -- first cliff (day 5) has too little history for either mode.
        FOR t IN (SELECT 'FIX_CYCLIC' AS ts_name FROM dual UNION ALL SELECT 'FIX_CYCLIC_UP' FROM dual) LOOP
            FOR m IN (SELECT 'TRAILING' AS md FROM dual UNION ALL SELECT 'SAME_DOW' FROM dual) LOOP
                SELECT COUNT(*),
                       COUNT(CASE WHEN anomaly_flag = 'LOW'
                                   AND MOD(meta_last_cliff - (ts - d_base), meta_cyc_days) = 0 THEN 1 END)
                  INTO v_n, v_num
                  FROM capa_anom
                       CROSS JOIN (SELECT MAX(CASE WHEN mkey = 'CYC0_LAST_CLIFF' THEN nval END) AS meta_last_cliff,
                                          MAX(CASE WHEN mkey = 'CYC0_DAYS'       THEN nval END) AS meta_cyc_days
                                   FROM   cap_fixture_meta)
                  WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'TBSPC'
                    AND series = t.ts_name AND baseline_mode = m.md AND anomaly_flag IS NOT NULL;
                chk_int(t.ts_name || ' ' || m.md || ' flags', v_n, meta_n('CYC0_N'));
                chk_int(t.ts_name || ' ' || m.md || ' LOW on the retention cliffs', v_num, meta_n('CYC0_N'));
            END LOOP;
        END LOOP;
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE kind = 'TBSPC' AND baseline_mode = 'SAME_DOW' AND anomaly_flag IS NOT NULL
            AND series NOT IN ('FIX_CYCLIC', 'FIX_CYCLIC_UP');
        chk_int('other TBSPC SAME_DOW flags: the spike and the purge only', v_n, 2);
        SELECT COUNT(*) INTO v_n FROM capa_anom
          WHERE kind = 'SERIES' AND series IN ('SESSIONS', 'PROCESSES', 'REDO_GB_DAY')
            AND anomaly_flag IS NOT NULL;
        chk_int('SESSIONS / PROCESSES / REDO_GB_DAY never flag', v_n, 0);
        FOR m IN (SELECT 'TRAILING' AS md FROM dual UNION ALL SELECT 'SAME_DOW' FROM dual) LOOP
            chk_str('DB_SIZE_GB ' || m.md || ' HIGH on the spike day',
                    anom_flag('SERIES', 'DB_SIZE_GB', m.md, d_spike, v_dbid), 'HIGH');
            chk_str('DB_SIZE_GB ' || m.md || ' LOW on the purge day',
                    anom_flag('SERIES', 'DB_SIZE_GB', m.md, d_purge, v_dbid), 'LOW');
            chk_int('DB_SIZE_GB ' || m.md || ' flags nothing else (spike, purge, the CYC0_N cliffs)',
                    anom_n('SERIES', 'DB_SIZE_GB', m.md, 'ANY', v_dbid), 2 + meta_n('CYC0_N'));
        END LOOP;
        -- The tablespace SET changes three times: FIX_DROPPED leaves the day
        -- after its last row, FIX_GAP leaves on day 100 and rejoins on 103.
        SELECT COUNT(*), COUNT(CASE WHEN day_dt - d_base IN (meta_n_dropped + 1, 100, 103) THEN 1 END)
          INTO v_n, v_num
          FROM capd_series_daily
               CROSS JOIN (SELECT nval AS meta_n_dropped FROM cap_fixture_meta WHERE mkey = 'DROPPED_LAST_DAY')
          WHERE dbid = v_dbid AND series = 'DB_SIZE_GB' AND gap_flag = 'Y';
        chk_int('DB_SIZE_GB gap_flag days (tablespace set changed)', v_n, 3);
        chk_int('DB_SIZE_GB gap_flag on DROPPED_LAST_DAY + 1, 100 and 103', v_num, 3);
        SELECT COUNT(*) INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND gap_flag = 'Y';
        chk_int('REDO_GB_DAY gap_flag never Y (12 h intervals)', v_n, 0);
        SELECT day_gap INTO v_n FROM capd_series_daily
          WHERE dbid = v_dbid AND series = 'REDO_GB_DAY' AND day_dt = d_base + 61;
        chk_int('REDO_GB_DAY day_gap after the restart day', v_n, 2);

        DBMS_OUTPUT.PUT_LINE('=== M15 point feeds ===');
        SELECT anomaly_flag, how_hours_flagged, anomaly INTO v_flag, v_n, v_num
          FROM capr_series_points
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'CPU' AND series = 'BUSY_PCT' AND ts = d_inv;
        chk_true('inverted Wednesday point: headline flag NULL', v_flag IS NULL);
        chk_int ('inverted Wednesday point: how_hours_flagged', v_n, 2);
        chk_int ('inverted Wednesday point: anomaly', v_num, 1);
        SELECT anomaly_flag, anomaly_modes INTO v_flag, v_msg
          FROM capr_series_points
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND kind = 'TBSPC' AND series = 'FIX_SPIKE' AND ts = d_spike;
        chk_str('SPIKE point headline flag (TRAILING)', v_flag, 'HIGH');
        chk_str('SPIKE point anomaly_modes', v_msg, 'TRAILING,SAME_DOW');
        SELECT how_flag, how_z INTO v_flag, v_num FROM capr_hourly_points
          WHERE dbid = v_dbid AND con_dbid = v_dbid AND series = 'BUSY_PCT' AND ts = d_inj + 6/24;
        chk_str  ('CAPR_HOURLY_POINTS injected Tuesday 06:00 how_flag', v_flag, 'HIGH');
        chk_close('CAPR_HOURLY_POINTS injected Tuesday 06:00 how_z', v_num, 10, 0.000001);

        DBMS_OUTPUT.PUT_LINE('=== M15 alerts with the shipped alert_modes ===');
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'CPU_ANOM';
        chk_int('CPU_ANOM alerts', v_n, 1);
        SELECT baseline_mode INTO v_mode FROM capr_alerts WHERE kind = 'CPU_ANOM';
        chk_str('CPU_ANOM baseline_mode', v_mode, 'SAME_DOW');
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'DBCPU_ANOM' AND severity = 'WARN' AND baseline_mode = 'SAME_DOW'
            AND db_pdb = 'FIXCDB/FIXPDB1' AND series_key = 'DB_CPU_PCT';
        chk_int('DBCPU_ANOM WARN alerts (the 7 FIXPDB1 step days)', v_n, 7);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'DBCPU_ANOM';
        chk_int('DBCPU_ANOM alerts in total', v_n, 7);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'TBSPC_ANOM';
        chk_int('TBSPC_ANOM alerts (the spike; the purge predates the window)', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE kind = 'SERIES_ANOM' AND series_key = 'DB_SIZE_GB' AND day_dt = d_spike
            AND severity = 'WARN' AND baseline_mode = 'TRAILING';
        chk_int('SERIES_ANOM WARN for DB_SIZE_GB on the spike day', v_n, 1);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'SERIES_ANOM';
        chk_int('SERIES_ANOM alerts in total', v_n, 1);
        SELECT value, threshold INTO v_num, v_num2 FROM capr_alerts
          WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE';
        chk_close('TBSPC_ANOM value = the scored rate (bytes/day)', v_num, meta_n('SPIKE_RATE') + 2147483648, 0.000001);
        chk_close('TBSPC_ANOM threshold = the bound crossed (median + floor)', v_num2,
                  meta_n('SPIKE_RATE') + 104857600, 0.000001);
        SELECT COUNT(*) INTO v_n FROM capr_alerts
          WHERE (kind IN ('TBSPC_ANOM', 'CPU_ANOM', 'DBCPU_ANOM', 'SERIES_ANOM') AND baseline_mode IS NULL)
             OR (kind NOT IN ('TBSPC_ANOM', 'CPU_ANOM', 'DBCPU_ANOM', 'SERIES_ANOM') AND baseline_mode IS NOT NULL);
        chk_int('baseline_mode set on anomaly kinds only', v_n, 0);
        SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'CPU_SHIFT';
        chk_int('CPU_SHIFT alerts unchanged', v_n, 1);

        DBMS_OUTPUT.PUT_LINE('=== M15 knob flips ===');
        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'alert_modes_cpu';
        knob('alert_modes_cpu', 6);
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'CPU_ANOM';
            chk_int('alert_modes_cpu=6: CPU_ANOM (SAME_DOW + HOW Tue + HOW Wed)', v_n, 3);
            SELECT severity, value, threshold, message INTO v_str, v_num, v_num2, v_msg
              FROM capr_alerts
              WHERE kind = 'CPU_ANOM' AND baseline_mode = 'HOUR_OF_WEEK' AND day_dt = d_inv;
            chk_str  ('alert_modes_cpu=6: HOW inverted Wednesday severity', v_str, 'WARN');
            chk_close('alert_modes_cpu=6: HOW inverted Wednesday carries 06:00 (value 40)', v_num, 40, 0.000001);
            chk_close('alert_modes_cpu=6: HOW inverted Wednesday bound 20 + 15', v_num2, 35, 0.000001);
            chk_true ('alert_modes_cpu=6: message says "2 hours flagged that day" (got: ' || v_msg || ')',
                      INSTR(v_msg, '; 2 hours flagged that day') > 0 AND INSTR(v_msg, 'for Wed 06:00') > 0);
            SELECT value, threshold INTO v_num, v_num2 FROM capr_alerts
              WHERE kind = 'CPU_ANOM' AND baseline_mode = 'HOUR_OF_WEEK' AND day_dt = d_inj;
            chk_true('alert_modes_cpu=6: HOW injected Tuesday carries 06:00 (70 vs bound 35, got '
                     || v_num || ' / ' || v_num2 || ')',
                     ABS(v_num - 70) < 1e-9 AND ABS(v_num2 - 35) < 1e-9);
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind = 'DBCPU_ANOM';
            chk_int('alert_modes_cpu=6: DBCPU_ANOM (7 SAME_DOW + 7 HOW days)', v_n, 14);
            SELECT COUNT(*) INTO v_n FROM (
                SELECT alert_key FROM capr_alerts GROUP BY alert_key HAVING COUNT(*) > 1);
            chk_int('alert_modes_cpu=6: alert_key still unique', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN knob('alert_modes_cpu', v_old); COMMIT; RAISE;
        END;
        knob('alert_modes_cpu', 0);
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capr_alerts WHERE kind IN ('CPU_ANOM', 'DBCPU_ANOM');
            chk_int('alert_modes_cpu=0: no CPU_ANOM / DBCPU_ANOM', v_n, 0);
            SELECT alerting, sev INTO v_gflag, v_str FROM capr_anomalies
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND anomaly_kind = 'CPU_BUSY'
                AND baseline_mode = 'SAME_DOW' AND ts = d_inj;
            chk_true('alert_modes_cpu=0: CAPR_ANOMALIES still lists it, alerting N, sev INFO',
                     v_gflag = 'N' AND v_str = 'INFO');
        EXCEPTION
            WHEN OTHERS THEN knob('alert_modes_cpu', v_old); COMMIT; RAISE;
        END;
        knob('alert_modes_cpu', v_old);
        COMMIT;

        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'alert_modes_tbspc';
        knob('alert_modes_tbspc', 3);
        BEGIN
            SELECT COUNT(*), COUNT(DISTINCT alert_key) INTO v_n, v_num FROM capr_alerts
              WHERE kind = 'TBSPC_ANOM' AND series_key = 'FIX_SPIKE' AND day_dt = d_spike;
            chk_int('alert_modes_tbspc=3: SPIKE TBSPC_ANOM rows (TRAILING + SAME_DOW)', v_n, 2);
            chk_int('alert_modes_tbspc=3: distinct alert_key', v_num, 2);
        EXCEPTION
            WHEN OTHERS THEN knob('alert_modes_tbspc', v_old); COMMIT; RAISE;
        END;
        knob('alert_modes_tbspc', v_old);
        COMMIT;

        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'weekly_min_hist';
        SELECT COUNT(*) INTO v_num FROM capa_anom
          WHERE baseline_mode = 'TRAILING' AND anomaly_flag IS NOT NULL;
        knob('weekly_min_hist', 9);
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capa_anom
              WHERE baseline_mode IN ('SAME_DOW', 'HOUR_OF_WEEK') AND anomaly_flag IS NOT NULL;
            chk_int('weekly_min_hist=9 (> dow_weeks): no weekly flags', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capa_anom
              WHERE baseline_mode = 'TRAILING' AND anomaly_flag IS NOT NULL;
            chk_int('weekly_min_hist=9: TRAILING flags unchanged', v_n, v_num);
            SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'weekly_min_hist';
            chk_str('weekly_min_hist=9: CAP_CFG_CHECK', v_str, 'BAD');
        EXCEPTION
            WHEN OTHERS THEN knob('weekly_min_hist', v_old); COMMIT; RAISE;
        END;
        knob('weekly_min_hist', v_old);
        COMMIT;

        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'hour_gap_ratio';
        knob('hour_gap_ratio', 0.5);
        BEGIN
            SELECT COUNT(*) INTO v_n FROM capd_cpu_hourly WHERE gap_flag = 'N';
            chk_int('hour_gap_ratio=0.5: every 12 h bucket is an hour-grain gap', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capa_anom
              WHERE baseline_mode = 'HOUR_OF_WEEK' AND anomaly_flag IS NOT NULL;
            chk_int('hour_gap_ratio=0.5: no HOUR_OF_WEEK flags', v_n, 0);
            SELECT COUNT(*) INTO v_n FROM capd_cpu_daily
              WHERE dbid = v_dbid AND con_dbid = v_dbid AND gap_flag = 'Y';
            chk_int('hour_gap_ratio=0.5: daily gap days unchanged', v_n, 1);
        EXCEPTION
            WHEN OTHERS THEN knob('hour_gap_ratio', v_old); COMMIT; RAISE;
        END;
        knob('hour_gap_ratio', v_old);
        COMMIT;

        SELECT cfg_value INTO v_old FROM cap_config WHERE cfg_name = 'cpu_min_mad_pct_hour';
        knob('cpu_min_mad_pct_hour', 3);
        BEGIN
            chk_str('cpu_min_mad_pct_hour=3: injected Tuesday 18:00 flips HIGH (10 > 9)',
                    anom_flag('CPU', 'BUSY_PCT', 'HOUR_OF_WEEK', d_inj + 18/24, v_dbid), 'HIGH');
        EXCEPTION
            WHEN OTHERS THEN knob('cpu_min_mad_pct_hour', v_old); COMMIT; RAISE;
        END;
        knob('cpu_min_mad_pct_hour', v_old);
        COMMIT;

        SELECT COUNT(*) INTO v_n FROM cap_config WHERE cfg_name IN ('tbspc_min_hist', 'cpu_min_dow_hist');
        chk_int('retired knobs tbspc_min_hist / cpu_min_dow_hist gone', v_n, 0);
        SELECT trailing_min_hist, weekly_min_hist INTO v_num, v_num2 FROM cap_cfg;
        chk_true('CAP_CFG trailing_min_hist = 7, weekly_min_hist = 3', v_num = 7 AND v_num2 = 3);
        SELECT COUNT(*) INTO v_n FROM cap_cfg
          WHERE cpu_min_mad_pct_hour = 5 AND hour_gap_ratio = 1.5 AND series_floor_count = 10
            AND series_floor_gib = 0.5 AND alert_modes_tbspc = 1 AND alert_modes_cpu = 2
            AND alert_modes_series = 1;
        chk_int('CAP_CFG new M15 knobs at their shipped values', v_n, 1);
    EXCEPTION
        WHEN OTHERS THEN
            fail('M15 anomaly-modes block raised ' || SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('=== CAP_CFG: the one config access path ===');
    SELECT COUNT(*) INTO v_n FROM cap_cfg;
    chk_int('CAP_CFG row count', v_n, 1);
    SELECT c.train_days, k.cfg_value INTO v_num, v_num2
      FROM cap_cfg c CROSS JOIN cap_config k WHERE k.cfg_name = 'train_days';
    chk_int('CAP_CFG.train_days = CAP_CONFIG train_days', v_num, v_num2);
    SELECT c.mad_k, k.cfg_value INTO v_num, v_num2
      FROM cap_cfg c CROSS JOIN cap_config k WHERE k.cfg_name = 'mad_k';
    chk_int('CAP_CFG.mad_k = CAP_CONFIG mad_k', v_num, v_num2);
    SELECT c.slope_method, k.cfg_value INTO v_num, v_num2
      FROM cap_cfg c CROSS JOIN cap_config k WHERE k.cfg_name = 'slope_method';
    chk_int('CAP_CFG.slope_method = CAP_CONFIG slope_method', v_num, v_num2);
    SELECT COUNT(*) INTO v_n FROM cap_config k
      WHERE NOT EXISTS (SELECT 1 FROM cap_cfg_check c WHERE c.knob = k.cfg_name);
    chk_int('CAP_CONFIG keys without a CAP_CFG column', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check WHERE status <> 'OK';
    chk_int('CAP_CFG_CHECK rows not OK', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM cap_config WHERE cfg_default IS NULL;
    chk_int('CAP_CONFIG rows with no cfg_default', v_n, 0);
    SELECT cfg_value, cfg_default INTO v_num, v_num2
      FROM cap_config WHERE cfg_name = 'mad_k';
    chk_int('mad_k cfg_value (shipped)', v_num, 3);
    chk_int('mad_k cfg_default = cfg_value', v_num2, v_num);

    -- A range rule, then the documented reset (cfg_value = cfg_default).
    UPDATE cap_config SET cfg_value = 1000 WHERE cfg_name = 'recent_days';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'recent_days';
    chk_str('CAP_CFG_CHECK recent_days=1000 > train_days', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'recent_days';
    COMMIT;
    SELECT status, value INTO v_str, v_num FROM cap_cfg_check WHERE knob = 'recent_days';
    chk_str('CAP_CFG_CHECK recent_days after reset', v_str, 'OK');
    chk_int('recent_days after reset to cfg_default', v_num, 28);

    -- The new knobs' range rules.
    UPDATE cap_config SET cfg_value = 1 WHERE cfg_name = 'cyclic_min_cliffs';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'cyclic_min_cliffs';
    chk_str('CAP_CFG_CHECK cyclic_min_cliffs = 1', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = 3 WHERE cfg_name = 'slope_method';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'slope_method';
    chk_str('CAP_CFG_CHECK slope_method = 3', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = 2 WHERE cfg_name = 'cpu_quality_gate';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'cpu_quality_gate';
    chk_str('CAP_CFG_CHECK cpu_quality_gate = 2', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = 2 WHERE cfg_name = 'cpu_deseason';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'cpu_deseason';
    chk_str('CAP_CFG_CHECK cpu_deseason = 2', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default
     WHERE cfg_name IN ('cyclic_min_cliffs', 'slope_method', 'cpu_quality_gate', 'cpu_deseason');
    COMMIT;
    SELECT COUNT(*) INTO v_n FROM cap_cfg_check
      WHERE knob IN ('cyclic_min_cliffs', 'slope_method', 'cpu_quality_gate', 'cpu_deseason') AND status = 'OK';
    chk_int('new knobs OK after reset', v_n, 4);

    -- suite_version: stamped by every install, BAD when older than this release.
    SELECT suite_version INTO v_num FROM cap_cfg;
    chk_int('suite_version = 15', v_num, 15);
    UPDATE cap_config SET cfg_value = 12 WHERE cfg_name = 'suite_version';
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'suite_version';
    chk_str('CAP_CFG_CHECK suite_version=12 < 13', v_str, 'BAD');
    UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'suite_version';
    COMMIT;

    -- A deleted key is the silent failure mode: the pivot yields NULL, the
    -- SPIKE threshold goes NULL and the flag disappears without an error.
    DECLARE
        s_val  cap_config.cfg_value%TYPE;
        s_def  cap_config.cfg_default%TYPE;
        s_desc cap_config.cfg_desc%TYPE;
    BEGIN
        SELECT cfg_value, cfg_default, cfg_desc INTO s_val, s_def, s_desc
          FROM cap_config WHERE cfg_name = 'mad_k';
        DELETE FROM cap_config WHERE cfg_name = 'mad_k';
        BEGIN
            SELECT status, value INTO v_str, v_num FROM cap_cfg_check WHERE knob = 'mad_k';
            chk_str ('CAP_CFG_CHECK mad_k after DELETE', v_str, 'MISSING');
            chk_true('CAP_CFG.mad_k is NULL after DELETE', v_num IS NULL);
            SELECT COUNT(*) INTO v_n FROM capa_anom
              WHERE kind = 'TBSPC' AND series = 'FIX_SPIKE' AND anomaly_flag IS NOT NULL;
            chk_int('SPIKE flagged rows (any mode) with mad_k deleted', v_n, 0);
        EXCEPTION
            WHEN OTHERS THEN
                INSERT INTO cap_config (cfg_name, cfg_value, cfg_default, cfg_desc)
                VALUES ('mad_k', s_val, s_def, s_desc);
                COMMIT;
                RAISE;
        END;
        INSERT INTO cap_config (cfg_name, cfg_value, cfg_default, cfg_desc)
        VALUES ('mad_k', s_val, s_def, s_desc);
        COMMIT;
    END;
    SELECT status INTO v_str FROM cap_cfg_check WHERE knob = 'mad_k';
    chk_str('CAP_CFG_CHECK mad_k after re-INSERT', v_str, 'OK');
    chk_str('SPIKE HIGH on spike day after mad_k re-INSERT (TRAILING)',
            anom_flag('TBSPC', 'FIX_SPIKE', 'TRAILING', d_spike, v_dbid), 'HIGH');

    DBMS_OUTPUT.PUT_LINE('----------------------------------------');
    DBMS_OUTPUT.PUT_LINE('RESULT: ' || g_pass || ' passed, ' || g_fail || ' failed');
    IF g_fail > 0 THEN
        RAISE_APPLICATION_ERROR(-20050, 'FIXTURE TESTS FAILED: ' || g_fail || ' assertion(s)');
    END IF;
END;
/

PROMPT
PROMPT All fixture assertions passed.
