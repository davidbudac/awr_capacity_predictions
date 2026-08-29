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
--   FIX_OVERRIDE : FIX_LINEAR's twin (10 MiB/day, 50 GiB maxsize) with a
--                  CAP_TBSPC_OVERRIDE limit of 2 GiB -> days_to_full 4990
--                  becomes OVERRIDE_DTF, limit_source 'OVERRIDE' (M9.5).
--   FIX_EXCLUDED : 99% full and would shout, but exclude_flag='Y' (matched via
--                  the dbid/con_dbid = 0 wildcard) removes it everywhere (M9.5).
--   FIX_PURGE    : 10 MiB/day, a -600 MiB purge at day 90, then 10 MiB/day
--                  again -- the M9.3 change-point reset (fit must restart at
--                  the cliff and read 10 MiB/day, not the across-the-cliff
--                  slope).
--   CPU          : two snapshots per day (06:00 = the overnight interval,
--                  18:00 = the daytime/peak interval). Weekday 20% night /
--                  60% day (daily avg 40%), weekend 10% / 30% (avg 20%), one
--                  +30pt Tuesday (70%/70%), one restart at day 60 (startup_time
--                  change + counter reset, morning snapshot missing so the
--                  whole day drops), and one PURE AWR GAP (a Sunday in 70..80
--                  whose two snapshots carry no osstat/time-model rows, so the
--                  next 06:00 interval spans 36 h). Exercises M10.1
--                  (p95/max/peak-window), M10.2 (DB CPU % of cores) and M10.5
--                  (gap_flag / max_interval_hours / day_gap) closed forms.
--   PDB CPU      : a SECOND container (FIXPDB1, con_dbid 42424243) with
--                  time-model rows ONLY -- a 7-day 34..46% DB CPU sawtooth
--                  that steps +18 points for the last 7 days. The M10.3
--                  level-shift fixture.
--   SERIES (M11) : SESSIONS max_utilization = 200 + 2*i against a limit of 500
--                  -> exactly 2/day growth, days_to_limit (90% of 500) = 5, a
--                  SERIES_LIMIT CRIT. PROCESSES constant 150 of 300 -> FLAT,
--                  no alert. 'redo size' cumulative counter +1 GiB per 12 h
--                  interval, reset at the same restart as the CPU counters ->
--                  REDO_GB_DAY = 2.0 GiB/day, no ceiling, no alert. A second
--                  ('user commits') stat name is present purely so the
--                  downstream 'redo size' filter is exercised.
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
-- M11 sources. limit_value is a NUMBER here (the local seam's
-- 'UNLIMITED'-to-NULL conversion happens in the seam, not in the contract).
CREATE TABLE cap_fixture_resource_limit (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    resource_name VARCHAR2(30), current_utilization NUMBER,
    max_utilization NUMBER, limit_value NUMBER);
CREATE TABLE cap_fixture_sysstat (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    stat_name VARCHAR2(64), value NUMBER);

DECLARE
    c_dbid   CONSTANT NUMBER := 42424242;
    c_con    CONSTANT NUMBER := 42424242;
    c_inst   CONSTANT NUMBER := 1;
    c_nd     CONSTANT PLS_INTEGER := 120;         -- day indices 0..120 (121 snaps)
    c_bs     CONSTANT NUMBER := 8192;
    c_restart CONSTANT PLS_INTEGER := 60;
    c_spike  CONSTANT PLS_INTEGER := 110;
    -- M9.3: FIX_PURGE's cliff. Day 90 of 120 leaves 31 post-purge days --
    -- comfortably above min_train_days (14), and 30 days back from the last
    -- day, i.e. OUTSIDE the 14-day anomaly_report_days alert window.
    c_purge  CONSTANT PLS_INTEGER := 90;
    c_purgeb CONSTANT NUMBER      := 76800;       -- 600 MiB in 8 KiB blocks
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
    -- M10.5: the pure-AWR-gap day. Both of its snapshots keep existing but
    -- carry NO osstat / time-model rows, so the next interval (06:00 of the
    -- following day) differences against 18:00 of the PRECEDING day and spans
    -- 36 h. Chosen at runtime as the latest SUNDAY in 70..80 so that
    --   * neither it nor the day after is a Tuesday -- the injected Tuesday's
    --     same-weekday baseline count is therefore untouched,
    --   * the affected day (a Monday, normally 40% busy) reads 30%, i.e. 10
    --     points off its baseline against a 9-point threshold: it WOULD flag
    --     LOW if the gap guard were not there,
    --   * it is far from the restart day (60), the probe day (>=115) and the
    --     M10.3 shift windows (86..120).
    v_cpugap PLS_INTEGER;
    -- M10.3: the second container (FIXPDB1, con_dbid c_con + 1) and its
    -- DB CPU level-shift series. See the block comment at the CPU counters.
    c_pdb    CONSTANT NUMBER      := 42424243;    -- = c_con + 1
    c_shift  CONSTANT PLS_INTEGER := 114;         -- first shifted day index
    c_shpts  CONSTANT NUMBER      := 18;          -- shift size, percentage points
    v_pcpu   NUMBER := 0;
    v_ptime  NUMBER := 0;
    v_pbg    NUMBER := 0;

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

    -- M10.3: the FIXPDB1 container's DB CPU level, in percent of the host's
    -- 4 cores, for day index p_i. A 7-day sawtooth 34,36,38,40,42,44,46 keyed
    -- off MOD(i,7): ANY 7 consecutive days contain each offset exactly once,
    -- so a 7-day median is exactly 40 and a 28-day (4 x 7) median is too --
    -- the medians are closed forms, not approximations. The sawtooth also
    -- gives the baseline a real MAD (sigma = 4 * 1.4826 = 5.93), which is the
    -- point of the fixture: the N-of-M confirmation then has to clear a real
    -- base_med + sigma line (45.93) rather than a degenerate flat one.
    -- The step itself is +18 points from day c_shift on, and it lands on
    -- DB_CPU_PCT -- a metric the daily CAPA_CPU_ANOM does not cover at all
    -- (that view scores host busy%, and this container has no OSSTAT). So the
    -- level shift is invisible to every other layer: the REGR trend fit reads
    -- it as noise (R^2 well under the gate), no day is ever flagged, and
    -- CAPA_CPU_SHIFT is the only thing that says the container now runs 18
    -- points hotter than it did a month ago.
    FUNCTION pdb_pct(p_i PLS_INTEGER) RETURN NUMBER IS
        v NUMBER := 40 + (MOD(p_i, 7) - 3) * 2;
    BEGIN
        IF p_i >= c_shift THEN v := v + c_shpts; END IF;
        RETURN v;
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
    -- Same, for the second container. NOTE: it gets time-model rows ONLY, no
    -- OSSTAT -- which is what a real PDB looks like, since host OSSTAT records
    -- under the CDB's con_dbid (see CLAUDE.md). That also keeps host_busy_sec
    -- for the dbid unchanged, so the existing host_share_pct closed form still
    -- holds, and it is why the M10.3 shift rides on DB_CPU_PCT (a per-PDB
    -- metric) rather than on host busy%.
    PROCEDURE ptmodel(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_time_model
        VALUES (c_dbid, c_pdb, c_inst, p_snap, p_name, p_val);
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
    -- M10.5 gap day = the latest Sunday (dow 6) in 70..80. See the declaration
    -- comment for why Sunday and why that range.
    v_cpugap := NULL;
    FOR i IN REVERSE 70 .. 80 LOOP
        IF MOD(TRUNC(v_base + i) - DATE '2020-01-06', 7) = 6 THEN v_cpugap := i; EXIT; END IF;
    END LOOP;

    -- ---- dimensions ----
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 10, 'FIX_LINEAR',   'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 11, 'FIX_SPIKE',    'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 12, 'FIX_FLAT',     'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 13, 'FIX_GAP',      'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 14, 'FIX_NEARFULL', 'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 15, 'FIX_FILLING',  'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 16, 'FIX_ZIGZAG',   'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 17, 'FIX_OVERRIDE', 'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 18, 'FIX_EXCLUDED', 'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 19, 'FIX_PURGE',    'PERMANENT', c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 10, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 11, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 12, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 13, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 14, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 15, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 16, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 17, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 18, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 19, c_bs);

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

        -- FIX_OVERRIDE (M9.5) : byte-for-byte FIX_LINEAR (10 MiB/day, 50 GiB
        -- autoextend maxsize), so WITHOUT an override it would forecast
        -- days_to_full = 4990. A CAP_TBSPC_OVERRIDE row (inserted after this
        -- block) caps the real ceiling at 2 GiB -- days_to_full collapses to
        -- OVERRIDE_DTF and limit_source becomes 'OVERRIDE'. The pair
        -- FIX_LINEAR / FIX_OVERRIDE is therefore a controlled experiment:
        -- identical data, different limit, and only the override explains it.
        v_used := 1280 * i + 12800;
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 17, v_used, v_max50g, v_used);

        -- FIX_EXCLUDED (M9.5) : constant 126720 of maxsize 128000 blocks =
        -- exactly 99.0% full, which WOULD raise a TBSPC_NEARFULL CRIT. An
        -- exclude_flag='Y' override (via the dbid=0/con_dbid=0 WILDCARD, so
        -- the wildcard match path is exercised too) removes it at
        -- CAPD_TBSPC_DAILY, so it must appear NOWHERE downstream -- the
        -- loudest possible series making the quietest possible noise.
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 18, 128000, 128000, 126720);

        -- FIX_PURGE (M9.3) : FIX_LINEAR's growth (10 MiB/day, 1280 blocks/day,
        -- base 100 MiB, 50 GiB autoextend maxsize) with ONE cliff: at day 90 a
        -- purge removes 600 MiB (76800 blocks) and growth resumes at the same
        -- rate. Fitted ACROSS the cliff the slope reads ~5 MiB/day and the
        -- headroom is a fiction; with reset_on_shrink=1 the window restarts AT
        -- day 90 (the reset day carries the already-purged level) and the fit
        -- sees 31 perfectly linear post-purge days -> exactly 10 MiB/day.
        v_used := 1280 * i + 12800 - CASE WHEN i >= c_purge THEN c_purgeb ELSE 0 END;
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 19, v_used, v_max50g, v_used);

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
        --
        -- M10.5 PURE AWR GAP. On day v_cpugap the counters keep ACCUMULATING
        -- (the instance was up -- only the snapshots are missing), but no
        -- osstat / time-model row is written for either of its two snaps. The
        -- effect is exactly a real AWR gap: day v_cpugap disappears from
        -- CAPD_CPU_DAILY, and the 06:00 interval of the NEXT day differences
        -- against 18:00 of the PREVIOUS day, so it spans 36 h and carries
        -- three half-days of CPU. That day therefore reads 30% busy against a
        -- 40% Monday baseline -- past the 9-point threshold -- and must stay
        -- unflagged purely because gap_flag = 'Y'. It is a different failure
        -- from the restart at day 60, whose long interval is thrown away by
        -- the startup_time guard instead.
        --
        -- M10.3 SECOND CONTAINER (FIXPDB1). Time-model rows only, split evenly
        -- over the two 12 h intervals so the per-interval percentage equals
        -- the daily one (p95 = avg, nothing to reason about). Daily
        -- db_cpu_pct = 100 * db_cpu_sec / (4 cores * 86400 s), so a level of
        -- L points needs L * 3456 CPU-seconds a day, i.e. L * 1728 per
        -- interval. pdb_pct() supplies L.
        IF i = c_restart THEN
            v_busy := 0; v_idle := 0; v_dbcpu := 0; v_dbtime := 0; v_bg := 0;
            v_pcpu := 0; v_ptime := 0; v_pbg := 0;
        ELSE
            v_busy   := v_busy   + fnight(i) * c_tot_cs / 2;
            v_idle   := v_idle   + (1 - fnight(i)) * c_tot_cs / 2;
            v_dbcpu  := v_dbcpu  + fnight(i) * 500 * 1000000;
            v_dbtime := v_dbtime + fnight(i) * 600 * 1000000;
            v_bg     := v_bg     + 25 * 1000000;
            v_pcpu   := v_pcpu   + pdb_pct(i) * 1728 * 1000000;
            v_ptime  := v_ptime  + pdb_pct(i) * 1728 * 1.2 * 1000000;
            v_pbg    := v_pbg    + 25 * 1000000;
            IF i <> v_cpugap THEN
                osstat(2000 + 2 * i, 'BUSY_TIME', v_busy);
                osstat(2000 + 2 * i, 'IDLE_TIME', v_idle);
                osstat(2000 + 2 * i, 'NUM_CPUS', 4);
                osstat(2000 + 2 * i, 'NUM_CPU_CORES', 4);
                tmodel(2000 + 2 * i, 'DB CPU', v_dbcpu);
                tmodel(2000 + 2 * i, 'DB time', v_dbtime);
                tmodel(2000 + 2 * i, 'background cpu time', v_bg);
            END IF;
            ptmodel(2000 + 2 * i, 'DB CPU', v_pcpu);
            ptmodel(2000 + 2 * i, 'DB time', v_ptime);
            ptmodel(2000 + 2 * i, 'background cpu time', v_pbg);
        END IF;
        v_busy   := v_busy   + fday(i) * c_tot_cs / 2;
        v_idle   := v_idle   + (1 - fday(i)) * c_tot_cs / 2;
        v_dbcpu  := v_dbcpu  + fday(i) * 500 * 1000000;
        v_dbtime := v_dbtime + fday(i) * 600 * 1000000;
        v_bg     := v_bg     + 25 * 1000000;
        v_pcpu   := v_pcpu   + pdb_pct(i) * 1728 * 1000000;
        v_ptime  := v_ptime  + pdb_pct(i) * 1728 * 1.2 * 1000000;
        v_pbg    := v_pbg    + 25 * 1000000;
        IF i <> v_cpugap THEN
            osstat(2001 + 2 * i, 'BUSY_TIME', v_busy);
            osstat(2001 + 2 * i, 'IDLE_TIME', v_idle);
            osstat(2001 + 2 * i, 'NUM_CPUS', 4);
            osstat(2001 + 2 * i, 'NUM_CPU_CORES', 4);
            tmodel(2001 + 2 * i, 'DB CPU', v_dbcpu);
            tmodel(2001 + 2 * i, 'DB time', v_dbtime);
            tmodel(2001 + 2 * i, 'background cpu time', v_bg);
        END IF;
        ptmodel(2001 + 2 * i, 'DB CPU', v_pcpu);
        ptmodel(2001 + 2 * i, 'DB time', v_ptime);
        ptmodel(2001 + 2 * i, 'background cpu time', v_pbg);
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
    -- M10.5 gap closed forms. The gap day itself vanishes; the day AFTER it
    -- carries one 36 h interval (Sunday night 0.10 + Sunday day 0.30 + Monday
    -- night 0.20 = 0.60 of three half-days) plus the normal 12 h Monday
    -- daytime interval (0.60 of one half-day):
    --   busy_pct = 100 * (0.60 + 0.60) / 4 = 30  (vs a 40% Monday baseline,
    --              i.e. 10 points off against a 9-point threshold -- it WOULD
    --              flag LOW without the gap guard)
    --   busy_p95 = 60, from the 12 h interval ALONE (the 36 h one averages
    --              20% and is excluded from p95/max as too long to be a
    --              "peak hour"; an unfiltered p95 of {20,60} would be 58)
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('CPUGAP_DAY',  v_base + v_cpugap, v_cpugap);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('CPUGAP_NEXT', v_base + v_cpugap + 1, v_cpugap + 1);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPUGAP_HOURS',    36);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPUGAP_DAYGAP',    2);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPUGAP_BUSY_PCT', 30);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPUGAP_P95',      60);
    -- M10.3 level-shift closed forms for the FIXPDB1 container. The 7-day
    -- sawtooth means both medians are exact: 40 over any whole number of
    -- weeks, 58 over the shifted last 7 days.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PDB_CON_DBID',      c_pdb);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SHIFT_EXPECTED_PTS', c_shpts);       -- 18
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SHIFT_BASE_MED',     40);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SHIFT_RECENT_MED',   40 + c_shpts);  -- 58
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SHIFT_BASE_SIGMA',   4 * 1.4826);    -- 5.9304
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
    -- M9.5 FIX_OVERRIDE closed forms. The series is FIX_LINEAR's twin, so its
    -- last-day usage is the same (1,363,148,800 bytes); only the ceiling
    -- differs -- 2 GiB from CAP_TBSPC_OVERRIDE instead of the 50 GiB maxsize.
    -- Written as a bare NUMBER literal for the same reason c_50g is: the
    -- 2*1024*1024*1024 product would overflow PLS_INTEGER first.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('OVERRIDE_LIMIT', 2147483648);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('OVERRIDE_DTF',
        FLOOR((2147483648 - (1280 * c_nd + 12800) * c_bs) / 10485760));                         -- 74

    -- ---- M9.2 / M9.3 expectations ----------------------------------------
    -- FIX_SPIKE's TRUE growth rate: 640 blocks/day = 5 MiB/day. Theil-Sen must
    -- land on it (the +2 GiB step at day 110 makes only 869 of the 4005
    -- pairwise slopes "crossing" pairs -- a 22% minority, well under the 29%
    -- breakdown point), while OLS is dragged to ~4x it.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SPIKE_RATE', 640 * c_bs);                 -- 5,242,880
    -- FIX_PURGE (M9.3): the reset day, the post-purge window size and the
    -- days-to-full computed off the post-purge line.
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('PURGE_DAY', v_base + c_purge, c_purge);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PURGE_TRAIN_N', c_nd - c_purge + 1);       -- 31
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PURGE_CUR',
        (1280 * c_nd + 12800 - c_purgeb) * c_bs);                                                -- 734,003,200
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PURGE_DTF',
        FLOOR((c_50g - (1280 * c_nd + 12800 - c_purgeb) * c_bs) / 10485760));                    -- 5050

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

    -- ---- M9.2 Theil-Sen expectation for FIX_ZIGZAG -----------------------
    -- The median of ALL 4005 pairwise slopes (y_j - y_i)/(j - i) over the same
    -- forecast window the view fits (i = 31..120). Built explicitly here: the
    -- pairs are enumerated in a loop, sorted by ROW_NUMBER, and the median is
    -- taken as the average of the two middle values for an even count (exactly
    -- Oracle's MEDIAN / PERCENTILE_CONT(0.5) semantics) -- spelled out rather
    -- than delegated to MEDIAN so the expectation is independent of the
    -- aggregate the view uses. SYS.ODCINUMBERLIST is a shipped VARRAY(32767)
    -- OF NUMBER, so no fixture-owned type is needed. Fitting in i-space is
    -- exact: day_n = i + constant, and a pairwise slope is shift-invariant.
    DECLARE
        v_ps   SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        v_med  NUMBER;
        v_cnt  NUMBER;
        FUNCTION zz(p_i PLS_INTEGER) RETURN NUMBER IS
        BEGIN
            RETURN (12800 + 1280 * p_i
                    + CASE WHEN MOD(p_i, 2) = 0 THEN 2560 ELSE -2560 END) * c_bs;
        END;
    BEGIN
        FOR i IN 31 .. 119 LOOP
            FOR j IN i + 1 .. 120 LOOP
                v_ps.EXTEND;
                v_ps(v_ps.COUNT) := (zz(j) - zz(i)) / (j - i);
            END LOOP;
        END LOOP;
        SELECT AVG(x) INTO v_med
        FROM   (SELECT column_value AS x,
                       ROW_NUMBER() OVER (ORDER BY column_value) AS rn,
                       COUNT(*)     OVER ()                      AS c
                FROM   TABLE(v_ps))
        WHERE  rn IN (FLOOR((c + 1) / 2), CEIL((c + 1) / 2));
        -- v_ps.COUNT is a collection METHOD: legal in PL/SQL, ORA-00984 inside
        -- a SQL statement, so it goes through a local variable.
        v_cnt := v_ps.COUNT;
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_TS_SLOPE', v_med);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_TS_PAIRS', v_cnt);
    END;
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('Fixtures loaded: base=' || TO_CHAR(v_base,'YYYY-MM-DD')
        || ' restart=' || TO_CHAR(v_base + c_restart,'YYYY-MM-DD')
        || ' spike=' || TO_CHAR(v_base + c_spike,'YYYY-MM-DD')
        || ' inj_tue=' || TO_CHAR(v_base + v_inj,'YYYY-MM-DD Dy')
        || ' probe=' || TO_CHAR(v_base + v_probe,'YYYY-MM-DD Dy')
        || ' cpu_gap=' || TO_CHAR(v_base + v_cpugap,'YYYY-MM-DD Dy'));
END;
/

-- =====================================================================
-- M11 -- fixed-ceiling series fixtures (resource limits + redo).
-- =====================================================================
-- Deliberately a SEPARATE block from the tablespace/CPU loader above: it only
-- needs the snapshot spine that block already created, and keeping it apart
-- means the two can be read (and changed) independently.
--
-- It reuses the EXISTING snapshot ids -- 2000+2i ends 06:00, 2001+2i ends
-- 18:00 -- including the restart-day hole (i = 60 has no 06:00 snapshot, and
-- the counters reset), so the redo counter meets exactly the same restart
-- guard the CPU counters do and the restart day produces no REDO_GB_DAY row.
--
-- Closed forms (assume the shipped knobs train_days = 90, series_sat_pct = 90):
--   SESSIONS   max_utilization = 200 + 2*i, limit 500 -> slope exactly 2/day,
--              R2 = 1 (quality OK), cur = 440 on the last day (88% of limit,
--              deliberately just UNDER nearfull_warn_pct so only the
--              days-to-limit branch fires), and
--              days_to_limit = FLOOR((500*0.90 - 440) / 2) = 5  -> CRIT.
--   PROCESSES  constant 150 of 300 -> slope 0 -> FLAT, no days_to_limit,
--              50% of limit -> no alert of either kind.
--   REDO       +1 GiB per 12 h interval -> 2 GiB/day every full day, i.e. a
--              PERFECTLY FLAT GiB/day series with NO ceiling: it must produce
--              a REDO_GB_DAY value of exactly 2.0 and never an alert.
DECLARE
    c_dbid   CONSTANT NUMBER := 42424242;
    c_con    CONSTANT NUMBER := 42424242;
    c_inst   CONSTANT NUMBER := 1;
    c_nd     CONSTANT PLS_INTEGER := 120;
    c_restart CONSTANT PLS_INTEGER := 60;
    c_gib    CONSTANT NUMBER := 1073741824;
    c_sesslim CONSTANT NUMBER := 500;
    c_proclim CONSTANT NUMBER := 300;
    c_satpct CONSTANT NUMBER := 90;               -- shipped series_sat_pct
    v_redo   NUMBER := 0;
    v_probe  PLS_INTEGER;

    PROCEDURE rlim(p_snap NUMBER, p_name VARCHAR2, p_cur NUMBER,
                   p_max NUMBER, p_lim NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_resource_limit
        VALUES (c_dbid, c_con, c_inst, p_snap, p_name, p_cur, p_max, p_lim);
    END;
    PROCEDURE sstat(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_sysstat
        VALUES (c_dbid, c_con, c_inst, p_snap, p_name, p_val);
    END;
    -- Both resource rows for one snapshot. max_utilization is the number the
    -- daily view takes the MAX of, so it is what the forecast fits.
    PROCEDURE res_day(p_snap NUMBER, p_i PLS_INTEGER) IS
    BEGIN
        rlim(p_snap, 'sessions',  180 + 2 * p_i, 200 + 2 * p_i, c_sesslim);
        rlim(p_snap, 'processes', 120,           150,           c_proclim);
    END;
BEGIN
    SELECT nval INTO v_probe FROM cap_fixture_meta WHERE mkey = 'PROBE_DAY';

    FOR i IN 0 .. c_nd LOOP
        -- Resource limits: sampled at every snapshot that exists.
        IF i <> c_restart THEN
            res_day(2000 + 2 * i, i);
        END IF;
        res_day(2001 + 2 * i, i);

        -- Redo: cumulative BYTE counter, +1 GiB per interval, reset by the
        -- restart exactly like the OSSTAT / time-model counters above.
        IF i = c_restart THEN
            v_redo := 0;
        ELSE
            v_redo := v_redo + c_gib;
            sstat(2000 + 2 * i, 'redo size', v_redo);
            -- Noise: a stat name the series must ignore. Its value is chosen
            -- to be absurd on the redo scale, so a missing filter is loud.
            sstat(2000 + 2 * i, 'user commits', 987654321 + i);
        END IF;
        v_redo := v_redo + c_gib;
        sstat(2001 + 2 * i, 'redo size', v_redo);
        sstat(2001 + 2 * i, 'user commits', 987654321 + i);
    END LOOP;

    -- ---- expected values for run_test.sql ----
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SESS_CUR',   200 + 2 * c_nd);   -- 440
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SESS_LIMIT', c_sesslim);        -- 500
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SESS_DTL',
        FLOOR((c_sesslim * c_satpct / 100 - (200 + 2 * c_nd)) / 2));                   -- 5
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PROC_CUR',   150);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PROC_LIMIT', c_proclim);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('REDO_PROBE_GB', 2);
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('M11 fixtures loaded: sessions 200..'
        || TO_CHAR(200 + 2 * c_nd) || ' of ' || TO_CHAR(c_sesslim)
        || ', processes 150 of ' || TO_CHAR(c_proclim)
        || ', redo 2 GiB/day, probe day index ' || TO_CHAR(v_probe));
END;
/

-- =====================================================================
-- M9.5 -- CAP_TBSPC_OVERRIDE fixture rows.
-- =====================================================================
-- CHICKEN AND EGG: the harness order is fixture_install -> install.sql, and
-- CAP_TBSPC_OVERRIDE is created by ddl/05_config.sql -- i.e. AFTER this script.
-- But the override rows must already be there when the CAPD/CAPF views are
-- first queried, and ddl/00_drop.sql deliberately does NOT drop the table (it
-- is operator data that survives a re-install), so seeding it here is safe:
-- install.sql's own CREATE swallows ORA-00955, finds the table we made, and
-- leaves these rows alone. Hence the create below is a verbatim copy of the
-- one in ddl/05_config.sql -- keep the two in sync if the shape ever changes.
DECLARE
BEGIN
    EXECUTE IMMEDIATE 'CREATE TABLE cap_tbspc_override (
        dbid            NUMBER        DEFAULT 0   NOT NULL,
        con_dbid        NUMBER        DEFAULT 0   NOT NULL,
        tablespace_name VARCHAR2(30)              NOT NULL,
        limit_bytes     NUMBER,
        exclude_flag    CHAR(1)       DEFAULT ''N'' NOT NULL,
        note            VARCHAR2(200),
        CONSTRAINT cap_tbspc_override_pk PRIMARY KEY (dbid, con_dbid, tablespace_name),
        CONSTRAINT cap_tbspc_override_ck CHECK (exclude_flag IN (''Y'',''N''))
    )';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

-- Re-runnable: clear only THIS fixture's rows (every fixture tablespace is
-- named FIX_%, under dbid 42424242 or the wildcard 0), then re-seed. An
-- operator's real rows in the same schema are never touched.
DELETE FROM cap_tbspc_override WHERE tablespace_name LIKE 'FIX!_%' ESCAPE '!';

INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note)
VALUES (42424242, 42424242, 'FIX_OVERRIDE', 2147483648, 'N',
        'M9.5: real ceiling is 2 GiB, not the 50 GiB autoextend maxsize.');

-- A LESS specific duplicate for the same tablespace. The exact-key row above
-- must win the specificity ranking in CAPD_TBSPC_DAILY.ores, so OVERRIDE_DTF
-- is computed against 2 GiB and never against this 1 GiB decoy.
INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note)
VALUES (0, 0, 'FIX_OVERRIDE', 1073741824, 'N',
        'M9.5: wildcard decoy -- the exact-key row must outrank this.');

-- Pure WILDCARD row (any dbid, any con_dbid): exercises the "fleet-wide rule"
-- matching path as well as exclude_flag.
INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note)
VALUES (0, 0, 'FIX_EXCLUDED', NULL, 'Y',
        'M9.5: scratch tablespace -- excluded from every layer.');

COMMIT;

PROMPT Fixtures installed.  Next: @install.sql (seam_mode=fixture), then test/run_test.sql
