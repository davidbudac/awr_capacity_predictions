--
-- test/demo_fixture.sql -- a realistic, DESIGNED demo database for the docs.
-- =====================================================================
-- Fills the CAP_FIXTURE_* tables (same shapes as test/fixture_install.sql)
-- with 150 days of hourly AWR-shaped history for a fictional e-commerce
-- database, so the sample report published on the documentation site is the
-- real output of report/report.sql + report_html.sql, not a mock-up.
--
-- Nothing here is random: every series is a closed-form curve plus a tiny
-- deterministic ripple (a hashed sine), so the run is reproducible.
--
-- The story ("ECOMPRD", a CDB with one application PDB "SHOP_PDB"):
--   ORDERS_DATA      the headline: steady growth (weekday-heavy), ~2 months
--                    of headroom left -> a confident days-to-full WARN.
--   ORDERS_IDX       same shape, more headroom -> a healthy OK forecast.
--   AUDIT_TRAIL      growth tripled 32 days ago (a compliance-logging
--                    release) and it is about to hit its maxsize -> CRIT,
--                    with the recent-window acceleration ratio showing why.
--   SESSION_STORE    a 30-day purge cycle (sawtooth). The change-point reset
--                    fits only the post-purge leg instead of the cliff.
--   CUSTOMER_DATA    95% full RIGHT NOW but barely growing -> near-full
--                    warning, no days-to-full panic.
--   PRODUCT_CATALOG  flat, no autoextend -> FLAT, nothing to say.
--   ANALYTICS_STAGE  ~1 GiB/day of staging data, plus ONE +38 GiB backfill
--                    load 6 days ago -> a tablespace growth anomaly inside
--                    the alert window (and a forecast that shrugs it off).
--   SYSTEM / SYSAUX / UNDOTBS1  in the root container, quiet.
--   Host CPU (32 threads / 16 cores)  a business-hours/night/weekend profile
--                    with a 02:00-04:00 batch, +55% load growth over the
--                    window (busy p95 heading for the 80% saturation line
--                    in a couple of months), one runaway day 9 days ago (CPU
--                    anomaly), and an instance restart 95 days ago (a counter
--                    reset the guard must skip).
--   SHOP_PDB DB CPU  its share of host CPU jumps from 50% to 85% 12 days ago
--                    (a release) -> a sustained level shift, not an outlier,
--                    which CAPA_CPU_SHIFT reports.
--   sessions / processes (SHOP_PDB)  sessions high-water creeping toward
--                    the 90% line (~40 days), processes flat.
--   redo             ~45 GiB/day weekdays, less at weekends.
--
-- Run BEFORE @install.sql with seam_mode=fixture (the seam views need the
-- tables), in a throwaway schema. Then:
--   SQL> DEFINE seam_mode = 'fixture'
--   SQL> @install.sql
--   SQL> EXEC cap_forecast_ml.train_all
--   SQL> @report/report.sql
--   SQL> @report/report_html.sql
--
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE

-- ---- drop any prior fixtures ----
DECLARE
    TYPE nl IS TABLE OF VARCHAR2(30);
    v nl := nl('CAP_FIXTURE_SNAPSHOT','CAP_FIXTURE_TBSPC_USAGE','CAP_FIXTURE_TABLESPACE',
              'CAP_FIXTURE_DATAFILE','CAP_FIXTURE_OSSTAT','CAP_FIXTURE_TIME_MODEL',
              'CAP_FIXTURE_CONTAINER','CAP_FIXTURE_META',
              'CAP_FIXTURE_RESOURCE_LIMIT','CAP_FIXTURE_SYSSTAT');
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
CREATE TABLE cap_fixture_resource_limit (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    resource_name VARCHAR2(30), current_utilization NUMBER,
    max_utilization NUMBER, limit_value NUMBER);
CREATE TABLE cap_fixture_sysstat (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    stat_name VARCHAR2(64), value NUMBER);

DECLARE
    c_dbid    CONSTANT NUMBER      := 3141592653;    -- root con_dbid = dbid
    c_pdb     CONSTANT NUMBER      := 3141592654;    -- SHOP_PDB
    c_inst    CONSTANT NUMBER      := 1;
    c_nd      CONSTANT PLS_INTEGER := 150;           -- day index 0..150
    c_bs      CONSTANT NUMBER      := 8192;
    c_g       CONSTANT NUMBER      := 131072;        -- 1 GiB in 8 KiB blocks
    c_thr     CONSTANT NUMBER      := 32;            -- CPU threads
    c_cores   CONSTANT NUMBER      := 16;
    c_cs_h    CONSTANT NUMBER      := 32 * 3600 * 100;  -- busy+idle cs per hour
    c_restart CONSTANT PLS_INTEGER := 55;            -- restart day (04:00)
    c_audit   CONSTANT PLS_INTEGER := 118;           -- AUDIT_TRAIL growth step
    c_shift   CONSTANT PLS_INTEGER := 138;           -- SHOP_PDB DB CPU level shift
    c_purge   CONSTANT PLS_INTEGER := 12;            -- SESSION_STORE purge phase (i mod 30)
    v_base    DATE := TRUNC(SYSDATE) - c_nd;
    v_start1  TIMESTAMP := CAST(v_base - 40 AS TIMESTAMP);
    v_start2  TIMESTAMP := CAST(v_base + c_restart + 4/24 AS TIMESTAMP);
    v_start   TIMESTAMP;
    v_anom    PLS_INTEGER;                            -- runaway CPU day
    v_etlanom PLS_INTEGER;                            -- double ETL Sunday
    -- cumulative counters
    v_busy NUMBER := 0; v_idle NUMBER := 0;
    v_rcpu NUMBER := 0; v_rtime NUMBER := 0; v_rbg NUMBER := 0;
    v_pcpu NUMBER := 0; v_ptime NUMBER := 0; v_pbg NUMBER := 0;
    v_redo NUMBER := 0;
    v_smax NUMBER := 0; v_pmax NUMBER := 0;           -- resource high-water marks
    v_snap NUMBER; v_f NUMBER; v_hb NUMBER; v_cur NUMBER;
    v_used NUMBER; v_alloc NUMBER;
    -- ORDERS_* cumulative growth
    v_ord  NUMBER := 300 * c_g;
    v_idx  NUMBER := 120 * c_g;
    v_aud  NUMBER := 40 * c_g;
    v_sysx NUMBER := 8 * c_g;
    v_cust NUMBER := 149 * c_g;
    v_stage NUMBER := 15 * c_g;

    FUNCTION dow(p_i PLS_INTEGER) RETURN PLS_INTEGER IS       -- 0=Mon .. 6=Sun
    BEGIN RETURN MOD(TRUNC(v_base + p_i) - DATE '2020-01-06', 7); END;
    FUNCTION wkend(p_i PLS_INTEGER) RETURN BOOLEAN IS
    BEGIN RETURN dow(p_i) >= 5; END;
    -- deterministic ripple in [-1, 1]
    FUNCTION rip(p_i NUMBER, p_h NUMBER, p_k NUMBER) RETURN NUMBER IS
        x NUMBER := SIN(p_i * 12.9898 + p_h * 78.233 + p_k * 37.719) * 43758.5453;
    BEGIN RETURN (x - FLOOR(x)) * 2 - 1; END;

    -- host busy fraction for day i, hour h (interval ending h+1)
    FUNCTION busy(p_i PLS_INTEGER, p_h PLS_INTEGER) RETURN NUMBER IS
        f NUMBER;
    BEGIN
        f := CASE WHEN p_h <= 6               THEN 0.16
                  WHEN p_h <= 9               THEN 0.30
                  WHEN p_h <= 18              THEN 0.42       -- business hours
                  WHEN p_h <= 22              THEN 0.34
                  ELSE 0.20 END;
        IF wkend(p_i) THEN f := f * 0.92; END IF;
        f := f * (1 + 0.55 * p_i / c_nd);                    -- +55% load over the window
        IF p_h BETWEEN 2 AND 4 THEN f := GREATEST(f, 0.50); END IF;  -- nightly batch, constant
        IF p_i >= c_shift THEN f := f + 0.04; END IF;        -- the release, host side
        IF p_i = v_anom AND p_h BETWEEN 8 AND 20 THEN f := f * 1.55; END IF;
        f := f + 0.025 * rip(p_i, p_h, 1);
        RETURN LEAST(0.97, GREATEST(0.05, f));
    END;

    PROCEDURE osstat(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN INSERT INTO cap_fixture_osstat VALUES (c_dbid, c_dbid, c_inst, p_snap, p_name, p_val); END;
    PROCEDURE tm(p_con NUMBER, p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN INSERT INTO cap_fixture_time_model VALUES (c_dbid, p_con, c_inst, p_snap, p_name, p_val); END;
    PROCEDURE ts(p_con NUMBER, p_id NUMBER, p_name VARCHAR2, p_contents VARCHAR2) IS
    BEGIN
        INSERT INTO cap_fixture_tablespace VALUES (c_dbid, p_con, p_id, p_name, p_contents, c_bs);
        INSERT INTO cap_fixture_datafile   VALUES (c_dbid, p_con, p_id, c_bs);
    END;
    -- usage row: allocated = used rounded up to the next 4 GiB (+ 2 GiB slack)
    PROCEDURE usage(p_con NUMBER, p_snap NUMBER, p_id NUMBER, p_used NUMBER,
                    p_max NUMBER, p_alloc NUMBER DEFAULT NULL) IS
        a NUMBER := NVL(p_alloc, (CEIL(p_used / (4 * c_g)) * 4 + 2) * c_g);
    BEGIN
        IF p_max > 0 THEN a := LEAST(a, p_max); END IF;
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, p_con, p_snap, p_id, a, p_max, ROUND(p_used));
    END;
BEGIN
    -- the runaway CPU day: latest weekday in 139..142
    FOR i IN REVERSE 139 .. 142 LOOP
        IF NOT wkend(i) THEN v_anom := i; EXIT; END IF;
    END LOOP;
    v_etlanom := c_nd - 6;                            -- the one-off backfill load

    INSERT INTO cap_fixture_container VALUES (c_dbid, c_dbid, 'ECOMPRD', 'CDB$ROOT');
    INSERT INTO cap_fixture_container VALUES (c_dbid, c_pdb,  'ECOMPRD', 'SHOP_PDB');

    ts(c_pdb,  1, 'ORDERS_DATA',     'PERMANENT');
    ts(c_pdb,  2, 'ORDERS_IDX',      'PERMANENT');
    ts(c_pdb,  3, 'AUDIT_TRAIL',     'PERMANENT');
    ts(c_pdb,  4, 'SESSION_STORE',   'PERMANENT');
    ts(c_pdb,  5, 'CUSTOMER_DATA',   'PERMANENT');
    ts(c_pdb,  6, 'PRODUCT_CATALOG', 'PERMANENT');
    ts(c_pdb,  7, 'ANALYTICS_STAGE', 'PERMANENT');
    ts(c_dbid, 8, 'SYSTEM',          'PERMANENT');
    ts(c_dbid, 9, 'SYSAUX',          'PERMANENT');
    ts(c_dbid,10, 'UNDOTBS1',        'UNDO');

    FOR i IN 0 .. c_nd LOOP
        -- ---- daily tablespace levels (end of day) ----
        v_ord := v_ord + (CASE WHEN wkend(i) THEN 0.9 ELSE 1.3 END + 0.25 * rip(i, 0, 2)) * c_g;
        v_idx := v_idx + (0.55 + 0.10 * rip(i, 0, 3)) * c_g;
        v_aud := v_aud + (CASE WHEN i >= c_audit THEN 1.15 ELSE 0.35 END + 0.06 * rip(i, 0, 4)) * c_g;
        v_cust := v_cust + 0.02 * c_g;
        v_sysx := v_sysx + 0.03 * c_g;
        v_stage := v_stage + (1 + 0.15 * rip(i, 0, 5) + CASE WHEN i = v_etlanom THEN 38 ELSE 0 END) * c_g;

        FOR h IN 0 .. 23 LOOP
            -- restart at 04:00 on day c_restart: snapshots 00..04 missing,
            -- 05:00 onward carry the new startup_time and reset counters.
            IF i = c_restart AND h < 5 THEN CONTINUE; END IF;
            v_snap  := 50000 + 24 * i + h;
            v_start := CASE WHEN i < c_restart THEN v_start1 ELSE v_start2 END;
            -- interval (h-1):00 -> h:00, so day i owns the snapshots ending
            -- 00:00 .. 23:00 and every day in the window is complete.
            INSERT INTO cap_fixture_snapshot
            VALUES (c_dbid, c_dbid, c_inst, v_snap,
                    CAST(v_base + i + (h-1)/24 AS TIMESTAMP),
                    CAST(v_base + i + h/24 AS TIMESTAMP), v_start);

            IF i = c_restart AND h = 5 THEN
                v_busy := 0; v_idle := 0; v_rcpu := 0; v_rtime := 0; v_rbg := 0;
                v_pcpu := 0; v_ptime := 0; v_pbg := 0; v_redo := 0;
                v_smax := 0; v_pmax := 0;
            END IF;

            -- ---- host CPU (cumulative centiseconds over all threads) ----
            v_f  := busy(i, h);
            v_hb := v_f * c_cores * 3600;                   -- host busy core-seconds this hour
            v_busy := v_busy + v_f * c_cs_h;
            v_idle := v_idle + (1 - v_f) * c_cs_h;
            osstat(v_snap, 'BUSY_TIME', ROUND(v_busy));
            osstat(v_snap, 'IDLE_TIME', ROUND(v_idle));
            osstat(v_snap, 'NUM_CPUS', c_thr);
            osstat(v_snap, 'NUM_CPU_CORES', c_cores);

            -- ---- time model (cumulative microseconds), root + SHOP_PDB ----
            v_rcpu  := v_rcpu  + 0.03 * v_hb * 1e6;
            v_rtime := v_rtime + 0.03 * v_hb * 1.2 * 1e6;
            v_rbg   := v_rbg   + 90 * 1e6;
            tm(c_dbid, v_snap, 'DB CPU', ROUND(v_rcpu));
            tm(c_dbid, v_snap, 'DB time', ROUND(v_rtime));
            tm(c_dbid, v_snap, 'background cpu time', ROUND(v_rbg));
            v_pcpu  := v_pcpu  + (CASE WHEN i >= c_shift THEN 0.85 ELSE 0.50 END) * v_hb * 1e6;
            v_ptime := v_ptime + (CASE WHEN i >= c_shift THEN 0.85 ELSE 0.50 END) * v_hb * 1.35 * 1e6;
            v_pbg   := v_pbg   + 120 * 1e6;
            tm(c_pdb, v_snap, 'DB CPU', ROUND(v_pcpu));
            tm(c_pdb, v_snap, 'DB time', ROUND(v_ptime));
            tm(c_pdb, v_snap, 'background cpu time', ROUND(v_pbg));

            -- ---- redo (cumulative bytes) ----
            v_redo := v_redo + ROUND(v_f / 0.5 * 2.2 * 1073741824);
            INSERT INTO cap_fixture_sysstat VALUES (c_dbid, c_dbid, c_inst, v_snap, 'redo size', v_redo);

            -- ---- resource limits (SHOP_PDB): sessions creep, processes flat ----
            v_cur := 500 + 2.2 * i + CASE WHEN h BETWEEN 8 AND 17 AND NOT wkend(i) THEN 250 ELSE 0 END
                     + 15 * rip(i, h, 6);
            v_smax := GREATEST(v_smax, v_cur);
            INSERT INTO cap_fixture_resource_limit
            VALUES (c_dbid, c_pdb, c_inst, v_snap, 'sessions', ROUND(v_cur), ROUND(v_smax), 1300);
            v_cur := 700 + CASE WHEN h BETWEEN 8 AND 17 AND NOT wkend(i) THEN 200 ELSE 0 END
                     + 12 * rip(i, h, 7);
            v_pmax := GREATEST(v_pmax, v_cur);
            INSERT INTO cap_fixture_resource_limit
            VALUES (c_dbid, c_pdb, c_inst, v_snap, 'processes', ROUND(v_cur), ROUND(v_pmax), 1600);

            -- ---- tablespace usage: sampled at the last snapshot of the day ----
            IF h = 23 THEN
                usage(c_pdb,  v_snap, 1, v_ord,   600 * c_g);
                usage(c_pdb,  v_snap, 2, v_idx,   300 * c_g);
                usage(c_pdb,  v_snap, 3, v_aud,   130 * c_g);
                usage(c_pdb,  v_snap, 4, 20 * c_g + 2.5 * c_g * MOD(i - c_purge + 30, 30), 300 * c_g);
                usage(c_pdb,  v_snap, 5, v_cust,  160 * c_g);
                usage(c_pdb,  v_snap, 6, 12 * c_g, 0, 16 * c_g);
                usage(c_pdb,  v_snap, 7, v_stage, 400 * c_g);
                usage(c_dbid, v_snap, 8, 1.1 * c_g, 4 * c_g, 2 * c_g);
                usage(c_dbid, v_snap, 9, v_sysx,  32 * c_g);
                usage(c_dbid, v_snap,10, 6 * c_g, 0, 12 * c_g);
            END IF;
        END LOOP;
    END LOOP;

    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBID', c_dbid);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('BASE_DAY', v_base);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('LAST_DAY', v_base + c_nd);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('RESTART_DAY', v_base + c_restart);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('AUDIT_STEP_DAY', v_base + c_audit);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('SHIFT_DAY', v_base + c_shift);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('CPU_ANOM_DAY', v_base + v_anom);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('BACKFILL_DAY', v_base + v_etlanom);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Demo fixtures loaded: ' || TO_CHAR(v_base, 'YYYY-MM-DD') || ' .. '
        || TO_CHAR(v_base + c_nd, 'YYYY-MM-DD') || ' hourly; restart '
        || TO_CHAR(v_base + c_restart, 'YYYY-MM-DD') || ', audit step '
        || TO_CHAR(v_base + c_audit, 'YYYY-MM-DD') || ', cpu shift '
        || TO_CHAR(v_base + c_shift, 'YYYY-MM-DD') || ', cpu anomaly '
        || TO_CHAR(v_base + v_anom, 'YYYY-MM-DD') || ', backfill load '
        || TO_CHAR(v_base + v_etlanom, 'YYYY-MM-DD'));
END;
/
