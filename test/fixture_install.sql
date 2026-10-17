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
--   FIX_GAP      : 60 MiB/day with a 3-day AWR gap (rate normalization),
--                  plus a 3-day burst of +256 MiB a day on days 115..117
--                  (one 3-day TBSPC_ANOM episode in CAPR_ALERTS).
--   FIX_NEARFULL : constant at exactly 97.0% of maxsize (FLAT quality but
--                  near-full NOW -> M7.1 ranking + TBSPC_NEARFULL alert).
--   FIX_FILLING  : 10 MiB/day against a small maxsize -> days_to_full = 20
--                  (TBSPC_FULL CRIT alert), pct 86.7% (below near-full).
--                  A CAP_TBSPC_OVERRIDE row with no ceiling sets its own
--                  dtf_crit 25 / dtf_warn 60 (per-tablespace thresholds).
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
--   FIX_OVERFULL : flat 1.5 GiB used of ~1.6 GiB allocated, with a
--                  CAP_TBSPC_OVERRIDE ceiling of 1 GiB: the limit is under the
--                  usage (limit_below_used = Y, pct_used 150, FLAT so
--                  days_to_full NULL, TBSPC_NEARFULL CRIT).
--   FIX_DROPPED  : FIX_LINEAR's 10 MiB/day, but its usage rows stop 30 days
--                  before the end of the spine (a dropped tablespace): it
--                  still fits (OK) and reads is_current = N.
--   FIX_CYCLIC   : a 30-day sawtooth (rolling retention): 20 GiB after each
--                  purge, +2.5 GiB/day for 29 days to a 92.5 GiB peak, then
--                  a cliff back to 20 GiB, against a 300 GiB maxsize. Cliffs
--                  on the days i = 5 (mod 30): 3 in the 90-day window, so
--                  quality CYCLIC, no reset, no days_to_full (flat peaks).
--   FIX_CYCLIC_UP: the same sawtooth with floor and peak +1 GiB per cycle
--                  and a maxsize one block under 300 GiB: peak_slope_bpd =
--                  1 GiB / 30 days and days_to_full off the peak line.
--   CPU          : two snapshots per day (06:00 = the overnight interval,
--                  18:00 = the daytime/peak interval) on an SMT host:
--                  NUM_CPUS 8, NUM_CPU_CORES 4. Weekday 20% night /
--                  60% day (daily avg 40%), weekend 10% / 30% (avg 20%), one
--                  +30pt Tuesday (70%/70%), one inverted Wednesday (40%/40%:
--                  a normal daily average, an abnormal hour profile -- M15
--                  HOUR_OF_WEEK), one restart at day 60 (startup_time
--                  change + counter reset, morning snapshot missing so the
--                  whole day drops), one PARTIAL day (a weekday in 14..20
--                  whose instance restarts at noon: only its 06:00 interval
--                  survives, 12 h of 24), and one PURE AWR GAP (a Sunday in
--                  70..80 whose two snapshots carry no osstat/time-model rows,
--                  so the next 06:00 interval spans 36 h). Exercises M10.1
--                  (p95/max/peak-window), M10.2 (DB CPU % of logical CPUs),
--                  M10.5 (gap_flag / max_interval_hours / day_gap) and the
--                  covered_sec / is_complete closed forms.
--   PDB CPU      : a SECOND container (FIXPDB1, con_dbid 42424243) with
--                  time-model rows ONLY -- a 7-day 34..46% DB CPU sawtooth
--                  that steps +18 points for the last 7 days. The M10.3
--                  level-shift fixture.
--   PDB2 CPU     : a THIRD container (FIXPDB2, con_dbid 42424244), time-model
--                  rows only: DB CPU at 60% on weekdays and 20% at weekends
--                  plus a ramp of 1/12 point a day (+10 over the spine). The
--                  night interval runs at level - s and the day interval at
--                  level + s (s = 25 weekdays, 10 weekends), so DB_CPU_P95 =
--                  level + 0.9 s sits above 80% on weekdays. The weekday /
--                  weekend deseasoning, slope-significance gate and hot_now
--                  fixture.
--   SERIES (M11) : SESSIONS max_utilization = 200 + 2*i against a limit of 500
--                  -> exactly 2/day growth, days_to_limit (90% of 500) = 5, a
--                  SERIES_LIMIT CRIT. PROCESSES constant 150 of 300 -> FLAT,
--                  no alert. 'redo size' cumulative counter +1 GiB per 12 h
--                  interval, reset at the same restart as the CPU counters ->
--                  REDO_GB_DAY = 2.0 GiB/day, no ceiling, no alert. A second
--                  ('user commits') stat name is present purely so the
--                  downstream 'redo size' filter is exercised.
--   CONTAINER    : FIXCDB root row + FIXPDB1 and FIXPDB2 rows (M7.2 labels).
--   PARAMETER    : the nine CAPV_PARAMETER names on every snapshot, cpu_count
--                  8 = NUM_CPUS (no CPU number moves) and
--                  db_recovery_file_dest_size 100 GiB -> FRA days at the
--                  2 GiB/day redo rate = 50.
--   ASM          : diskgroup DATA, 1000 GiB, used 200 + 5*i GiB at the 18:00
--                  sample (2.5 GiB less at 06:00) -> ASM_DG:+DATA cur 800,
--                  days_to_limit (90% of 1000) = 20, a SERIES_LIMIT CRIT.
--                  Diskgroup FRA: 50 of 200 GiB, flat.
--   FIX_TEMP     : TEMPORARY, 20 GiB allocated, no autoextend. The 06:00
--                  sample is the day's peak, 6 - i/64 GiB, then 19.5 GiB on
--                  the last day; the 18:00 sample reads 1 GiB. TEMP_PEAK
--                  reads the peak, 97.5% of the limit now (SERIES_NEARLIMIT
--                  CRIT), slope negative, LOW_CONFIDENCE.
--   FIX_UNDO     : UNDO, 4 GiB allocated, autoextend to 10 GiB, peak 3 GiB at
--                  18:00 every day: UNDO_PEAK 3 of 10 GiB, FLAT.
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
              'CAP_FIXTURE_RESOURCE_LIMIT','CAP_FIXTURE_SYSSTAT',
              'CAP_FIXTURE_PARAMETER','CAP_FIXTURE_ASM_DISKGROUP',
              'CAP_FIXTURE_SEG_STAT');
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
-- value_num is a NUMBER here (the local seam converts DBA_HIST_PARAMETER's
-- VARCHAR2), group_name has no '+' (AWR stores the bare name).
CREATE TABLE cap_fixture_parameter (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    parameter_name VARCHAR2(64), value_num NUMBER);
CREATE TABLE cap_fixture_asm_diskgroup (
    dbid NUMBER, con_dbid NUMBER, snap_id NUMBER, group_name VARCHAR2(128),
    total_mb NUMBER, free_mb NUMBER, usable_file_mb NUMBER);
-- Segment space deltas (CAPV_SEG_STAT), already joined to the names.
CREATE TABLE cap_fixture_seg_stat (
    dbid NUMBER, con_dbid NUMBER, instance_number NUMBER, snap_id NUMBER,
    tablespace_id NUMBER, tablespace_name VARCHAR2(30), owner VARCHAR2(128),
    object_name VARCHAR2(128), subobject_name VARCHAR2(128), object_type VARCHAR2(18),
    space_used_delta NUMBER, space_allocated_delta NUMBER);

DECLARE
    c_dbid   CONSTANT NUMBER := 42424242;
    c_con    CONSTANT NUMBER := 42424242;
    c_inst   CONSTANT NUMBER := 1;
    c_nd     CONSTANT PLS_INTEGER := 120;         -- day indices 0..120 (121 snaps)
    c_bs     CONSTANT NUMBER := 8192;
    c_restart CONSTANT PLS_INTEGER := 60;
    c_spike  CONSTANT PLS_INTEGER := 110;
    -- FIX_GAP's burst: +32768 blocks (256 MiB) on each of the 3 days
    -- c_burst .. c_burst + 2. Inside the 14-day alert window, after the
    -- spike, and 2.5x the 100 MiB anomaly floor while 0.25 GiB stays under
    -- DB_SIZE_GB's 0.5 GiB series floor, so only the tablespace flags.
    c_burst  CONSTANT PLS_INTEGER := 115;
    c_burstb CONSTANT NUMBER      := 32768;
    -- M9.3: FIX_PURGE's cliff. Day 90 of 120 leaves 31 post-purge days --
    -- comfortably above min_train_days (14), and 30 days back from the last
    -- day, i.e. OUTSIDE the 14-day anomaly_report_days alert window.
    c_purge  CONSTANT PLS_INTEGER := 90;
    c_purgeb CONSTANT NUMBER      := 76800;       -- 600 MiB in 8 KiB blocks
    -- FIX_DROPPED's usage rows stop this many days before the last day, so
    -- its last_day is c_drop days behind the newest day of the dbid: stale
    -- under the default stale_days (3), current once stale_days >= c_drop.
    c_drop   CONSTANT PLS_INTEGER := 30;
    -- FIX_OVERFULL: 1.5 GiB used (196608 blocks) of 209715 blocks (~1.6 GiB)
    -- allocated, no autoextend. Its override ceiling is 1 GiB (131072 blocks).
    c_ofused CONSTANT NUMBER      := 196608;
    c_ofsize CONSTANT NUMBER      := 209715;
    c_oflim  CONSTANT NUMBER      := 1073741824;
    -- BUSY_TIME + IDLE_TIME are summed over NUM_CPUS (logical CPUs), so a day
    -- holds 8 * 86400 * 100 cs. NUM_CPU_CORES = 4: a 2-way SMT host.
    c_ncpu   CONSTANT NUMBER := 8;
    c_ncore  CONSTANT NUMBER := 4;
    c_tot_cs CONSTANT NUMBER := c_ncpu * 86400 * 100;  -- 69,120,000 cs/day
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
    -- M15: the inverted-profile Wednesday. Both of its intervals read 40%
    -- busy (the overnight batch ran in the daytime instead): the daily
    -- average is 40, exactly a normal weekday, so TRAILING and SAME_DOW
    -- cannot see it, while HOUR_OF_WEEK sees 06:00 at 40 vs 20 (HIGH) and
    -- 18:00 at 40 vs 60 (LOW) -- the case only the third mode catches.
    v_invwed PLS_INTEGER;
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
    -- The PARTIAL day: a weekday in 14..20 whose instance restarts at noon.
    -- Its 06:00 interval is valid, its 18:00 one spans the restart and is
    -- dropped, so the day covers 12 h and reads is_complete = 'N' with
    -- gap_flag = 'N'. Placed before the train_days window (31..120) so no
    -- fit or alert moves. The anomaly engine never scores an is_complete =
    -- 'N' day (its 20% would read LOW against the TRAILING median), and it
    -- has at most two same-weekday priors anyway (weekly_min_hist = 3).
    v_partial PLS_INTEGER;
    v_startp TIMESTAMP;
    -- Local functions cannot be called inside SQL (PLS-00231), so the meta
    -- values that need fnight() / pdb_pct() go through these.
    v_pnight NUMBER;
    v_ppdb   NUMBER;
    v_prpdb  NUMBER;
    v_gpdb   NUMBER;
    -- M10.3: the second container (FIXPDB1, con_dbid c_con + 1) and its
    -- DB CPU level-shift series. See the block comment at the CPU counters.
    c_pdb    CONSTANT NUMBER      := 42424243;    -- = c_con + 1
    c_shift  CONSTANT PLS_INTEGER := 114;         -- first shifted day index
    c_shpts  CONSTANT NUMBER      := 18;          -- shift size, percentage points
    v_pcpu   NUMBER := 0;
    v_ptime  NUMBER := 0;
    v_pbg    NUMBER := 0;
    -- FIX_CYCLIC / FIX_CYCLIC_UP: cliffs on the days i = c_cyc0 (mod 30).
    -- c_cyc0 = 5 puts 3 cliffs (35, 65, 95) in the 90-day window (31..120),
    -- the first window day mid-rise (so segment 0 still ends at a peak), the
    -- last cliff 25 days back (outside the 14-day anomaly alert window), and
    -- keeps the fixture's DB_SIZE_GB slope positive.
    c_cyc0   CONSTANT PLS_INTEGER := 5;
    c_cyclen CONSTANT PLS_INTEGER := 30;
    c_gb     CONSTANT NUMBER      := 131072;      -- 1 GiB in 8 KiB blocks
    c_cycmax CONSTANT NUMBER      := 39321600;    -- 300 GiB in 8 KiB blocks
    -- FIXPDB2: the deseasoning / slope-significance / hot_now container.
    c_pdb2   CONSTANT NUMBER      := 42424244;    -- = c_con + 2
    v_qcpu   NUMBER := 0;
    v_qtime  NUMBER := 0;
    v_qbg    NUMBER := 0;

    FUNCTION dow(p_i PLS_INTEGER) RETURN PLS_INTEGER IS       -- 0=Mon .. 6=Sun
    BEGIN RETURN MOD(TRUNC(v_base + p_i) - DATE '2020-01-06', 7); END;

    -- Busy fraction of the overnight (18:00 -> 06:00) and daytime (06:00 ->
    -- 18:00) intervals. Equal 12 h halves, so the daily time-weighted
    -- average is exactly their mean: weekday 0.40, weekend 0.20, injected 0.70.
    FUNCTION fnight(p_i PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        IF p_i = v_inj THEN RETURN 0.70;
        ELSIF p_i = v_invwed THEN RETURN 0.40;
        ELSIF dow(p_i) >= 5 THEN RETURN 0.10;
        ELSE RETURN 0.20; END IF;
    END;
    FUNCTION fday(p_i PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        IF p_i = v_inj THEN RETURN 0.70;
        ELSIF p_i = v_invwed THEN RETURN 0.40;
        ELSIF dow(p_i) >= 5 THEN RETURN 0.30;
        ELSE RETURN 0.60; END IF;
    END;

    -- M10.3: the FIXPDB1 container's DB CPU level, in percent of the host's
    -- 8 logical CPUs, for day index p_i. A 7-day sawtooth 34,36,38,40,42,44,46 keyed
    -- off MOD(i,7): ANY 7 consecutive days contain each offset exactly once,
    -- so a 7-day median is exactly 40 and a 28-day (4 x 7) median is too --
    -- the medians are closed forms, not approximations. The sawtooth also
    -- gives the baseline a real MAD (sigma = 4 * 1.4826 = 5.93), which is the
    -- point of the fixture: the N-of-M confirmation then has to clear a real
    -- base_med + sigma line (45.93) rather than a degenerate flat one.
    -- The step itself is +18 points from day c_shift on, and it lands on
    -- DB_CPU_PCT (this container has no OSSTAT, so no host busy%). The REGR
    -- trend fit reads it as noise (R^2 well under the gate), and CAPA_CPU_SHIFT
    -- says the container now runs 18 points hotter than a month ago. M15's
    -- anomaly modes see the step DAYS too: every step day is 18 points over
    -- its same-weekday priors (SAME_DOW, floor threshold 9), while TRAILING,
    -- whose window mixes the sawtooth (sigma 5.93), flags only the days whose
    -- deviation clears 3 x sigma (run_test.sql derives which).
    FUNCTION pdb_pct(p_i PLS_INTEGER) RETURN NUMBER IS
        v NUMBER := 40 + (MOD(p_i, 7) - 3) * 2;
    BEGIN
        IF p_i >= c_shift THEN v := v + c_shpts; END IF;
        RETURN v;
    END;

    -- FIX_CYCLIC (p_grow 0) / FIX_CYCLIC_UP (p_grow 1) used blocks on day
    -- p_i: cycle day k = 0 is the post-purge floor, k = 29 the peak. Cycle c
    -- is -1 before the first cliff, so FIX_CYCLIC_UP's floor is 19 GiB there.
    FUNCTION cyc_used(p_i PLS_INTEGER, p_grow PLS_INTEGER) RETURN NUMBER IS
        k PLS_INTEGER := MOD(p_i - c_cyc0 + c_cyclen, c_cyclen);
        c NUMBER      := FLOOR((p_i - c_cyc0) / c_cyclen);
    BEGIN
        RETURN 20 * c_gb + c_gb * 5 / 2 * k + p_grow * c_gb * c;
    END;

    -- FIXPDB2 daily DB CPU level (percent of the 8 logical CPUs) and the
    -- half-spread of its two 12 h intervals around it.
    FUNCTION p2_lvl(p_i PLS_INTEGER) RETURN NUMBER IS
    BEGIN RETURN CASE WHEN dow(p_i) >= 5 THEN 20 ELSE 60 END + p_i / 12; END;
    FUNCTION p2_spr(p_i PLS_INTEGER) RETURN NUMBER IS
    BEGIN RETURN CASE WHEN dow(p_i) >= 5 THEN 10 ELSE 25 END; END;

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
    PROCEDURE qtmodel(p_snap NUMBER, p_name VARCHAR2, p_val NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_time_model
        VALUES (c_dbid, c_pdb2, c_inst, p_snap, p_name, p_val);
    END;
BEGIN
    -- Injected Tuesday = the LATEST Tuesday (dow=1) in range, so no later
    -- same-weekday baseline is polluted by it. Probe = a plain weekday.
    v_inj := NULL;
    FOR i IN REVERSE 90 .. c_nd LOOP
        IF MOD(TRUNC(v_base + i) - DATE '2020-01-06', 7) = 1 THEN v_inj := i; EXIT; END IF;
    END LOOP;
    -- M10.5 gap day = the latest Sunday (dow 6) in 70..80. See the declaration
    -- comment for why Sunday and why that range.
    v_cpugap := NULL;
    FOR i IN REVERSE 70 .. 80 LOOP
        IF MOD(TRUNC(v_base + i) - DATE '2020-01-06', 7) = 6 THEN v_cpugap := i; EXIT; END IF;
    END LOOP;
    -- Partial day = the latest weekday (dow 0..4) in 14..20.
    v_partial := NULL;
    FOR i IN REVERSE 14 .. 20 LOOP
        IF MOD(TRUNC(v_base + i) - DATE '2020-01-06', 7) < 5 THEN v_partial := i; EXIT; END IF;
    END LOOP;
    v_startp := CAST(v_base + v_partial + 12/24 AS TIMESTAMP);
    -- M15 inverted Wednesday = the latest Wednesday (dow 2) in 90..c_nd: inside
    -- the alert window's reach, never the injected Tuesday or a gap day (a
    -- Sunday / Monday in 70..81), and chosen BEFORE the probe so the probe
    -- can avoid it.
    v_invwed := NULL;
    FOR i IN REVERSE 90 .. c_nd LOOP
        IF MOD(TRUNC(v_base + i) - DATE '2020-01-06', 7) = 2 THEN v_invwed := i; EXIT; END IF;
    END LOOP;
    v_probe := NULL;
    FOR i IN REVERSE 61 .. (c_nd - 1) LOOP
        IF MOD(TRUNC(v_base + i) - DATE '2020-01-06', 7) < 5
           AND i <> v_inj AND i <> v_invwed THEN
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
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 17, 'FIX_OVERRIDE', 'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 18, 'FIX_EXCLUDED', 'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 19, 'FIX_PURGE',    'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 20, 'FIX_OVERFULL', 'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 21, 'FIX_DROPPED',  'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 22, 'FIX_CYCLIC',   'PERMANENT', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 23, 'FIX_CYCLIC_UP','PERMANENT', c_bs);
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
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 20, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 21, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 22, c_bs);
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 23, c_bs);

    -- Container naming (M7.2): the row every fixture series resolves through
    -- (con_dbid = dbid -> label is the db_name alone), plus one synthetic PDB
    -- row (con_dbid <> dbid, no facts attached) purely to assert the
    -- DBNAME/PDBNAME label branch of CAPR_CONTAINER.
    INSERT INTO cap_fixture_container VALUES (c_dbid, c_con,     'FIXCDB', 'CDB$ROOT');
    INSERT INTO cap_fixture_container VALUES (c_dbid, c_con + 1, 'FIXCDB', 'FIXPDB1');
    INSERT INTO cap_fixture_container VALUES (c_dbid, c_pdb2,    'FIXCDB', 'FIXPDB2');

    -- ---- per-day series ----
    -- Two snapshots a day: 2000+2i ends 06:00 (covers the night), 2001+2i
    -- ends 18:00 (covers the day = the peak window). Tablespace usage hangs
    -- off the 18:00 snapshot only (last-of-day). On the restart day the
    -- instance was down overnight, so the 06:00 snapshot does not exist and
    -- the 18:00 one carries the new startup_time + reset counters: the single
    -- interval that day spans the restart and is dropped by the guard.
    -- On the partial day the instance restarts at noon, so its 06:00
    -- snapshot keeps the old startup_time and its 18:00 one has the new.
    FOR i IN 0 .. c_nd LOOP
        v_start := CASE WHEN i <= v_partial  THEN v_start1
                        WHEN i <  c_restart  THEN v_startp
                        ELSE                      v_start2 END;
        IF i <> c_restart THEN
            INSERT INTO cap_fixture_snapshot
            VALUES (c_dbid, c_con, c_inst, 2000 + 2 * i,
                    CAST(v_base + i - 6/24 AS TIMESTAMP),
                    CAST(v_base + i + 6/24 AS TIMESTAMP), v_start);
        END IF;
        IF i = v_partial THEN v_start := v_startp; END IF;
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

        -- FIX_OVERFULL : constant, so FLAT (slope 0, days_to_full NULL). Its
        -- 1 GiB override ceiling (inserted after this block) sits under the
        -- 1.5 GiB it uses: pct_used 150, limit_below_used = 'Y'.
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 20, c_ofsize, 0, c_ofused);

        -- FIX_DROPPED : FIX_LINEAR's growth, but nothing after day c_nd -
        -- c_drop. The fit window is its own last train_days days, so it still
        -- grades OK. The dbid's newest day stays c_nd (every other series).
        IF i <= c_nd - c_drop THEN
            v_used := 1280 * i + 12800;
            INSERT INTO cap_fixture_tbspc_usage
            VALUES (c_dbid, c_con, 2001 + 2 * i, 21, v_used, v_max50g, v_used);
        END IF;

        -- FIX_CYCLIC / FIX_CYCLIC_UP : the rolling-retention sawtooths (see
        -- cyc_used). FIX_CYCLIC_UP's maxsize is one block under 300 GiB so the
        -- peak-line division never lands on an exact integer, where FLOOR
        -- would hang on the last digit of REGR_SLOPE.
        v_used := cyc_used(i, 0);
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 22, v_used, c_cycmax, v_used);
        v_used := cyc_used(i, 1);
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, 2001 + 2 * i, 23, v_used, c_cycmax - 1, v_used);

        -- FIX_GAP : 60 MiB/day = 7680 blocks/day, but with a 3-day AWR gap
        -- (days 100-102 have NO usage sample). The post-gap day (103) sees a
        -- 4-day, 240 MiB jump; the per-day RATE (60 MiB) must NOT flag. Without
        -- gap normalization the 240 MiB raw delta would exceed the 100 MiB floor
        -- and false-flag. Exercises the CAPD_TBSPC_DELTA day_gap / rate fix.
        IF i NOT BETWEEN 100 AND 102 THEN
            v_used := 7680 * i + 6400
                      + c_burstb * LEAST(GREATEST(i - c_burst + 1, 0), 3);
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
        -- db_cpu_pct = 100 * db_cpu_sec / (8 logical CPUs * 86400 s), so a
        -- level of L points needs L * 6912 CPU-seconds a day, i.e. L * 3456
        -- per interval. pdb_pct() supplies L.
        --
        -- PARTIAL DAY. The 06:00 rows are written as usual, then every
        -- counter resets before the 18:00 rows, which carry the new
        -- startup_time: that interval is a restart and is dropped.
        IF i = c_restart THEN
            v_busy := 0; v_idle := 0; v_dbcpu := 0; v_dbtime := 0; v_bg := 0;
            v_pcpu := 0; v_ptime := 0; v_pbg := 0;
            v_qcpu := 0; v_qtime := 0; v_qbg := 0;
        ELSE
            v_busy   := v_busy   + fnight(i) * c_tot_cs / 2;
            v_idle   := v_idle   + (1 - fnight(i)) * c_tot_cs / 2;
            v_dbcpu  := v_dbcpu  + fnight(i) * 500 * 1000000;
            v_dbtime := v_dbtime + fnight(i) * 600 * 1000000;
            v_bg     := v_bg     + 25 * 1000000;
            v_pcpu   := v_pcpu   + pdb_pct(i) * 3456 * 1000000;
            v_ptime  := v_ptime  + pdb_pct(i) * 3456 * 1.2 * 1000000;
            v_pbg    := v_pbg    + 25 * 1000000;
            IF i <> v_cpugap THEN
                osstat(2000 + 2 * i, 'BUSY_TIME', v_busy);
                osstat(2000 + 2 * i, 'IDLE_TIME', v_idle);
                osstat(2000 + 2 * i, 'NUM_CPUS', c_ncpu);
                osstat(2000 + 2 * i, 'NUM_CPU_CORES', c_ncore);
                tmodel(2000 + 2 * i, 'DB CPU', v_dbcpu);
                tmodel(2000 + 2 * i, 'DB time', v_dbtime);
                tmodel(2000 + 2 * i, 'background cpu time', v_bg);
            END IF;
            ptmodel(2000 + 2 * i, 'DB CPU', v_pcpu);
            ptmodel(2000 + 2 * i, 'DB time', v_ptime);
            ptmodel(2000 + 2 * i, 'background cpu time', v_pbg);
            -- FIXPDB2 night interval: level - spread.
            v_qcpu   := v_qcpu  + (p2_lvl(i) - p2_spr(i)) * 3456 * 1000000;
            v_qtime  := v_qtime + (p2_lvl(i) - p2_spr(i)) * 3456 * 1.2 * 1000000;
            v_qbg    := v_qbg   + 25 * 1000000;
            qtmodel(2000 + 2 * i, 'DB CPU', v_qcpu);
            qtmodel(2000 + 2 * i, 'DB time', v_qtime);
            qtmodel(2000 + 2 * i, 'background cpu time', v_qbg);
        END IF;
        IF i = v_partial THEN
            v_busy := 0; v_idle := 0; v_dbcpu := 0; v_dbtime := 0; v_bg := 0;
            v_pcpu := 0; v_ptime := 0; v_pbg := 0;
            v_qcpu := 0; v_qtime := 0; v_qbg := 0;
        END IF;
        v_busy   := v_busy   + fday(i) * c_tot_cs / 2;
        v_idle   := v_idle   + (1 - fday(i)) * c_tot_cs / 2;
        v_dbcpu  := v_dbcpu  + fday(i) * 500 * 1000000;
        v_dbtime := v_dbtime + fday(i) * 600 * 1000000;
        v_bg     := v_bg     + 25 * 1000000;
        v_pcpu   := v_pcpu   + pdb_pct(i) * 3456 * 1000000;
        v_ptime  := v_ptime  + pdb_pct(i) * 3456 * 1.2 * 1000000;
        v_pbg    := v_pbg    + 25 * 1000000;
        IF i <> v_cpugap THEN
            osstat(2001 + 2 * i, 'BUSY_TIME', v_busy);
            osstat(2001 + 2 * i, 'IDLE_TIME', v_idle);
            osstat(2001 + 2 * i, 'NUM_CPUS', c_ncpu);
            osstat(2001 + 2 * i, 'NUM_CPU_CORES', c_ncore);
            tmodel(2001 + 2 * i, 'DB CPU', v_dbcpu);
            tmodel(2001 + 2 * i, 'DB time', v_dbtime);
            tmodel(2001 + 2 * i, 'background cpu time', v_bg);
        END IF;
        ptmodel(2001 + 2 * i, 'DB CPU', v_pcpu);
        ptmodel(2001 + 2 * i, 'DB time', v_ptime);
        ptmodel(2001 + 2 * i, 'background cpu time', v_pbg);
        -- FIXPDB2 day interval: level + spread.
        v_qcpu   := v_qcpu  + (p2_lvl(i) + p2_spr(i)) * 3456 * 1000000;
        v_qtime  := v_qtime + (p2_lvl(i) + p2_spr(i)) * 3456 * 1.2 * 1000000;
        v_qbg    := v_qbg   + 25 * 1000000;
        qtmodel(2001 + 2 * i, 'DB CPU', v_qcpu);
        qtmodel(2001 + 2 * i, 'DB time', v_qtime);
        qtmodel(2001 + 2 * i, 'background cpu time', v_qbg);
    END LOOP;

    -- ---- expected values / key dates for run_test.sql ----
    v_pnight := fnight(v_partial);
    v_ppdb   := pdb_pct(v_partial);
    v_prpdb  := pdb_pct(v_probe);
    v_gpdb   := pdb_pct(v_cpugap);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBID', c_dbid);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('BASE_DAY',    v_base);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('LAST_DAY',    v_base + c_nd);
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('SPIKE_DAY',   v_base + c_spike);
    -- Results layer: FIX_GAP's burst episode and the robust z of its days
    -- (dev / (abs_floor_bytes / mad_k): every baseline there is flat, so
    -- the floor sets eff_sigma), and FIX_SPIKE's single day for contrast.
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('BURST_FIRST', v_base + c_burst, c_burst);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('BURST_LAST',  v_base + c_burst + 2, c_burst + 2);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('BURST_DAYS', 3);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('BURST_Z',    c_burstb * c_bs / (104857600 / 3));  -- 7.68
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SPIKE_Z',    262144 * c_bs / (104857600 / 3));    -- 61.44
    -- FIX_LINEAR seen 7 days ago (last row i = c_nd - 7): 7 more days of headroom.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('LINEAR_DTF7',
        FLOOR((c_50g - (1280 * (c_nd - 7) + 12800) * c_bs) / 10485760));                         -- 4997
    INSERT INTO cap_fixture_meta (mkey, dval) VALUES ('RESTART_DAY', v_base + c_restart);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('INJECTED_TUE', v_base + v_inj, v_inj);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('PROBE_DAY',    v_base + v_probe, v_probe);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('INVERTED_WED', v_base + v_invwed, v_invwed);
    -- CPU closed forms on the probe weekday (M10.1 / M10.2). Assumes shipped
    -- peak window (8,18]: only the 18:00 interval is "peak".
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_AVG',  40);     -- (20+60)/2
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_P95',  58);     -- PERCENTILE_CONT(.95) of {20,60}
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_MAX',  60);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_PEAK', 60);     -- daytime interval only
    -- DB CPU percentages divide by LOGICAL CPUs (8), not cores (4).
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_PROBE_HOST_BUSY_SEC', 0.40 * c_ncpu * 86400);   -- 276480
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_SEC', 400);  -- 0.2*500 + 0.6*500
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_PCT', 100 * 400 / (c_ncpu * 86400));           -- 0.0579
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_PEAK_PCT', 100 * 300 / (c_ncpu * 43200));      -- 0.0868
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_HOST_SHARE', 100 * 400 / (0.40 * c_ncpu * 86400)); -- 0.1447
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_PER_CORE', 400 / c_ncore);                      -- 100
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_PCT_CORES', 100 * 400 / (c_ncore * 86400));    -- 0.1157, NUM_CPUS deleted
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('NUM_CPUS', c_ncpu);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('NUM_CPU_CORES', c_ncore);
    -- Coverage closed forms. A full day is two valid 12 h intervals. The
    -- partial day keeps only its 06:00 interval (weekday night, 20% busy,
    -- 0.2 * 500 s of DB CPU), and so does the first day of the series,
    -- whose 06:00 snapshot has no predecessor.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FULL_COVERED_SEC', 86400);
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('PARTIAL_DAY', v_base + v_partial, v_partial);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PARTIAL_COVERED_SEC', 43200);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PARTIAL_BUSY_PCT', 100 * v_pnight);                     -- 20
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PARTIAL_DBCPU_PCT',
        100 * v_pnight * 500 / (c_ncpu * 43200));                                                              -- 0.0289
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PDB_PARTIAL_PCT', v_ppdb);
    -- FIXPDB1's DB CPU is split evenly over the two 12 h intervals, so both
    -- M15 hour buckets of a day also read pdb_pct (the day's level).
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PDB_PROBE_PCT',   v_prpdb);
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
    -- The post-gap day covers 36 h + 12 h. Its DB CPU is (0.10 + 0.30 +
    -- 0.20) * 500 s over the long interval plus 0.60 * 500 s over the short
    -- one, and db_cpu_pct divides by the 48 h actually covered.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPUGAP_COVERED_SEC', 48 * 3600);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPUGAP_DBCPU_PCT', 100 * 600 / (c_ncpu * 48 * 3600));  -- 0.0434
    -- FIXPDB1 keeps time-model rows on the gap day, where OSSTAT has none:
    -- its NUM_CPUS is carried forward from the previous snapshot.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('PDB_GAP_PCT', v_gpdb);
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

    -- ---- clamp / staleness expectations ---------------------------------
    -- FIX_OVERFULL: limit 1 GiB under 1.5 GiB used.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('OVERFULL_CUR',   c_ofused * c_bs);             -- 1,610,612,736
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('OVERFULL_LIMIT', c_oflim);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('OVERFULL_PCT',
        ROUND(100 * c_ofused * c_bs / c_oflim, 1));                                              -- 150
    -- FIX_DROPPED: last row at day c_nd - c_drop, a full train_days window
    -- (days 1..90) behind it, and c_drop days between it and the newest day.
    INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('DROPPED_LAST_DAY', v_base + c_nd - c_drop, c_nd - c_drop);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DROPPED_TRAIN_N', 90);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DROPPED_STALE_GAP', c_drop);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DROPPED_CUR', (1280 * (c_nd - c_drop) + 12800) * c_bs);

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
        zcur  NUMBER;                                -- zz(c_nd): local functions are not callable in SQL
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
        zcur  := zz(c_nd);
        hr    := c_50g - zcur;
        -- Projections are anchored at today: cur + slope * 30, with the
        -- unchanged half-width around it. ZZ_P30_FIT keeps the fitted-line
        -- value (icept + slope * x0), which the view's icept still yields.
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_SLOPE',  slope);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_CUR',    zcur);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_P30_FIT', icept + slope * x0);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_P30',    zcur + slope * 30);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_P30_LO', zcur + slope * 30 - half);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_P30_HI', zcur + slope * 30 + half);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_DTF',    FLOOR(hr / slope));
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_DTF_LO', FLOOR(hr / (slope + sci)));
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_DTF_HI',
            CASE WHEN slope - sci > 0 THEN FLOOR(hr / (slope - sci)) END);

        -- backtest REGR fit (i = 3..92), scored on the holdout (i = 93..120),
        -- anchored at the cutoff day's actual value: pred = zz(92) + slope * (i - 92)
        n := 0; sx := 0; sy := 0; sxx := 0; sxy := 0;
        FOR i IN 3 .. 92 LOOP
            y := zz(i);
            n := n + 1; sx := sx + i; sy := sy + y;
            sxx := sxx + i * i; sxy := sxy + i * y;
        END LOOP;
        bxx   := sxx - sx * sx / n;
        bxy   := sxy - sx * sy / n;
        slope := bxy / bxx;
        mape := 0; bias := 0;
        FOR i IN 93 .. 120 LOOP
            y    := zz(i);
            pred := zz(92) + slope * (i - 92);
            mape := mape + ABS(pred - y) / y;
            bias := bias + (pred - y) / y;
        END LOOP;
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_BT_MAPE', mape / 28 * 100);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_BT_BIAS', bias / 28 * 100);

        -- Results layer (CAPR_FORECAST_ACCURACY): the forecast a run issued 7
        -- days ago, fitted on the 90 days i = c_nd - 96 .. c_nd - 7 and
        -- anchored at zz(c_nd - 7), against today's zz(c_nd). run_test.sql
        -- issues it by hiding FIX_ZIGZAG's last 7 days around a backdated
        -- cap_results.refresh.
        n := 0; sx := 0; sy := 0; sxx := 0; sxy := 0;
        FOR i IN (c_nd - 96) .. (c_nd - 7) LOOP
            y := zz(i);
            n := n + 1; sx := sx + i; sy := sy + y;
            sxx := sxx + i * i; sxy := sxy + i * y;
        END LOOP;
        bxx   := sxx - sx * sx / n;
        bxy   := sxy - sx * sy / n;
        slope := bxy / bxx;
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_ACC7_SLOPE', slope);
        y := zz(c_nd) - (zz(c_nd - 7) + 7 * slope);    -- PLS-00231: no local function in SQL
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_ACC7_ERR', y);
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

    -- ---- complete-day fits: expected train_n from the construction ------
    -- The CPU and redo fits read is_complete = 'Y' days only. Which days of
    -- a window carry a complete row:
    --   CPU (root)  : not day 0 (first, 12 h), not the restart day and not
    --                 the gap day (no row), not the partial day (12 h).
    --   REDO_GB_DAY : not day 0, not the restart day, not the partial day.
    --                 The gap day keeps its redo rows, so it stays.
    --   SESSIONS    : a level series, every day counts.
    -- With the shipped train_days (90) the window is days 31..120 and holds
    -- no partial day, so the run_test flip to train_days = 120 (days 1..120)
    -- is what proves the partial day is left out.
    DECLARE
        PROCEDURE put_counts(p_win PLS_INTEGER, p_suffix VARCHAR2) IS
            n_cpu PLS_INTEGER := 0; n_redo PLS_INTEGER := 0; n_sess PLS_INTEGER := 0;
        BEGIN
            FOR i IN c_nd - p_win + 1 .. c_nd LOOP
                IF i > 0 AND i NOT IN (c_restart, v_cpugap, v_partial) THEN n_cpu := n_cpu + 1; END IF;
                IF i > 0 AND i NOT IN (c_restart, v_partial)          THEN n_redo := n_redo + 1; END IF;
                n_sess := n_sess + 1;
            END LOOP;
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_TRAIN_N'  || p_suffix, n_cpu);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('REDO_TRAIN_N' || p_suffix, n_redo);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SESS_TRAIN_N' || p_suffix, n_sess);
        END;
    BEGIN
        put_counts(90,  NULL);         -- 88 / 89 / 90
        put_counts(120, '_120');       -- 117 / 118 / 120
    END;

    -- ---- CPU fits: deseasoned OLS, anchor, significance, hot_now --------
    -- Every CPU closed form below mirrors CAPF_CPU_TREND under the shipped
    -- knobs (train_days 90, shift_days 7, cpu_sat_pct 80): complete days in
    -- the window i = c_nd - 89 .. c_nd, OLS in i-space (day_n is i +
    -- constant, so slopes, residuals and fitted values at a given i are
    -- shift-invariant), the M9.1 t ~ 1.96 + 2.4/df, and, when deseasoned,
    -- fval = val - mean(val of the same day type) + mean(val) over the
    -- window, day type = weekday or Saturday / Sunday. The anchor is the
    -- MEDIAN of the raw values over the last 7 days (all complete for these
    -- series).
    DECLARE
        v_x  SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        v_y  SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        v_a  SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        v_slope NUMBER; v_icept NUMBER; v_ci NUMBER; v_r2 NUMBER;
        v_anchor NUMBER; v_cur NUMBER; v_rslope NUMBER; v_rr2 NUMBER;

        FUNCTION med(p SYS.ODCINUMBERLIST) RETURN NUMBER IS v NUMBER;
        BEGIN
            SELECT AVG(x) INTO v
            FROM   (SELECT column_value AS x,
                           ROW_NUMBER() OVER (ORDER BY column_value) AS rn,
                           COUNT(*)     OVER ()                      AS c
                    FROM   TABLE(p))
            WHERE  rn IN (FLOOR((c + 1) / 2), CEIL((c + 1) / 2));
            RETURN v;
        END;

        PROCEDURE put(p_k VARCHAR2, p_v NUMBER) IS
        BEGIN INSERT INTO cap_fixture_meta (mkey, nval) VALUES (p_k, p_v); END;

        -- OLS of v_y on v_x (deseasoned when p_ds = 1) -> slope, icept,
        -- slope CI half-width, R^2.
        PROCEDURE ols(p_ds PLS_INTEGER, o_slope OUT NUMBER, o_icept OUT NUMBER,
                      o_ci OUT NUMBER, o_r2 OUT NUMBER) IS
            n NUMBER := v_x.COUNT;
            m_all NUMBER := 0; m_we NUMBER := 0; m_wd NUMBER := 0; n_we NUMBER := 0;
            sx NUMBER := 0; sy NUMBER := 0; sxx NUMBER := 0; sxy NUMBER := 0; syy NUMBER := 0;
            y NUMBER; bxx NUMBER; bxy NUMBER; byy NUMBER; sse NUMBER;
        BEGIN
            FOR k IN 1 .. n LOOP
                m_all := m_all + v_y(k);
                IF dow(v_x(k)) >= 5 THEN m_we := m_we + v_y(k); n_we := n_we + 1;
                ELSE m_wd := m_wd + v_y(k); END IF;
            END LOOP;
            m_all := m_all / n;
            IF n_we > 0 THEN m_we := m_we / n_we; END IF;
            IF n_we < n THEN m_wd := m_wd / (n - n_we); END IF;
            FOR k IN 1 .. n LOOP
                y := v_y(k);
                IF p_ds = 1 THEN
                    y := y - CASE WHEN dow(v_x(k)) >= 5 THEN m_we ELSE m_wd END + m_all;
                END IF;
                sx := sx + v_x(k); sy := sy + y; sxx := sxx + v_x(k) * v_x(k);
                sxy := sxy + v_x(k) * y; syy := syy + y * y;
            END LOOP;
            bxx := sxx - sx * sx / n; bxy := sxy - sx * sy / n; byy := syy - sy * sy / n;
            o_slope := bxy / bxx;
            o_icept := sy / n - o_slope * sx / n;
            sse     := GREATEST(0, byy - bxy * bxy / bxx);
            o_ci    := (1.96 + 2.4 / (n - 2)) * SQRT(sse / (n - 2)) / SQRT(bxx);
            o_r2    := bxy * bxy / (bxx * byy);
        END;
    BEGIN
        -- Root BUSY_PCT: complete days skip the restart day and the gap day.
        -- The day after the gap averages its 36 h + 12 h intervals (four
        -- half-days). No trend by construction: the injected Tuesday near
        -- the end is the only lever, and it is not significant.
        FOR i IN c_nd - 89 .. c_nd LOOP
            IF i NOT IN (c_restart, v_cpugap) THEN
                v_x.EXTEND; v_x(v_x.COUNT) := i;
                v_y.EXTEND;
                v_y(v_y.COUNT) := CASE WHEN i = v_cpugap + 1
                                       THEN 100 * (fnight(i - 1) + fday(i - 1) + fnight(i) + fday(i)) / 4
                                       ELSE 100 * (fnight(i) + fday(i)) / 2 END;
            END IF;
        END LOOP;
        FOR i IN c_nd - 6 .. c_nd LOOP
            v_a.EXTEND; v_a(v_a.COUNT) := 100 * (fnight(i) + fday(i)) / 2;
        END LOOP;
        ols(1, v_slope, v_icept, v_ci, v_r2);
        put('ROOT_BUSY_SLOPE',  v_slope);
        put('ROOT_BUSY_CI',     v_ci);
        put('ROOT_BUSY_ANCHOR', med(v_a));                                  -- 40
        put('ROOT_BUSY_P30',    med(v_a) + 30 * v_slope);

        -- FIXPDB1 DB_CPU_PCT: exactly pdb_pct(i) on every complete day (the
        -- restart day has no row). The +18 step over the last 7 days makes
        -- the anchor 58 and the deseasoned slope significant.
        v_x.DELETE; v_y.DELETE; v_a.DELETE;
        FOR i IN c_nd - 89 .. c_nd LOOP
            IF i <> c_restart THEN
                v_x.EXTEND; v_x(v_x.COUNT) := i;
                v_y.EXTEND; v_y(v_y.COUNT) := pdb_pct(i);
            END IF;
        END LOOP;
        FOR i IN c_nd - 6 .. c_nd LOOP
            v_a.EXTEND; v_a(v_a.COUNT) := pdb_pct(i);
        END LOOP;
        v_cur    := pdb_pct(c_nd);
        v_anchor := med(v_a);
        ols(0, v_rslope, v_icept, v_ci, v_rr2);       -- raw (legacy) fit first
        put('PDB_DBCPU_SLOPE_RAW', v_rslope);
        put('PDB_DBCPU_R2_RAW',    v_rr2);
        ols(1, v_slope, v_icept, v_ci, v_r2);
        put('PDB_DBCPU_TRAIN_N',   v_x.COUNT);                               -- 89
        put('PDB_DBCPU_CUR',       v_cur);
        put('PDB_DBCPU_ANCHOR',    v_anchor);                                -- 58
        put('PDB_DBCPU_SLOPE',     v_slope);
        put('PDB_DBCPU_CI',        v_ci);
        put('PDB_DBCPU_P30',       v_anchor + v_slope * 30);
        put('PDB_DBCPU_P30_FIT',   v_icept + v_slope * (c_nd + 30));
        put('PDB_DBCPU_P30_RAW',   v_anchor + v_rslope * 30);
        put('PDB_DBCPU_DTS',       FLOOR((80 - v_anchor) / v_slope));

        -- FIXPDB2 DB_CPU_PCT = p2_lvl(i): a weekly two-level pattern plus a
        -- 1/12 point/day ramp. Deseasoned, only the ramp (and a tiny
        -- day-type offset from the window's uneven weekday positions) is
        -- left, so the fit is significant. Raw, R^2 stays near 0.
        v_x.DELETE; v_y.DELETE; v_a.DELETE;
        FOR i IN c_nd - 89 .. c_nd LOOP
            IF i <> c_restart THEN
                v_x.EXTEND; v_x(v_x.COUNT) := i;
                v_y.EXTEND; v_y(v_y.COUNT) := p2_lvl(i);
            END IF;
        END LOOP;
        FOR i IN c_nd - 6 .. c_nd LOOP
            v_a.EXTEND; v_a(v_a.COUNT) := p2_lvl(i);
        END LOOP;
        v_anchor := med(v_a);
        ols(0, v_rslope, v_icept, v_ci, v_rr2);
        put('PDB2_PCT_SLOPE_RAW', v_rslope);
        put('PDB2_PCT_R2_RAW',    v_rr2);
        ols(1, v_slope, v_icept, v_ci, v_r2);
        put('PDB2_CON_DBID',      c_pdb2);
        put('PDB2_TRAIN_N',       v_x.COUNT);
        put('PDB2_PCT_SLOPE',     v_slope);
        put('PDB2_PCT_CI',        v_ci);
        put('PDB2_PCT_R2',        v_r2);
        put('PDB2_PCT_ANCHOR',    v_anchor);
        put('PDB2_PCT_P30',       v_anchor + v_slope * 30);
        put('PDB2_PCT_DTS',       FLOOR((80 - v_anchor) / v_slope));
        -- DB_CPU_P95 = PERCENTILE_CONT(.95) of {level - s, level + s} =
        -- level + 0.9 s: about 92 on the last weekdays, so hot now.
        v_a.DELETE;
        FOR i IN c_nd - 6 .. c_nd LOOP
            v_a.EXTEND; v_a(v_a.COUNT) := p2_lvl(i) + 0.9 * p2_spr(i);
        END LOOP;
        put('PDB2_P95_RECENT_MED', med(v_a));
    END;

    -- ---- CYCLIC expectations (FIX_CYCLIC / FIX_CYCLIC_UP) ---------------
    -- Walked over the forecast window (i = c_nd - 89 .. c_nd) straight from
    -- cyc_used: a cliff is a day whose usage falls (the sawtooth's only
    -- negative steps, 72.5 / 71.5 GiB, far past the 100 MiB floor with a
    -- zero MAD). Each cliff closes a segment, whose maximum is a cycle peak.
    DECLARE
        n_cl NUMBER; n_pk NUMBER; seg_max NUMBER; seg_day NUMBER; w_max NUMBER;
        sx NUMBER; sy NUMBER; sxx NUMBER; sxy NUMBER;
        lpk NUMBER; lpkd NUMBER; slope NUMBER; lim NUMBER; lcl NUMBER;
        ccur NUMBER;               -- cyc_used(c_nd, g): not callable inside SQL
    BEGIN
        FOR g IN 0 .. 1 LOOP
            n_cl := 0; n_pk := 0; seg_max := NULL; w_max := 0;
            sx := 0; sy := 0; sxx := 0; sxy := 0;
            FOR i IN c_nd - 89 .. c_nd LOOP
                IF cyc_used(i, g) < cyc_used(i - 1, g) THEN
                    IF seg_max IS NOT NULL THEN
                        n_pk := n_pk + 1;
                        sx := sx + seg_day; sy := sy + seg_max;
                        sxx := sxx + seg_day * seg_day; sxy := sxy + seg_day * seg_max;
                        lpk := seg_max; lpkd := seg_day;
                    END IF;
                    n_cl := n_cl + 1;
                    lcl  := i;
                    seg_max := NULL;
                END IF;
                IF seg_max IS NULL OR cyc_used(i, g) >= seg_max THEN
                    seg_max := cyc_used(i, g); seg_day := i;
                END IF;
                w_max := GREATEST(w_max, cyc_used(i, g));
            END LOOP;
            slope := (sxy - sx * sy / n_pk) / (sxx - sx * sx / n_pk) * c_bs;
            ccur  := cyc_used(c_nd, g) * c_bs;
            lim   := (c_cycmax - g) * c_bs;
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_N',     n_cl);     -- 3
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_NPK',   n_pk);     -- 3
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_DAYS',  c_cyclen); -- 30
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_PEAK',  w_max * c_bs);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_PCT',
                ROUND(100 * w_max * c_bs / lim, 1));                                          -- 30.8 / 31.5
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_CUR',   ccur);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_PSLOPE', slope); -- 0 / 1 GiB / 30
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_DTF',
                CASE WHEN slope > 0
                     THEN GREATEST(0, FLOOR((lim - lpk * c_bs) / slope - (c_nd - lpkd))) END);
            -- With the grade off (cyclic_min_cliffs = 0) the M9.3 reset
            -- restarts at the last cliff: the window is the current rise,
            -- exactly 2.5 GiB/day, and days_to_full counts along it.
            INSERT INTO cap_fixture_meta (mkey, dval, nval) VALUES ('CYC' || g || '_LAST_CLIFF', v_base + lcl, lcl);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_RISE', c_gb * 5 / 2 * c_bs);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_LEGACY_N', c_nd - lcl + 1);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CYC' || g || '_LEGACY_DTF',
                FLOOR((lim - ccur) / (c_gb * 5 / 2 * c_bs)));
        END LOOP;
    END;

    -- ---- DRIFT expectations (slope_method = 2) ---------------------------
    -- The rates of a window are its day-over-day steps, all one day apart
    -- for these series. slope = MEDIAN (the mean of the two middle values
    -- for an even count), sd = sample standard deviation, se = sd /
    -- SQRT(n_rates), t = 1.96 + 2.4 / (n_rates - 1), CI = t * se, half_30 =
    -- t * (sd * SQRT(30) + 30 * se). Windows: the forecast window i = 31 ..
    -- 120 (89 rates, from day 32), FIX_PURGE's post-reset window 90 .. 120
    -- (30 rates, the cliff day has no rate). The backtest twins use the
    -- training window i = 3 .. 92 and score i = 93 .. 120.
    DECLARE
        v_r  SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        FUNCTION val(p_k VARCHAR2, p_i PLS_INTEGER) RETURN NUMBER IS
        BEGIN
            RETURN c_bs * CASE p_k
                WHEN 'LINEAR' THEN 1280 * p_i + 12800
                WHEN 'SPIKE'  THEN 640 * p_i + 6400 + CASE WHEN p_i >= c_spike THEN 262144 ELSE 0 END
                WHEN 'ZIGZAG' THEN 12800 + 1280 * p_i + CASE WHEN MOD(p_i, 2) = 0 THEN 2560 ELSE -2560 END
                WHEN 'PURGE'  THEN 1280 * p_i + 12800 - CASE WHEN p_i >= c_purge THEN c_purgeb ELSE 0 END
            END;
        END;
        FUNCTION med RETURN NUMBER IS v NUMBER;
        BEGIN
            SELECT AVG(x) INTO v
            FROM   (SELECT column_value AS x,
                           ROW_NUMBER() OVER (ORDER BY column_value) AS rn,
                           COUNT(*)     OVER ()                      AS c
                    FROM   TABLE(v_r))
            WHERE  rn IN (FLOOR((c + 1) / 2), CEIL((c + 1) / 2));
            RETURN v;
        END;
        PROCEDURE drift(p_k VARCHAR2, p_from PLS_INTEGER) IS
            n NUMBER; m NUMBER; s1 NUMBER := 0; s2 NUMBER := 0; sd NUMBER;
            se NUMBER; t NUMBER; ci NUMBER; half NUMBER; cur NUMBER; hr NUMBER;
        BEGIN
            v_r.DELETE;
            FOR i IN p_from + 1 .. c_nd LOOP
                v_r.EXTEND; v_r(v_r.COUNT) := val(p_k, i) - val(p_k, i - 1);
                s1 := s1 + v_r(v_r.COUNT);
            END LOOP;
            n  := v_r.COUNT;
            m  := med;
            FOR k IN 1 .. n LOOP s2 := s2 + POWER(v_r(k) - s1 / n, 2); END LOOP;
            sd   := SQRT(s2 / (n - 1));
            se   := sd / SQRT(n);
            t    := 1.96 + 2.4 / (n - 1);
            ci   := t * se;
            half := t * (sd * SQRT(30) + 30 * se);
            cur  := val(p_k, c_nd);
            hr   := c_50g - cur;
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_N',      n);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_SLOPE',  m);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_SD',     sd);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_CI',     ci);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_P30',    cur + m * 30);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_P30_LO', cur + m * 30 - half);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_P30_HI', cur + m * 30 + half);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_DTF',    FLOOR(hr / m));
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_DTF_LO', FLOOR(hr / (m + ci)));
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DR_' || p_k || '_DTF_HI',
                CASE WHEN m - ci > 0 THEN FLOOR(hr / (m - ci)) END);
            INSERT INTO cap_fixture_meta (mkey, sval) VALUES ('DR_' || p_k || '_Q',
                CASE WHEN m = 0 THEN 'FLAT' WHEN ABS(m) > ci THEN 'OK' ELSE 'LOW_CONFIDENCE' END);
        END;
        -- Backtest replay of FIX_ZIGZAG with slope p_slope, anchored at the
        -- cutoff day's actual (i = 92).
        PROCEDURE bt(p_tag VARCHAR2, p_slope NUMBER) IS
            mape NUMBER := 0; bias NUMBER := 0; y NUMBER; pred NUMBER;
        BEGIN
            FOR i IN 93 .. 120 LOOP
                y    := val('ZIGZAG', i);
                pred := val('ZIGZAG', 92) + p_slope * (i - 92);
                mape := mape + ABS(pred - y) / y;
                bias := bias + (pred - y) / y;
            END LOOP;
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_BT_' || p_tag || '_SLOPE', p_slope);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_BT_' || p_tag || '_MAPE', mape / 28 * 100);
            INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ZZ_BT_' || p_tag || '_BIAS', bias / 28 * 100);
        END;
    BEGIN
        drift('LINEAR', c_nd - 89);
        drift('SPIKE',  c_nd - 89);
        drift('ZIGZAG', c_nd - 89);
        drift('PURGE',  c_purge);
        -- Backtest DRIFT: median of the rates of i = 4 .. 92.
        v_r.DELETE;
        FOR i IN 4 .. 92 LOOP
            v_r.EXTEND; v_r(v_r.COUNT) := val('ZIGZAG', i) - val('ZIGZAG', i - 1);
        END LOOP;
        bt('DR', med);
        -- Backtest THEILSEN: median of the 4005 pairwise slopes of i = 3 .. 92.
        v_r.DELETE;
        FOR i IN 3 .. 91 LOOP
            FOR j IN i + 1 .. 92 LOOP
                v_r.EXTEND; v_r(v_r.COUNT) := (val('ZIGZAG', j) - val('ZIGZAG', i)) / (j - i);
            END LOOP;
        END LOOP;
        bt('TS', med);
    END;
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('Fixtures loaded: base=' || TO_CHAR(v_base,'YYYY-MM-DD')
        || ' restart=' || TO_CHAR(v_base + c_restart,'YYYY-MM-DD')
        || ' spike=' || TO_CHAR(v_base + c_spike,'YYYY-MM-DD')
        || ' inj_tue=' || TO_CHAR(v_base + v_inj,'YYYY-MM-DD Dy')
        || ' probe=' || TO_CHAR(v_base + v_probe,'YYYY-MM-DD Dy')
        || ' cpu_gap=' || TO_CHAR(v_base + v_cpugap,'YYYY-MM-DD Dy')
        || ' partial=' || TO_CHAR(v_base + v_partial,'YYYY-MM-DD Dy')
        || ' inverted_wed=' || TO_CHAR(v_base + v_invwed,'YYYY-MM-DD Dy'));
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
-- The redo counter also resets at the noon restart of the partial day, which
-- therefore reads 1 GiB over 12 h (is_complete = 'N').
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
    v_partial PLS_INTEGER;

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
    SELECT nval INTO v_probe   FROM cap_fixture_meta WHERE mkey = 'PROBE_DAY';
    SELECT nval INTO v_partial FROM cap_fixture_meta WHERE mkey = 'PARTIAL_DAY';

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
        IF i = v_partial THEN v_redo := 0; END IF;
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
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('REDO_PARTIAL_GB', 1);
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('M11 fixtures loaded: sessions 200..'
        || TO_CHAR(200 + 2 * c_nd) || ' of ' || TO_CHAR(c_sesslim)
        || ', processes 150 of ' || TO_CHAR(c_proclim)
        || ', redo 2 GiB/day, probe day index ' || TO_CHAR(v_probe));
END;
/

-- =====================================================================
-- Parameters, ASM diskgroups, TEMP / UNDO peaks (seam extensions).
-- =====================================================================
-- A separate block, like M11's: it only reuses the snapshot spine (2000+2i
-- ends 06:00, 2001+2i ends 18:00, no 06:00 snapshot on the restart day).
--
-- Closed forms (shipped knobs: train_days 90, series_sat_pct 90,
-- nearfull_warn_pct 90, nearfull_crit_pct 97, r2_gate 0.60):
--   PARAMETER  cpu_count 8 on every snapshot = NUM_CPUS, so cpu_ceiling = 8
--              and no db_cpu_pct moves. run_test.sql sets it to 4 on the
--              probe day (db_cpu_pct doubles there) and rolls back.
--              db_recovery_file_dest_size 100 GiB -> fra_size_gb 100 and
--              fra_days_at_cur = 100 / 2.0 GiB/day = 50.
--   ASM DATA   1000 GiB. Used 200 + 5*i GiB at 18:00, 197.5 + 5*i at 06:00,
--              so the day's last sample is 200 + 5*i: slope exactly 5,
--              cur 800 = 80% (under nearfull_warn_pct) and
--              days_to_limit = FLOOR((1000 * 0.90 - 800) / 5) = 20 -> CRIT.
--   ASM FRA    50 of 200 GiB on every sample -> FLAT, 25%.
--   FIX_TEMP   20 GiB allocated, maxsize 0 (limit = allocated). The day's
--              peak p(i) = 6 - i/64 GiB sits on the 06:00 sample (on the
--              restart day, which has no 06:00 snapshot, on the 18:00 one),
--              19.5 GiB on the last day. Every other sample reads 1 GiB, so
--              the last sample of the last day is 1 GiB and only a MAX finds
--              19.5. pct now 97.5 -> SERIES_NEARLIMIT CRIT. The OLS over
--              i = 31..120 is computed below: slope < 0 (no days_to_limit)
--              and R^2 about 0.005 (LOW_CONFIDENCE).
--   FIX_UNDO   4 GiB allocated, autoextend to 10 GiB (limit = maxsize).
--              1 GiB at 06:00, 3 GiB at 18:00 -> value 3 of 10, FLAT.
-- CAPD_TBSPC_DAILY excludes both by contents, so no tablespace number moves.
DECLARE
    c_dbid    CONSTANT NUMBER      := 42424242;
    c_con     CONSTANT NUMBER      := 42424242;
    c_inst    CONSTANT NUMBER      := 1;
    c_nd      CONSTANT PLS_INTEGER := 120;
    c_restart CONSTANT PLS_INTEGER := 60;
    c_bs      CONSTANT NUMBER      := 8192;
    c_gb      CONSTANT NUMBER      := 131072;          -- 1 GiB in 8 KiB blocks
    c_satpct  CONSTANT NUMBER      := 90;               -- shipped series_sat_pct
    c_r2gate  CONSTANT NUMBER      := 0.60;             -- shipped r2_gate
    -- 100 GiB as a bare NUMBER literal (100*1024*1024*1024 overflows
    -- PLS_INTEGER, see c_50g above).
    c_fra     CONSTANT NUMBER      := 107374182400;
    c_ncpu    CONSTANT NUMBER      := 8;
    c_asmtot  CONSTANT NUMBER      := 1024000;          -- DATA: 1000 GiB in MB
    c_frtot   CONSTANT NUMBER      := 204800;           -- FRA: 200 GiB in MB
    c_frused  CONSTANT NUMBER      := 51200;            -- FRA: 50 GiB in MB
    v_probe   PLS_INTEGER;
    -- temp_peak() is a local function, not callable inside SQL (PLS-00231).
    v_tcur    NUMBER;
    v_tprobe  NUMBER;

    -- FIX_TEMP's daily peak in blocks.
    FUNCTION temp_peak(p_i PLS_INTEGER) RETURN NUMBER IS
    BEGIN
        RETURN CASE WHEN p_i = c_nd THEN 39 * c_gb / 2 ELSE 6 * c_gb - 2048 * p_i END;
    END;
    PROCEDURE params(p_snap NUMBER) IS
        PROCEDURE one(p_name VARCHAR2, p_val NUMBER) IS
        BEGIN
            INSERT INTO cap_fixture_parameter
            VALUES (c_dbid, c_con, c_inst, p_snap, p_name, p_val);
        END;
    BEGIN
        one('cpu_count',                  c_ncpu);
        one('processes',                  300);          -- = the PROCESSES limit
        one('sessions',                   500);          -- = the SESSIONS limit
        one('db_recovery_file_dest_size', c_fra);
        one('sga_target',                 4294967296);
        one('sga_max_size',               4294967296);
        one('pga_aggregate_target',       1073741824);
        one('pga_aggregate_limit',        2147483648);
        one('memory_target',              0);
    END;
    PROCEDURE asm(p_snap NUMBER, p_data_gib NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_asm_diskgroup
        VALUES (c_dbid, c_con, p_snap, 'DATA', c_asmtot, c_asmtot - p_data_gib * 1024, NULL);
        INSERT INTO cap_fixture_asm_diskgroup
        VALUES (c_dbid, c_con, p_snap, 'FRA', c_frtot, c_frtot - c_frused, NULL);
    END;
    PROCEDURE tusage(p_snap NUMBER, p_ts NUMBER, p_size NUMBER, p_max NUMBER, p_used NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_tbspc_usage
        VALUES (c_dbid, c_con, p_snap, p_ts, p_size, p_max, p_used);
    END;
BEGIN
    SELECT nval INTO v_probe FROM cap_fixture_meta WHERE mkey = 'PROBE_DAY';

    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 24, 'FIX_TEMP', 'TEMPORARY', c_bs);
    INSERT INTO cap_fixture_tablespace VALUES (c_dbid, c_con, 25, 'FIX_UNDO', 'UNDO',      c_bs);
    -- An UNDO tablespace has datafiles. A TEMPORARY one has only tempfiles,
    -- which DBA_HIST_DATAFILE does not list, so FIX_TEMP gets no row.
    INSERT INTO cap_fixture_datafile   VALUES (c_dbid, c_con, 25, c_bs);

    FOR i IN 0 .. c_nd LOOP
        IF i <> c_restart THEN
            params(2000 + 2 * i);
            asm(2000 + 2 * i, 197.5 + 5 * i);
            tusage(2000 + 2 * i, 24, 20 * c_gb, 0,         temp_peak(i));
            tusage(2000 + 2 * i, 25,  4 * c_gb, 10 * c_gb, c_gb);
        END IF;
        params(2001 + 2 * i);
        asm(2001 + 2 * i, 200 + 5 * i);
        tusage(2001 + 2 * i, 24, 20 * c_gb, 0,
               CASE WHEN i = c_restart THEN temp_peak(i) ELSE c_gb END);
        tusage(2001 + 2 * i, 25,  4 * c_gb, 10 * c_gb, 3 * c_gb);
    END LOOP;

    -- ---- expected values for run_test.sql ----
    v_tcur   := temp_peak(c_nd);
    v_tprobe := temp_peak(v_probe);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_COUNT',      c_ncpu);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('CPU_COUNT_CAGED', c_ncpu / 2);
    -- Probe day under cpu_count 4: 400 s of DB CPU over 4 CPUs * 86400 s,
    -- and the 18:00 peak interval's 300 s over 4 * 43200 s.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_PCT_CAGED',      100 * 400 / (c_ncpu / 2 * 86400));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('DBCPU_PROBE_PEAK_PCT_CAGED', 100 * 300 / (c_ncpu / 2 * 43200));
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FRA_SIZE_GB', c_fra / 1073741824);       -- 100
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FRA_DAYS',    c_fra / 1073741824 / 2);   -- 50 (redo 2 GiB/day)
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_DATA_CUR',   200 + 5 * c_nd);        -- 800
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_DATA_LIMIT', c_asmtot / 1024);       -- 1000
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_DATA_SLOPE', 5);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_DATA_PCT',
        ROUND(100 * (200 + 5 * c_nd) / (c_asmtot / 1024), 1));                                  -- 80
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_DATA_DTL',
        FLOOR((c_asmtot / 1024 * c_satpct / 100 - (200 + 5 * c_nd)) / 5));                      -- 20
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_DATA_P30', 200 + 5 * c_nd + 5 * 30); -- 950
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_DATA_PROBE', 200 + 5 * v_probe);     -- last sample, not 06:00
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_FRA_CUR',    c_frused / 1024);       -- 50
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('ASM_FRA_LIMIT',  c_frtot / 1024);        -- 200
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('TEMP_CUR',   v_tcur / c_gb);             -- 19.5
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('TEMP_LIMIT', 20);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('TEMP_PCT',
        ROUND(100 * v_tcur / (20 * c_gb), 1));                                                  -- 97.5
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('TEMP_PROBE', v_tprobe / c_gb);           -- 06:00 peak
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('UNDO_CUR',   3);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('UNDO_LIMIT', 10);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('UNDO_PCT',   30);
    -- Sizing ask for FIX_FILLING (10 MiB/day = 1280 blocks/day from 12800
    -- blocks, 192000-block maxsize, zero residuals so the band collapses on
    -- the anchored line): need_h = (cur + h * slope - limit) / 2^30.
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FILLING_NEED_30',
        GREATEST(0, (1280 * c_nd + 12800 + 30  * 1280 - 192000) * c_bs) / 1073741824);    -- 0.09765625
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FILLING_NEED_90',
        GREATEST(0, (1280 * c_nd + 12800 + 90  * 1280 - 192000) * c_bs) / 1073741824);    -- 0.68359375
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FILLING_NEED_180',
        GREATEST(0, (1280 * c_nd + 12800 + 180 * 1280 - 192000) * c_bs) / 1073741824);    -- 1.5625
    -- FIX_TEMP's OLS over the forecast window, in GiB, i-space (day_n is i +
    -- a constant: slope and R^2 are shift-invariant).
    DECLARE
        n NUMBER := 0; sx NUMBER := 0; sy NUMBER := 0; sxx NUMBER := 0;
        sxy NUMBER := 0; syy NUMBER := 0; y NUMBER;
        bxx NUMBER; bxy NUMBER; byy NUMBER; slope NUMBER; r2 NUMBER;
    BEGIN
        FOR i IN c_nd - 89 .. c_nd LOOP
            y := temp_peak(i) / c_gb;
            n := n + 1; sx := sx + i; sy := sy + y;
            sxx := sxx + i * i; sxy := sxy + i * y; syy := syy + y * y;
        END LOOP;
        bxx   := sxx - sx * sx / n;
        bxy   := sxy - sx * sy / n;
        byy   := syy - sy * sy / n;
        slope := bxy / bxx;
        r2    := bxy * bxy / (bxx * byy);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('TEMP_SLOPE', slope);
        INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('TEMP_R2',    r2);
        INSERT INTO cap_fixture_meta (mkey, sval) VALUES ('TEMP_Q',
            CASE WHEN slope = 0 THEN 'FLAT' WHEN r2 < c_r2gate THEN 'LOW_CONFIDENCE' ELSE 'OK' END);
    END;
    COMMIT;

    DBMS_OUTPUT.PUT_LINE('Seam-extension fixtures loaded: cpu_count ' || c_ncpu
        || ', FRA 100 GiB, ASM DATA 200..' || TO_CHAR(200 + 5 * c_nd) || ' of 1000 GiB'
        || ', FIX_TEMP peak 19.5 of 20 GiB, FIX_UNDO 3 of 10 GiB');
END;
/

-- =====================================================================
-- Segment growth (CAPR_SEGMENT_GROWTH, report/drill_tbspc.sql).
-- =====================================================================
-- FIX_FILLING grows 10 MiB a day. Three segments take that growth at every
-- 18:00 snapshot (2001 + 2i, i = 0 .. 120, one per day): APP.ORDERS 7 MiB
-- (70%), APP.ORDERS_PK 2 MiB (20%) and APP.EVENTS partition P1 1 MiB (10%).
-- space_used_delta is half of space_allocated_delta. One FIX_LINEAR segment
-- (APP.LEDGER, 10 MiB a day) proves the shares are per tablespace. Rows
-- exist on every day, so the seg_window_days (28) window holds exactly 28
-- of them: closed forms 28 x 7 / 2 / 1 MiB and 28 x 10 MiB.
DECLARE
    c_mib CONSTANT NUMBER := 1048576;
    PROCEDURE seg(p_snap NUMBER, p_ts NUMBER, p_tsname VARCHAR2, p_obj VARCHAR2,
                  p_sub VARCHAR2, p_type VARCHAR2, p_alloc NUMBER) IS
    BEGIN
        INSERT INTO cap_fixture_seg_stat
        VALUES (42424242, 42424242, 1, p_snap, p_ts, p_tsname, 'APP', p_obj, p_sub, p_type,
                p_alloc / 2, p_alloc);
    END;
BEGIN
    FOR i IN 0 .. 120 LOOP
        seg(2001 + 2 * i, 15, 'FIX_FILLING', 'ORDERS',    NULL, 'TABLE',           7 * c_mib);
        seg(2001 + 2 * i, 15, 'FIX_FILLING', 'ORDERS_PK', NULL, 'INDEX',           2 * c_mib);
        seg(2001 + 2 * i, 15, 'FIX_FILLING', 'EVENTS',    'P1', 'TABLE PARTITION', 1 * c_mib);
        seg(2001 + 2 * i, 10, 'FIX_LINEAR',  'LEDGER',    NULL, 'TABLE',          10 * c_mib);
    END LOOP;
    DELETE FROM cap_fixture_meta WHERE mkey LIKE 'SEG!_%' ESCAPE '!';
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SEG_WINDOW_DAYS', 28);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SEG_ORDERS_BYTES',    28 * 7 * c_mib);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SEG_ORDERS_PK_BYTES', 28 * 2 * c_mib);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SEG_EVENTS_BYTES',    28 * 1 * c_mib);
    INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('SEG_LEDGER_BYTES',    28 * 10 * c_mib);
    COMMIT;
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

-- The per-tablespace alert thresholds, added the same way ddl/05_config.sql
-- adds them (a table from an older install gains them here first, because
-- the FIX_FILLING row below sets two of them).
DECLARE
    PROCEDURE add_col(p_def VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE cap_tbspc_override ADD (' || p_def || ')';
    EXCEPTION
        WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
    END;
BEGIN
    add_col('dtf_warn NUMBER');
    add_col('dtf_crit NUMBER');
    add_col('nearfull_warn_pct NUMBER');
    add_col('nearfull_crit_pct NUMBER');
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

-- FIX_OVERFULL: a ceiling UNDER the current usage (1 GiB vs 1.5 GiB used).
INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note)
VALUES (42424242, 42424242, 'FIX_OVERFULL', 1073741824, 'N',
        'Clamp fixture: ceiling below the used size.');

-- Pure WILDCARD row (any dbid, any con_dbid): exercises the "fleet-wide rule"
-- matching path as well as exclude_flag.
INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note)
VALUES (0, 0, 'FIX_EXCLUDED', NULL, 'Y',
        'M9.5: scratch tablespace -- excluded from every layer.');

-- Per-tablespace thresholds: FIX_FILLING (days_to_full 20) gets dtf_crit 25
-- and dtf_warn 60 and no ceiling, so its TBSPC_FULL stays CRIT but against
-- 25 (threshold) / 60 (alarm_threshold) instead of the knobs' 30 / 90, and
-- its limit_source stays AUTOEXTEND. FIX_OVERRIDE's rows above set no
-- threshold column, so the knobs keep applying to it.
INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag, note,
                                dtf_warn, dtf_crit)
VALUES (42424242, 42424242, 'FIX_FILLING', NULL, 'N',
        'Per-tablespace thresholds: dtf_crit 25, dtf_warn 60.', 60, 25);
DELETE FROM cap_fixture_meta WHERE mkey IN ('FILLING_OVR_DTF_WARN', 'FILLING_OVR_DTF_CRIT', 'DROPPED_DTF');
INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FILLING_OVR_DTF_WARN', 60);
INSERT INTO cap_fixture_meta (mkey, nval) VALUES ('FILLING_OVR_DTF_CRIT', 25);
-- FIX_DROPPED is FIX_LINEAR's series cut 30 days short: 10 MiB/day against
-- the same 50 GiB maxsize from DROPPED_CUR, so FLOOR((50 GiB - DROPPED_CUR)
-- / 10 MiB) = LINEAR_DTF + 30 = 5020 days. Inside dtf_warn = 7000 it would
-- alert, but it is not current (the CAPR_SEVERITY gate).
INSERT INTO cap_fixture_meta (mkey, nval)
SELECT 'DROPPED_DTF', FLOOR((53687091200 - nval) / 10485760)
FROM   cap_fixture_meta WHERE mkey = 'DROPPED_CUR';

COMMIT;

PROMPT Fixtures installed.  Next: @install.sql (seam_mode=fixture), then test/run_test.sql
