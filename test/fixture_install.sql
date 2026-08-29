--
-- test/fixture_install.sql -- deterministic CAP_FIXTURE_* data for run_test.sql.
-- =====================================================================
-- Creates and fills the CAP_FIXTURE_* tables the fixture seam (ddl/12) points
-- CAPV_* at. Everything is exact and anchored to TRUNC(SYSDATE) so the forecast
-- windows (which use SYSDATE) line up, but nothing is random -- every asserted
-- number is a closed form. A CAP_FIXTURE_META table records the expected values
-- + key dates so run_test.sql reads them instead of re-deriving (no drift).
--
-- Series (fake dbid/con_dbid 42424242 so it never collides with real AWR):
--   FIX_LINEAR   : exactly 10 MiB/day growth, 8 KiB blocks, 50 GiB maxsize.
--   FIX_SPIKE    :  5 MiB/day + a one-time +2 GiB step at day 110.
--   FIX_FLAT     : constant usage at 66.7% of allocation (quality FLAT).
--   FIX_GAP      : 60 MiB/day with a 3-day AWR gap (rate normalization).
--   FIX_NEARFULL : constant at exactly 97.0% of maxsize (FLAT quality but
--                  near-full NOW -> M7.1 ranking + TBSPC_NEARFULL alert).
--   FIX_FILLING  : 10 MiB/day against a small maxsize -> days_to_full = 20
--                  (TBSPC_FULL CRIT alert), pct 86.7% (below near-full).
--   FIX_ZIGZAG   : 10 MiB/day +-20 MiB alternating -- deterministic residuals
--                  for the M9.1 prediction-interval + M9.4 backtest closed
--                  forms (expectations computed in-loop below).
--   CPU          : two snapshots per day (06:00 = the overnight interval,
--                  18:00 = the daytime/peak interval). Weekday 20% night /
--                  60% day (daily avg 40%), weekend 10% / 30% (avg 20%), one
--                  +30pt Tuesday (70%/70%), one restart at day 60 (startup_time
--                  change + counter reset, morning snapshot missing so the
--                  whole day drops). Exercises M10.1 (p95/max/peak-window)
--                  and M10.2 (DB CPU % of cores) closed forms.
--   CONTAINER    : FIXCDB root row + one synthetic FIXPDB1 row (M7.2 labels).
--
-- Run this BEFORE @install.sql with seam_mode=fixture (the seam views need the
-- tables to exist), then run test/run_test.sql.
--
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE

-- ---- drop any prior fixtures ----
DECLARE
    TYPE nl IS TABLE OF VARCHAR2(30);
    v nl := nl('CAP_FIXTURE_SNAPSHOT','CAP_FIXTURE_TBSPC_USAGE','CAP_FIXTURE_TABLESPACE',
              'CAP_FIXTURE_DATAFILE','CAP_FIXTURE_OSSTAT','CAP_FIXTURE_TIME_MODEL',
              'CAP_FIXTURE_CONTAINER','CAP_FIXTURE_META');
BEGIN
    FOR i IN 1 .. v.COUNT LOOP
        BEGIN EXECUTE IMMEDIATE 'DROP TABLE ' || v(i) || ' PURGE';
        EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
    END LOOP;
END;
/

CREATE TABLE cap_fixture_snapshot (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    begin_interval_time TIMESTAMP, end_interval_time TIMESTAMP, startup_time TIMESTAMP);
CREATE TABLE cap_fixture_tbspc_usage (
    dbid NUMBER, con_dbid NUMBER, snap_id NUMBER, tablespace_id NUMBER,
    tablespace_size NUMBER, tablespace_maxsize NUMBER, tablespace_usedsize NUMBER);
CREATE TABLE cap_fixture_tablespace (
    dbid NUMBER, con_dbid NUMBER, tablespace_id NUMBER,
    tablespace_name VARCHAR2(30), contents VARCHAR2(30), block_size NUMBER);
CREATE TABLE cap_fixture_datafile (
    dbid NUMBER, con_dbid NUMBER, tablespace_id NUMBER, block_size NUMBER);
CREATE TABLE cap_fixture_osstat (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    stat_name VARCHAR2(64), value NUMBER);
CREATE TABLE cap_fixture_time_model (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    stat_name VARCHAR2(64), value NUMBER);
CREATE TABLE cap_fixture_container (
    dbid NUMBER, con_dbid NUMBER, db_name VARCHAR2(128), con_name VARCHAR2(128));
CREATE TABLE cap_fixture_meta (
    mkey VARCHAR2(30) PRIMARY KEY, dval DATE, nval NUMBER, sval VARCHAR2(100));

DECLARE
    c_dbid   CONSTANT NUMBER := 42424242;
    c_con    CONSTANT NUMBER := 42424242;
    c_inst   CONSTANT NUMBER := 1;
    c_nd     CONSTANT PLS_INTEGER := 120;         -- day indices 0..120 (121 snaps)
    c_bs     CONSTANT NUMBER := 8192;
    c_restart CONSTANT PLS_INTEGER := 60;
    c_spike  CONSTANT PLS_INTEGER := 110;
    c_tot_cs CONSTANT NUMBER := 4 * 86400 * 100;  -- 34,560,000 cs/day (4 CPUs)
    -- 50 GiB as a literal NUMBER: 50*1024*1024*1024 as integer-literal
    -- arithmetic overflows PLS_INTEGER (>2^31) before the NUMBER assignment.
    c_50g    CONSTANT NUMBER := 53687091200;
    v_base   DATE := TRUNC(SYSDATE) - c_nd;
    v_start1 TIMESTAMP := CAST(v_base - 5 AS TIMESTAMP);
    v_start2 TIMESTAMP := CAST(v_base + c_restart AS TIMESTAMP);
    v_max50g NUMBER := c_50g / c_bs;   -- 6,553,600 blocks
    v_start  TIMESTAMP;
    v_used   NUMBER;
    v_busy   NUMBER := 0;
    v_idle   NUMBER := 0;
    v_dbcpu  NUMBER := 0;
    v_dbtime NUMBER := 0;
    v_bg     NUMBER := 0;
    v_inj    PLS_INTEGER;
    v_probe  PLS_INTEGER;

    FUNCTION dow(p_i PLS_INTEGER) RETURN PLS_INTEGER IS       -- 0=Mon .. 6=Sun
    BEGIN RETURN MOD(TRUNC(v_base + p_i) - DATE '2020-01-06', 7); END;

    -- Busy fraction of the overnight (18:00 -> 06:00) and daytime (06:00 ->
    -- 18:00) intervals. Equal 12 h halves, so the daily time-weighted
    -- average is exactly their mean: weekday 0.40, weekend 0.20, injected 0.70.
    FUNCTION fnight(p_i PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        IF p_i = v_inj THEN RETURN 0.70;
        ELSIF dow(p_i) >= 5 THEN RETURN 0.10;
        ELSE RETURN 0.20; END IF;
    END;
    FUNCTION fday(p_i PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        IF p_i = v_inj THEN RETURN 0.70;
        ELSIF dow(p_i) >= 5 THEN RETURN 0.30;
        ELSE RETURN 0.60; END IF;
    END;

    PROCEDURE osstat(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_osstat
        VALUES (c_dbid, c_con, c_inst, p_snap, p_name, p_val);
    END;
    PROCEDURE tmodel(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_time_model
        VALUES (c_dbid, c_con, c_inst, p_snap, p_name, p_val);
    END;
BEGIN
    -- Injected Tuesday = the LATEST Tuesday (dow=1) in range, so no later
    -- same-weekday baseline is polluted by it. Probe = a plain weekday.
    v_inj := NULL;
    FOR i IN REVERSE 90 .. c_nd LOOP
        IF MOD(TRUNC(v_base + i) - DATE '2020-01-06', 7) = 1 THEN v_inj := i; EXIT; END IF;
    END LOOP;
    v_probe := NULL;
    FOR i IN REVERSE 61 .. (c_nd - 1) LOOP
        IF MOD(TRUNC(v_base + i) - DATE '2020-01-06', 7) < 5 AND i <> v_inj THEN
            v_probe := i; EXIT;
        END IF;
    END LOOP;

    -- ---- dimensions ----
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 10, 'FIX_LINEAR',   'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 11, 'FIX_SPIKE',    'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 12, 'FIX_FLAT',     'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 13, 'FIX_GAP',      'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 14, 'FIX_NEARFULL', 'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 15, 'FIX_FILLING',  'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 16, 'FIX_ZIGZAG',   'PERMANENT', c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 10, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 11, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 12, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 13, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 14, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 15, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 16, c_bs);

    -- Container naming (M7.2): the row every fixture series resolves through
    -- (con_dbid = dbid -> label is the db_name alone), plus one synthetic PDB
    -- row (con_dbid <> dbid, no facts attached) purely to assert the
    -- DBNAME/PDBNAME label branch of CAPR_CONTAINER.
    INSERT INTO cap_fixture_container VALUES (c_dbid, c_con,     'FIXCDB', 'CDB$ROOT');
    INSERT INTO cap_fixture_container VALUES (c_dbid, c_con + 1, 'FIXCDB', 'FIXPDB1');

    -- ---- per-day series ----
    -- Two snapshots a day: 2000+2i ends 06:00 (covers the night), 2001+2i
    -- ends 18:00 (covers the day = the peak window). Tablespace usage hangs
    -- off the 18:00 snapshot only (last-of-day). On the restart day the
    -- instance was down overnight, so the 06:00 snapshot does not exist and
    -- the 18:00 one carries the new startup_time + reset counters: the single
    -- interval that day spans the restart and is dropped by the guard.
    FOR i IN 0 .. c_nd LOOP
        v_start := CASE WHEN i < c_restart THEN v_start1 ELSE v_start2 END;
        IF i <> c_restart THEN
            INSERT INTO cap_fixture_snapshot
            VALUES (c_dbid, c_con, c_inst, 2000 + 2 * i,
                    CAST(v_base + i - 6/24 AS TIMESTAMP),
                    CAST(v_base + i + 6/24 AS TIMESTAMP), v_start);
        END IF;
        INSERT INTO cap_fixture_snapshot
        VALUES (c_dbid, c_con, c_inst, 2001 + 2 * i,
                CAST(v_base + i + 6/24 AS TIMESTAMP),
                CAST(v_base + i + 18/24 AS TIMESTAMP), v_start);

        -- FIX_LINEAR : 10 MiB/day = 1280 blocks/day, base 100 MiB (12800 blocks)
        v_used := 1280 * i + 12800;
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 10, v_used, v_max50g, v_used);

        -- FIX_SPIKE : 5 MiB/day = 640 blocks/day + one +2 GiB (262144 blocks) step
        v_used := 640 * i + 6400 + CASE WHEN i >= c_spike THEN 262144 ELSE 0 END;
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 11, v_used, v_max50g, v_used);

        -- FIX_FLAT : constant 400 MiB used of a 600 MiB (76800-block) allocation,
        -- no autoextend (maxsize 0 -> limit = allocated size). Kept well under
        -- the near-full floor so its 66.7% never trips a TBSPC_NEARFULL alert
        -- (only FIX_NEARFULL exercises that path).
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 12, 76800, 0, 51200);

        -- FIX_NEARFULL : constant 124160 of maxsize 128000 blocks = exactly
        -- 97.0% full, never growing (quality FLAT). Exercises M7.1: near-full
        -- NOW must surface (near-full ranking + TBSPC_NEARFULL CRIT alert)
        -- even though the fit quality would hide it from days-to-full.
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 14, 124160, 128000, 124160);

        -- FIX_FILLING : same 10 MiB/day (1280 blocks/day, base 100 MiB) growth
        -- as FIX_LINEAR but with a small 1500-MiB (192000-block) maxsize, so
        -- headroom on the last day is exactly 200 MiB -> days_to_full = 20
        -- (CRIT), while pct_used = 86.7% stays below the near-full floor.
        -- Exercises the TBSPC_FULL alert branch of CAPR_ALERTS.
        v_used := 1280 * i + 12800;
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 15, v_used, 192000, v_used);

        -- FIX_ZIGZAG : 10 MiB/day trend + alternating +-20 MiB (2560 blocks)
        -- around the line -- a deterministic "noisy" series whose OLS sums are
        -- closed forms, exercising the M9.1 prediction-interval and M9.4
        -- backtest arithmetic with NON-degenerate residuals (FIX_LINEAR's
        -- residuals are all zero, which only proves bands collapse).
        -- Deltas alternate +50 / -30 MiB: well inside the anomaly threshold
        -- (k*MAD of the alternating baseline), so it never flags.
        v_used := 12800 + 1280 * i + CASE WHEN MOD(i, 2) = 0 THEN 2560 ELSE -2560 END;
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 16, v_used, v_max50g, v_used);

        -- FIX_GAP : 60 MiB/day = 7680 blocks/day, but with a 3-day AWR gap
        -- (days 100-102 have NO usage sample). The post-gap day (103) sees a
        -- 4-day, 240 MiB jump; the per-day RATE (60 MiB) must NOT flag. Without
        -- gap normalization the 240 MiB raw delta would exceed the 100 MiB floor
        -- and false-flag. Exercises the CAPD_TBSPC_DELTA day_gap / rate fix.
        IF i NOT BETWEEN 100 AND 102 THEN
            v_used := 7680 * i + 6400;
            INSERT INTO cap_fixture_tbspc_usage
            VALUES (c_dbid, c_con, 2001 + 2 * i, 13, v_used, v_max50g, v_used);
        END IF;

        -- ---- CPU counters (cumulative centiseconds), reset at restart ----
        -- Each 12 h interval contributes half a day of CPU time (c_tot_cs/2).
        -- DB time model (cumulative microseconds) resets with the restart:
        -- db_cpu_sec = f * 500 per interval (daily sum = avg busy * 1000),
        -- db_time = f * 600 per interval, background 25 s per interval.
        IF i = c_restart THEN
            v_busy := 0; v_idle := 0; v_dbcpu := 0; v_dbtime := 0; v_bg := 0;
        ELSE
            v_busy   := v_busy   + fnight(i) * c_tot_cs / 2;
            v_idle   := v_idle   + (1 - fnight(i)) * c_tot_cs / 2;
            v_dbcpu  := v_dbcpu  + fnight(i) * 500 * 1000000;
            v_dbtime := v_dbtime + fnight(i) * 600 * 1000000;
            v_bg     := v_bg     + 25 * 1000000;
            osstat(2000 + 2 * i, 'BUSY_TIME', v_busy);
            osstat(2000 + 2 * i, 'IDLE_TIME', v_idle);
            osstat(2000 + 2 * i, 'NUM_CPUS', 4);
            osstat(2000 + 2 * i, 'NUM_CPU_CORES', 4);
            tmodel(2000 + 2 * i, 'DB CPU', v_dbcpu);
            tmodel(2000 + 2 * i, 'DB time', v_dbtime);
            tmodel(2000 + 2 * i, 'background cpu time', v_bg);
        END IF;
        v_busy   := v_busy   + fday(i) * c_tot_cs / 2;
        v_idle   := v_idle   + (1 - fday(i)) * c_tot_cs / 2;
        v_dbcpu  := v_dbcpu  + fday(i) * 500 * 1000000;
        v_dbtime := v_dbtime + fday(i) * 600 * 1000000;
        v_bg     := v_bg     + 25 * 1000000;
        osstat(2001 + 2 * i, 'BUSY_TIME', v_busy);
        osstat(2001 + 2 * i, 'IDLE_TIME', v_idle);
        osstat(2001 + 2 * i, 'NUM_CPUS', 4);
        osstat(2001 + 2 * i, 'NUM_CPU_CORES', 4);
        tmodel(2001 + 2 * i, 'DB CPU', v_dbcpu);
        tmodel(2001 + 2 * i, 'DB time', v_dbtime);
        tmodel(2001 + 2 * i, 'background cpu time', v_bg);
    END LOOP;

    -- ---- expected values / key dates for run_test.sql ----
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBID', c_dbid);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('BASE_DAY',    v_base);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('LAST_DAY',    v_base + c_nd);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('SPIKE_DAY',   v_base + c_spike);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('RESTART_DAY', v_base + c_restart);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('INJECTED_TUE', v_base + v_inj, v_inj);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('PROBE_DAY',    v_base + v_probe, v_probe);
    -- CPU closed forms on the probe weekday (M10.1 / M10.2). Assumes shipped
    -- peak window (8,18]: only the 18:00 interval is "peak".
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_AVG',  40);     -- (20+60)/2
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_P95',  58);     -- PERCENTILE_CONT(.95) of {20,60}
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_MAX',  60);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_PEAK', 60);     -- daytime interval only
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_HOST_BUSY_SEC', 0.40 * 4 * 86400);   -- 138240
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_SEC', 400);  -- 0.2*500 + 0.6*500
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_PCT', 100 * 400 / (4 * 86400));           -- 0.1157
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_PEAK_PCT', 100 * 300 / (4 * 43200));      -- 0.1736
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_HOST_SHARE', 100 * 400 / (0.40 * 4 * 86400)); -- 0.2894
    -- FIX_LINEAR closed forms
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('LINEAR_SLOPE', 10485760);              -- bytes/day
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('LINEAR_CUR',   1280 * c_nd * 8192 + 104857600);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('LINEAR_LIMIT', c_50g);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('LINEAR_DTF',
        FLOOR((c_50g - (1280 * c_nd * 8192 + 104857600)) / 10485760));                          -- 4990
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('LINEAR_PRED30_DAY',
        v_base + c_nd + 30, (1280 * c_nd * 8192 + 104857600) + 30 * 10485760);                 -- 1,677,721,600
    -- FIX_NEARFULL / FIX_FILLING closed forms (M7.1 / M8.1)
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('NEARFULL_PCT', 97.0);                    -- 124160/128000
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FILLING_DTF',
        FLOOR((192000 - (1280 * c_nd + 12800)) * c_bs / 10485760));                             -- 20
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FILLING_PCT',
        ROUND(100 * (1280 * c_nd + 12800) / 192000, 1));                                        -- 86.7

    -- ---- M9.1/M9.4 expectations for FIX_ZIGZAG, computed from first
    -- principles in exact NUMBER arithmetic over the SAME windows the views
    -- use: forecast fit = the last train_days (90) days (i 31..120); backtest
    -- fit = the 90 days ending at the 28-day-holdout cutoff (i 3..92), scored
    -- against the held-out days (i 93..120). Same closed forms as
    -- ddl/30_forecast_views.sql / CAPF_BACKTEST, including the
    -- t ~ 1.96 + 2.4/df approximation -- that formula is part of the
    -- contract. Assumes shipped defaults (train_days=90,
    -- backtest_holdout_days=28). Fitting in i-space is exact: day_n is
    -- i + constant, and slope/SSE/projections are shift-invariant.
    DECLARE
        n     PLS_INTEGER;
        sx    NUMBER; sy NUMBER; sxx NUMBER; sxy NUMBER; syy NUMBER;
        bxx   NUMBER; bxy NUMBER;                    -- centered sums
        slope NUMBER; icept NUMBER; sse NUMBER; rse NUMBER; tv NUMBER;
        sci   NUMBER; x0 NUMBER; half NUMBER; y NUMBER; hr NUMBER;
        mape  NUMBER; bias NUMBER; pred NUMBER;
        FUNCTION zz(p_i PLS_INTEGER) RETURN NUMBER IS
        BEGIN
            RETURN (12800 + 1280 * p_i
                    + CASE WHEN MOD(p_i, 2) = 0 THEN 2560 ELSE -2560 END) * c_bs;
        END;
    BEGIN
        -- forecast-window fit + 95% intervals (i = 31..120)
        n := 0; sx := 0; sy := 0; sxx := 0; sxy := 0; syy := 0;
        FOR i IN 31 .. 120 LOOP
            y := zz(i);
            n := n + 1; sx := sx + i; sy := sy + y;
            sxx := sxx + i * i; sxy := sxy + i * y; syy := syy + y * y;
        END LOOP;
        bxx   := sxx - sx * sx / n;
        bxy   := sxy - sx * sy / n;
        slope := bxy / bxx;
        icept := sy / n - slope * (sx / n);
        sse   := (syy - sy * sy / n) - bxy * bxy / bxx;
        rse   := SQRT(GREATEST(0, sse) / (n - 2));
        tv    := 1.96 + 2.4 / (n - 2);
        sci   := tv * rse / SQRT(bxx);
        x0    := c_nd + 30;
        half  := tv * rse * SQRT(1 + 1 / n + POWER(x0 - sx / n, 2) / bxx);
        hr    := c_50g - zz(c_nd);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_SLOPE',  slope);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_P30',    icept + slope * x0);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_P30_LO', icept + slope * x0 - half);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_P30_HI', icept + slope * x0 + half);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_DTF',    FLOOR(hr / slope));
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_DTF_LO', FLOOR(hr / (slope + sci)));
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_DTF_HI',
            CASE WHEN slope - sci > 0 THEN FLOOR(hr / (slope - sci)) END);

        -- backtest REGR fit (i = 3..92), scored on the holdout (i = 93..120)
        n := 0; sx := 0; sy := 0; sxx := 0; sxy := 0;
        FOR i IN 3 .. 92 LOOP
            y := zz(i);
            n := n + 1; sx := sx + i; sy := sy + y;
            sxx := sxx + i * i; sxy := sxy + i * y;
        END LOOP;
        bxx   := sxx - sx * sx / n;
        bxy   := sxy - sx * sy / n;
        slope := bxy / bxx;
        icept := sy / n - slope * (sx / n);
        mape := 0; bias := 0;
        FOR i IN 93 .. 120 LOOP
            y    := zz(i);
            pred := icept + slope * i;
            mape := mape + ABS(pred - y) / y;
            bias := bias + (pred - y) / y;
        END LOOP;
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_BT_MAPE', mape / 28 * 100);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_BT_BIAS', bias / 28 * 100);
    END;
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('Fixtures loaded: base=' || TO_CHAR(v_base,'YYYY-MM-DD')
        || ' restart=' || TO_CHAR(v_base + c_restart,'YYYY-MM-DD')
        || ' spike=' || TO_CHAR(v_base + c_spike,'YYYY-MM-DD')
        || ' inj_tue=' || TO_CHAR(v_base + v_inj,'YYYY-MM-DD Dy')
        || ' probe=' || TO_CHAR(v_base + v_probe,'YYYY-MM-DD Dy'));
END;
/

PROMPT Fixtures installed.  Next: @install.sql (seam_mode=fixture), then test/run_test.sql
