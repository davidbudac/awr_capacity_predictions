--
-- ddl/05_config.sql -- CAP_CONFIG name/value tuning table + idempotent seed.
-- =====================================================================
-- An operator table, like CAP_TBSPC_OVERRIDE (bottom of this file): both
-- survive every re-install. The suite's other persisted tables are the
-- CAP_ML_MODEL registry (ddl/50) and the results cache (ddl/60).
-- Every analytic view reads its knobs through the one-row view CAP_CFG
-- (below), so tuning the toolkit never requires editing SQL -- just UPDATE a
-- value.
--
-- All values are numeric (NUMBER). Byte thresholds are in bytes, day windows
-- in days, percentages in whole percent. The MERGE below is re-runnable: it
-- inserts any missing key, refreshes cfg_default and cfg_desc, and never
-- touches cfg_value, so a re-install never clobbers an operator's tuning.
-- The one exception is suite_version, which is not a knob (see the MERGE).
-- To reset a key to its shipped default:
--   UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = '...'
-- Do not DELETE a key: every view that reads it then returns no rows or NULLs.
-- SELECT * FROM cap_cfg_check WHERE status <> 'OK' lists missing knobs and
-- values that break a range rule.
--
SET DEFINE OFF

-- Idempotent create: on a re-install the table already exists (00_drop no longer
-- drops it, so operator overrides survive). Swallow ORA-00955 (name already used)
-- and keep the existing rows; the MERGE below then adds only missing keys.
DECLARE
BEGIN
    EXECUTE IMMEDIATE 'CREATE TABLE cap_config (
        cfg_name   VARCHAR2(40)  CONSTRAINT cap_config_pk PRIMARY KEY,
        cfg_value  NUMBER        NOT NULL,
        cfg_desc   VARCHAR2(200),
        cfg_default NUMBER
    )';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

-- Installs that predate cfg_default get the column here. ORA-01430 = the
-- column already exists (fresh install, or a re-install).
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE cap_config ADD (cfg_default NUMBER)';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

COMMENT ON TABLE  cap_config             IS 'AWR capacity toolkit tuning knobs (name/value). Views read them through the one-row view CAP_CFG.';
COMMENT ON COLUMN cap_config.cfg_name    IS 'Knob name (primary key).';
COMMENT ON COLUMN cap_config.cfg_value   IS 'Numeric value. Units per cfg_desc (bytes / days / whole percent / ratio).';
COMMENT ON COLUMN cap_config.cfg_desc    IS 'Human description incl. units.';
COMMENT ON COLUMN cap_config.cfg_default IS 'Shipped default, refreshed on every install. Reset a knob with UPDATE cap_config SET cfg_value = cfg_default.';

-- M15 renames: the min-history knobs belong to the baseline MODE now, not to
-- the series family. Carry an operator's value over to the new name BEFORE
-- the seed MERGE (which would otherwise insert the shipped default), then
-- retire the old key. Re-runnable: once the old keys are gone the scalar
-- subqueries return NULL and the INSERT's WHERE makes the MERGE a no-op.
MERGE INTO cap_config c
USING (
    SELECT 'trailing_min_hist' AS cfg_name,
           (SELECT cfg_value FROM cap_config WHERE cfg_name = 'tbspc_min_hist') AS v
    FROM   dual
    UNION ALL
    SELECT 'weekly_min_hist',
           (SELECT cfg_value FROM cap_config WHERE cfg_name = 'cpu_min_dow_hist')
    FROM   dual
) s
ON (c.cfg_name = s.cfg_name)
WHEN NOT MATCHED THEN
    INSERT (cfg_name, cfg_value, cfg_desc) VALUES (s.cfg_name, s.v, 'carried over')
    WHERE s.v IS NOT NULL;
DELETE FROM cap_config WHERE cfg_name IN ('tbspc_min_hist', 'cpu_min_dow_hist');

-- Idempotent seed. A missing key is inserted with cfg_value = cfg_default =
-- the shipped value. An existing key gets only cfg_default and cfg_desc
-- refreshed, so an operator's cfg_value survives every re-install.
MERGE INTO cap_config c
USING (
    SELECT 'train_days'          AS cfg_name, 90        AS cfg_default, 'Length of the primary linear-fit training window (days).'                              AS cfg_desc FROM dual
    UNION ALL SELECT 'recent_days',          28,        'Length of the secondary "recent" fit window for acceleration detection (days).'                       FROM dual
    UNION ALL SELECT 'min_train_days',       14,        'Minimum REGR_COUNT before a forecast is trusted; below this quality=INSUFFICIENT_HISTORY.'            FROM dual
    UNION ALL SELECT 'r2_gate',              0.60,      'REGR_R2 below this marks a forecast LOW_CONFIDENCE.'                                                   FROM dual
    UNION ALL SELECT 'mad_k',                3,         'MAD multiplier k: |value-median| > k*MAD_sigma flags an anomaly.'                                     FROM dual
    UNION ALL SELECT 'mad_window_days',      28,        'Trailing window length for the rolling median/MAD baseline (days).'                                   FROM dual
    UNION ALL SELECT 'anomaly_report_days',  14,        'Trailing-days window of anomalies CAPR_ALERTS raises (the report''s own window is the anomaly_days DEFINE).' FROM dual
    UNION ALL SELECT 'cpu_sat_pct',          80,        'CPU busy percent treated as saturated for days-to-saturation.'                                        FROM dual
    UNION ALL SELECT 'abs_floor_bytes',      104857600, 'Absolute floor (100 MiB) for tablespace-delta anomaly threshold; guards flat baselines (MAD=0).'      FROM dual
    UNION ALL SELECT 'dow_weeks',            8,         'Weeks of history (ts - 7k, k = 1..dow_weeks) forming the SAME_DOW and HOUR_OF_WEEK anomaly baselines.' FROM dual
    UNION ALL SELECT 'dtf_warn',             90,        'days_to_full at/below this = WARN in the report.'                                                      FROM dual
    UNION ALL SELECT 'dtf_crit',             30,        'days_to_full at/below this = CRIT in the report.'                                                      FROM dual
    UNION ALL SELECT 'trailing_min_hist',    7,         'M15: minimum baseline observations before a TRAILING anomaly can flag (any series).'                   FROM dual
    UNION ALL SELECT 'cpu_min_mad_pct',      3,         'Floor (whole percent) on CPU MAD_sigma so an exactly-flat seasonal baseline still flags a real jump.' FROM dual
    UNION ALL SELECT 'weekly_min_hist',      3,         'M15: minimum baseline observations before a SAME_DOW or HOUR_OF_WEEK anomaly can flag.'                FROM dual
    UNION ALL SELECT 'esm_prediction_step',  30,        'OML ESM forecast horizon in steps (days). Oracle 19c hard-caps this at 30.'                            FROM dual
    UNION ALL SELECT 'esm_tbspc_model',       2,        'ESM model type for tablespaces: 0=EXSM_HOLT, 1=EXSM_ADDWINTERS(7), 2=AUTO (pick by backtest MAPE).'     FROM dual
    UNION ALL SELECT 'esm_select_by_backtest',1,        '1 = AUTO trains both candidate backtest twins per tablespace and keeps the lower-MAPE one; 0 = AUTO falls back to EXSM_HOLT.' FROM dual
    UNION ALL SELECT 'nearfull_warn_pct',    90,        'Percent-used at/above which a tablespace raises a near-full-now WARN (any forecast quality).'          FROM dual
    UNION ALL SELECT 'nearfull_crit_pct',    97,        'Percent-used at/above which a tablespace raises a near-full-now CRIT (any forecast quality).'          FROM dual
    UNION ALL SELECT 'peak_hour_from',        8,         'Peak window start (hour of day, exclusive). A snapshot interval is "peak" when its end time falls in (from, to].' FROM dual
    UNION ALL SELECT 'peak_hour_to',          18,        'Peak window end (hour of day, inclusive). See peak_hour_from.'                                          FROM dual
    UNION ALL SELECT 'cpu_sat_on_p95',        1,         '1 = CPU_SAT alerts key off the BUSY_P95 (per-snapshot p95) trend; 0 = off the daily-average BUSY_PCT trend.' FROM dual
    UNION ALL SELECT 'backtest_holdout_days',28,        'Holdout window (days) CAPF_BACKTEST fits before and scores against; <=30 lets ESM cover it on 19c.'    FROM dual
    UNION ALL SELECT 'report_min_gb',         1,        'Report sections 2/6a print a tablespace only if it is growing, near-full, or at least this many GiB used.' FROM dual
    UNION ALL SELECT 'accel_slope_floor_bpd', 1048576,  'Minimum |slope| (bytes/day, default 1 MiB) before accel_ratio is computed; below it a near-flat series gets NULL.' FROM dual
    UNION ALL SELECT 'slope_method',           0,        'Slope estimator for the CAPF_* fits. NUMERIC ENCODING: 0 = OLS (REGR_SLOPE, default), 1 = THEILSEN (median pairwise slope), 2 = DRIFT (median day-over-day rate, random-walk bands).' FROM dual
    UNION ALL SELECT 'reset_on_shrink',        1,        'M9.3: 1 = restart a tablespace training window at the most recent large negative used_bytes step (post-purge fit); 0 = fit across the cliff.' FROM dual
    UNION ALL SELECT 'shrink_mad_k',           6,        'M9.3 MAD multiplier: a daily delta below -GREATEST(k*MAD_sigma of the window deltas, abs_floor_bytes) is a shrink change-point.' FROM dual
    UNION ALL SELECT 'cpu_gap_hours',          12,       'M10.5: a snapshot interval LONGER than this many hours is an AWR gap/downtime. Its day gets gap_flag=Y, is skipped by the CPU anomaly + shift baselines, and is left out of busy_p95/max/peak.' FROM dual
    UNION ALL SELECT 'shift_days',              7,       'M10.3: length of the RECENT window (days) whose median CAPA_CPU_SHIFT compares against the baseline; also the N of the N-of-M rule.' FROM dual
    UNION ALL SELECT 'shift_baseline_days',    28,       'M10.3: length of the BASELINE window (days) immediately before the recent window.'                                                   FROM dual
    UNION ALL SELECT 'shift_min_pct',          15,       'M10.3: minimum |recent median - baseline median|, in percentage POINTS, before a level shift is flagged.'                            FROM dual
    UNION ALL SELECT 'series_sat_pct',         90,        'M11: percent of a fixed-ceiling series'' limit (processes/sessions, DB size) treated as saturated for days_to_limit.' FROM dual
    UNION ALL SELECT 'esm_max_age_days',        7,        'Tier 2: an ESM model trained more than this many days before its series'' last day is stale; CAPF_COMPARE drops it.' FROM dual
    UNION ALL SELECT 'esm_auto_tie_pct',        0.25,     'Tier 2 AUTO: candidate MAPEs closer than this many percentage points tie and EXSM_HOLT is kept (chosen_by AUTO_TIE).' FROM dual
    UNION ALL SELECT 'complete_day_pct',       80,        'Percent of a day (86400 s) of valid counter intervals a CPU / DB time / redo day needs for is_complete = Y. Partial, restart and outage days fall below it.' FROM dual
    UNION ALL SELECT 'cyclic_min_cliffs',       2,        'A tablespace with at least this many shrink cliffs (the M9.3 rule) in its train_days window is graded CYCLIC and judged on its peaks. 0 = off (M9.3 reset only).' FROM dual
    UNION ALL SELECT 'cpu_quality_gate',        1,        'CAPF_CPU_TREND quality gate: 1 = OK when |slope| > slope CI (slope significance), 0 = legacy R2 >= r2_gate.' FROM dual
    UNION ALL SELECT 'cpu_deseason',            1,        'CAPF_CPU_TREND: 1 = subtract the weekday / weekend mean (and add back the window mean) before the fit, 0 = fit the raw daily values.' FROM dual
    UNION ALL SELECT 'stale_days',              3,        'A CAPF_* series whose last_day is more than this many days before the newest day of its daily source (same dbid) reads is_current = N: dropped tablespace, retired DBID, stopped collection.' FROM dual
    UNION ALL SELECT 'suite_version',          22,        'Suite release that built these objects (latest PLAN.md milestone). Set by every install; not a tuning knob.' FROM dual
    UNION ALL SELECT 'cpu_min_mad_pct_hour',    5,        'M15: cpu_min_mad_pct for HOUR-grain CPU (HOUR_OF_WEEK): hourly values are noisier than daily averages.' FROM dual
    UNION ALL SELECT 'hour_gap_ratio',        1.5,        'M15: an interval <= 0 h or longer than LEAST(cpu_gap_hours, this x the instance''s median interval) is a gap at HOUR grain.' FROM dual
    UNION ALL SELECT 'series_floor_count',     10,        'M15: anomaly threshold floor for COUNT series (PROCESSES/SESSIONS), in sessions/processes.' FROM dual
    UNION ALL SELECT 'series_floor_gib',      0.5,        'M15: anomaly threshold floor (GiB/day) for GIB_PER_DAY series (REDO_GB_DAY level, DB_SIZE_GB growth).' FROM dual
    UNION ALL SELECT 'alert_modes_tbspc',       1,        'M15 BITMASK of baseline modes raising TBSPC_ANOM: 1=TRAILING 2=SAME_DOW 4=HOUR_OF_WEEK (sum them), 0=none.' FROM dual
    UNION ALL SELECT 'alert_modes_cpu',         2,        'M15 BITMASK of baseline modes raising CPU_ANOM and DBCPU_ANOM: 1=TRAILING 2=SAME_DOW 4=HOUR_OF_WEEK, 0=none.' FROM dual
    UNION ALL SELECT 'alert_modes_series',      1,        'M15 BITMASK of baseline modes raising SERIES_ANOM: 1=TRAILING 2=SAME_DOW (4 has no effect: day grain only).' FROM dual
    UNION ALL SELECT 'stale_hours',            36,        'CAPR_ALERTS raises DATA_STALE for a dbid whose newest AWR snapshot ended at least this many hours before SYSDATE (the dead-man check).' FROM dual
    UNION ALL SELECT 'data_stale_max_days',    14,        'A dbid whose newest AWR snapshot is at least this many days old is retired: no DATA_STALE alert, listed in CAPR_COVERAGE with retired = Y.' FROM dual
    UNION ALL SELECT 'resolve_grace_runs',      2,        'Results layer: consecutive refresh runs an OPEN alert must be missing from CAPR_ALERTS before CAP_RESULTS.refresh marks it RESOLVED.' FROM dual
    UNION ALL SELECT 'refresh_stale_hours',    36,        'Results layer: CAPR_RUNS.stale_run = Y when the last OK live refresh run ended at least this many hours ago, or none ever did.' FROM dual
    UNION ALL SELECT 'digest_days',             7,        'Results layer: CAPR_WEEKLY_DIGEST compares the latest run with the latest run whose as_of_day is at least this many days earlier.' FROM dual
    UNION ALL SELECT 'seg_window_days',        28,        'CAPR_SEGMENT_GROWTH: trailing days (up to the dbid''s newest snapshot) over which segment growth is summed for the "who is filling it" ranking.' FROM dual
    UNION ALL SELECT 'anomaly_hour_grain',      1,        'CAPA_OBS: 1 = score CPU per hour too (HOUR_OF_WEEK), 0 = day grain only: no HOUR rows, so no hourly anomalies, alerts or ring tooltips (cheaper on long hourly AWR).' FROM dual
) s
ON (c.cfg_name = s.cfg_name)
WHEN MATCHED THEN
    -- suite_version records which release built the objects, so every install
    -- overwrites its cfg_value. Bump it here and in CAP_CFG_CHECK together.
    UPDATE SET c.cfg_value   = CASE WHEN c.cfg_name = 'suite_version' THEN s.cfg_default ELSE c.cfg_value END,
               c.cfg_default = s.cfg_default,
               c.cfg_desc    = s.cfg_desc
WHEN NOT MATCHED THEN
    INSERT (cfg_name, cfg_value, cfg_default, cfg_desc)
    VALUES (s.cfg_name, s.cfg_default, s.cfg_default, s.cfg_desc);

COMMIT;

-- =====================================================================
-- CAP_CFG -- the one config access path: one row, one column per knob.
-- =====================================================================
-- Every analytic view CROSS JOINs this view (alias cfg) instead of pivoting
-- cap_config itself. A deleted key reads NULL here, and a NULL knob makes
-- predicates such as day_dt > last_day - cfg.train_days silently false, so
-- CAP_CFG_CHECK below reports it as MISSING. No defaults are inlined: the
-- shipped values live only in the MERGE above. A new knob needs a MERGE row,
-- a column here and an entry in CAP_CFG_CHECK's UNPIVOT list.
CREATE OR REPLACE VIEW cap_cfg AS
SELECT MAX(CASE WHEN cfg_name = 'train_days'             THEN cfg_value END) AS train_days,
       MAX(CASE WHEN cfg_name = 'recent_days'            THEN cfg_value END) AS recent_days,
       MAX(CASE WHEN cfg_name = 'min_train_days'         THEN cfg_value END) AS min_train_days,
       MAX(CASE WHEN cfg_name = 'r2_gate'                THEN cfg_value END) AS r2_gate,
       MAX(CASE WHEN cfg_name = 'mad_k'                  THEN cfg_value END) AS mad_k,
       MAX(CASE WHEN cfg_name = 'mad_window_days'        THEN cfg_value END) AS mad_window_days,
       MAX(CASE WHEN cfg_name = 'anomaly_report_days'    THEN cfg_value END) AS anomaly_report_days,
       MAX(CASE WHEN cfg_name = 'cpu_sat_pct'            THEN cfg_value END) AS cpu_sat_pct,
       MAX(CASE WHEN cfg_name = 'abs_floor_bytes'        THEN cfg_value END) AS abs_floor_bytes,
       MAX(CASE WHEN cfg_name = 'dow_weeks'              THEN cfg_value END) AS dow_weeks,
       MAX(CASE WHEN cfg_name = 'dtf_warn'               THEN cfg_value END) AS dtf_warn,
       MAX(CASE WHEN cfg_name = 'dtf_crit'               THEN cfg_value END) AS dtf_crit,
       MAX(CASE WHEN cfg_name = 'trailing_min_hist'      THEN cfg_value END) AS trailing_min_hist,
       MAX(CASE WHEN cfg_name = 'cpu_min_mad_pct'        THEN cfg_value END) AS cpu_min_mad_pct,
       MAX(CASE WHEN cfg_name = 'weekly_min_hist'        THEN cfg_value END) AS weekly_min_hist,
       MAX(CASE WHEN cfg_name = 'esm_prediction_step'    THEN cfg_value END) AS esm_prediction_step,
       MAX(CASE WHEN cfg_name = 'esm_tbspc_model'        THEN cfg_value END) AS esm_tbspc_model,
       MAX(CASE WHEN cfg_name = 'esm_select_by_backtest' THEN cfg_value END) AS esm_select_by_backtest,
       MAX(CASE WHEN cfg_name = 'nearfull_warn_pct'      THEN cfg_value END) AS nearfull_warn_pct,
       MAX(CASE WHEN cfg_name = 'nearfull_crit_pct'      THEN cfg_value END) AS nearfull_crit_pct,
       MAX(CASE WHEN cfg_name = 'peak_hour_from'         THEN cfg_value END) AS peak_hour_from,
       MAX(CASE WHEN cfg_name = 'peak_hour_to'           THEN cfg_value END) AS peak_hour_to,
       MAX(CASE WHEN cfg_name = 'cpu_sat_on_p95'         THEN cfg_value END) AS cpu_sat_on_p95,
       MAX(CASE WHEN cfg_name = 'backtest_holdout_days'  THEN cfg_value END) AS backtest_holdout_days,
       MAX(CASE WHEN cfg_name = 'report_min_gb'          THEN cfg_value END) AS report_min_gb,
       MAX(CASE WHEN cfg_name = 'accel_slope_floor_bpd'  THEN cfg_value END) AS accel_slope_floor_bpd,
       MAX(CASE WHEN cfg_name = 'slope_method'           THEN cfg_value END) AS slope_method,
       MAX(CASE WHEN cfg_name = 'reset_on_shrink'        THEN cfg_value END) AS reset_on_shrink,
       MAX(CASE WHEN cfg_name = 'shrink_mad_k'           THEN cfg_value END) AS shrink_mad_k,
       MAX(CASE WHEN cfg_name = 'cpu_gap_hours'          THEN cfg_value END) AS cpu_gap_hours,
       MAX(CASE WHEN cfg_name = 'shift_days'             THEN cfg_value END) AS shift_days,
       MAX(CASE WHEN cfg_name = 'shift_baseline_days'    THEN cfg_value END) AS shift_baseline_days,
       MAX(CASE WHEN cfg_name = 'shift_min_pct'          THEN cfg_value END) AS shift_min_pct,
       MAX(CASE WHEN cfg_name = 'series_sat_pct'         THEN cfg_value END) AS series_sat_pct,
       MAX(CASE WHEN cfg_name = 'esm_max_age_days'       THEN cfg_value END) AS esm_max_age_days,
       MAX(CASE WHEN cfg_name = 'esm_auto_tie_pct'       THEN cfg_value END) AS esm_auto_tie_pct,
       MAX(CASE WHEN cfg_name = 'complete_day_pct'       THEN cfg_value END) AS complete_day_pct,
       MAX(CASE WHEN cfg_name = 'stale_days'             THEN cfg_value END) AS stale_days,
       MAX(CASE WHEN cfg_name = 'cyclic_min_cliffs'      THEN cfg_value END) AS cyclic_min_cliffs,
       MAX(CASE WHEN cfg_name = 'cpu_quality_gate'       THEN cfg_value END) AS cpu_quality_gate,
       MAX(CASE WHEN cfg_name = 'cpu_deseason'           THEN cfg_value END) AS cpu_deseason,
       MAX(CASE WHEN cfg_name = 'suite_version'          THEN cfg_value END) AS suite_version,
       MAX(CASE WHEN cfg_name = 'cpu_min_mad_pct_hour'   THEN cfg_value END) AS cpu_min_mad_pct_hour,
       MAX(CASE WHEN cfg_name = 'hour_gap_ratio'         THEN cfg_value END) AS hour_gap_ratio,
       MAX(CASE WHEN cfg_name = 'series_floor_count'     THEN cfg_value END) AS series_floor_count,
       MAX(CASE WHEN cfg_name = 'series_floor_gib'       THEN cfg_value END) AS series_floor_gib,
       MAX(CASE WHEN cfg_name = 'alert_modes_tbspc'      THEN cfg_value END) AS alert_modes_tbspc,
       MAX(CASE WHEN cfg_name = 'alert_modes_cpu'        THEN cfg_value END) AS alert_modes_cpu,
       MAX(CASE WHEN cfg_name = 'alert_modes_series'     THEN cfg_value END) AS alert_modes_series,
       MAX(CASE WHEN cfg_name = 'stale_hours'            THEN cfg_value END) AS stale_hours,
       MAX(CASE WHEN cfg_name = 'data_stale_max_days'    THEN cfg_value END) AS data_stale_max_days,
       MAX(CASE WHEN cfg_name = 'resolve_grace_runs'     THEN cfg_value END) AS resolve_grace_runs,
       MAX(CASE WHEN cfg_name = 'refresh_stale_hours'    THEN cfg_value END) AS refresh_stale_hours,
       MAX(CASE WHEN cfg_name = 'digest_days'            THEN cfg_value END) AS digest_days,
       MAX(CASE WHEN cfg_name = 'seg_window_days'        THEN cfg_value END) AS seg_window_days,
       MAX(CASE WHEN cfg_name = 'anomaly_hour_grain'     THEN cfg_value END) AS anomaly_hour_grain
FROM   cap_config;

COMMENT ON TABLE cap_cfg IS 'One row, one NUMBER column per CAP_CONFIG knob (column name = knob name). NULL = the knob row is missing.';

-- =====================================================================
-- CAP_CFG_CHECK -- one row per knob: value, OK / MISSING / BAD, reason.
-- =====================================================================
-- A cross-knob rule is reported on the knob named first in it.
CREATE OR REPLACE VIEW cap_cfg_check AS
WITH u AS (
        SELECT CAST(LOWER(knob) AS VARCHAR2(40)) AS knob, value
        FROM   cap_cfg
        UNPIVOT INCLUDE NULLS (value FOR knob IN (
               train_days, recent_days, min_train_days, r2_gate, mad_k,
               mad_window_days, anomaly_report_days, cpu_sat_pct, abs_floor_bytes,
               dow_weeks, dtf_warn, dtf_crit, trailing_min_hist, cpu_min_mad_pct,
               weekly_min_hist, esm_prediction_step, esm_tbspc_model,
               esm_select_by_backtest, nearfull_warn_pct, nearfull_crit_pct,
               peak_hour_from, peak_hour_to, cpu_sat_on_p95, backtest_holdout_days,
               report_min_gb, accel_slope_floor_bpd, slope_method, reset_on_shrink,
               shrink_mad_k, cpu_gap_hours, shift_days, shift_baseline_days,
               shift_min_pct, series_sat_pct, esm_max_age_days, esm_auto_tie_pct,
               complete_day_pct, stale_days, cyclic_min_cliffs, cpu_quality_gate,
               cpu_deseason, suite_version,
               cpu_min_mad_pct_hour, hour_gap_ratio,
               series_floor_count, series_floor_gib, alert_modes_tbspc,
               alert_modes_cpu, alert_modes_series, stale_hours,
               data_stale_max_days, resolve_grace_runs, refresh_stale_hours,
               digest_days, seg_window_days, anomaly_hour_grain))
     ),
     r AS (
        SELECT u.knob, u.value,
               CASE
                   WHEN u.value IS NULL AND u.knob = 'suite_version'
                        THEN 'not stamped: re-run install.sql'
                   WHEN u.value IS NULL
                        THEN 'no CAP_CONFIG row: views that read it return no rows or NULLs. Re-run ddl/05_config.sql to re-seed it.'
                   WHEN u.knob = 'recent_days'         AND u.value > c.train_days
                        THEN 'must be <= train_days (' || c.train_days || ')'
                   WHEN u.knob = 'min_train_days'      AND u.value < 14
                        THEN 'must be >= 14: the interval t approximation needs df >= 12'
                   WHEN u.knob = 'dtf_crit'            AND u.value > c.dtf_warn
                        THEN 'must be <= dtf_warn (' || c.dtf_warn || ')'
                   WHEN u.knob = 'nearfull_warn_pct'   AND u.value > c.nearfull_crit_pct
                        THEN 'must be <= nearfull_crit_pct (' || c.nearfull_crit_pct || ')'
                   WHEN u.knob = 'trailing_min_hist'   AND u.value > c.mad_window_days
                        THEN 'must be <= mad_window_days (' || c.mad_window_days || '): the TRAILING window holds at most that many days'
                   WHEN u.knob = 'weekly_min_hist'     AND u.value > c.dow_weeks
                        THEN 'must be <= dow_weeks (' || c.dow_weeks || '): the weekly baselines hold at most that many observations'
                   WHEN u.knob = 'hour_gap_ratio'      AND u.value <= 0
                        THEN 'must be > 0'
                   WHEN u.knob IN ('alert_modes_tbspc', 'alert_modes_cpu', 'alert_modes_series')
                        AND (u.value <> TRUNC(u.value) OR u.value NOT BETWEEN 0 AND 7)
                        THEN 'must be a bitmask 0..7: 1=TRAILING 2=SAME_DOW 4=HOUR_OF_WEEK'
                   WHEN u.knob = 'shift_days'          AND u.value > c.shift_baseline_days
                        THEN 'must be <= shift_baseline_days (' || c.shift_baseline_days || ')'
                   WHEN u.knob = 'esm_prediction_step' AND u.value NOT BETWEEN 1 AND 30
                        THEN 'must be between 1 and 30: Oracle 19c caps the ESM horizon at 30'
                   WHEN u.knob = 'slope_method'        AND u.value NOT IN (0, 1, 2)
                        THEN 'must be 0 (OLS), 1 (THEILSEN) or 2 (DRIFT)'
                   WHEN u.knob = 'esm_tbspc_model'     AND u.value NOT IN (0, 1, 2)
                        THEN 'must be 0 (HOLT), 1 (ADDWINTERS) or 2 (AUTO)'
                   WHEN u.knob = 'esm_max_age_days'    AND u.value < 0
                        THEN 'must be >= 0'
                   WHEN u.knob = 'esm_auto_tie_pct'    AND u.value < 0
                        THEN 'must be >= 0'
                   WHEN u.knob = 'complete_day_pct'    AND u.value NOT BETWEEN 1 AND 100
                        THEN 'must be between 1 and 100 (percent of a day)'
                   WHEN u.knob IN ('stale_days', 'stale_hours') AND u.value < 0
                        THEN 'must be >= 0'
                   WHEN u.knob = 'data_stale_max_days' AND u.value * 24 <= c.stale_hours
                        THEN 'must be more than stale_hours (' || c.stale_hours || ') / 24, or DATA_STALE can never fire'
                   WHEN u.knob = 'resolve_grace_runs'  AND (u.value <> TRUNC(u.value) OR u.value < 1)
                        THEN 'must be a whole number >= 1'
                   WHEN u.knob = 'refresh_stale_hours' AND u.value <= 0
                        THEN 'must be > 0'
                   WHEN u.knob = 'digest_days'         AND (u.value <> TRUNC(u.value) OR u.value < 1)
                        THEN 'must be a whole number >= 1'
                   WHEN u.knob = 'seg_window_days'     AND (u.value <> TRUNC(u.value) OR u.value < 1)
                        THEN 'must be a whole number >= 1'
                   WHEN u.knob = 'anomaly_hour_grain'  AND u.value NOT IN (0, 1)
                        THEN 'must be 0 (day grain only) or 1 (score hours too)'
                   WHEN u.knob = 'cyclic_min_cliffs'   AND (u.value <> TRUNC(u.value) OR u.value = 1 OR u.value < 0)
                        THEN 'must be 0 (off) or a whole number >= 2: one cliff is a purge, the M9.3 reset handles it'
                   WHEN u.knob = 'cpu_quality_gate'    AND u.value NOT IN (0, 1)
                        THEN 'must be 0 (R2 gate) or 1 (slope significance)'
                   WHEN u.knob = 'cpu_deseason'        AND u.value NOT IN (0, 1)
                        THEN 'must be 0 (off) or 1 (weekday / weekend demeaning)'
                   WHEN u.knob = 'suite_version'       AND u.value < 22
                        THEN 'older than this release (22): re-run install.sql'
               END AS reason
        FROM   u CROSS JOIN cap_cfg c
     )
SELECT knob,
       value,
       CASE WHEN value IS NULL      THEN 'MISSING'
            WHEN reason IS NOT NULL THEN 'BAD'
            ELSE 'OK'
       END AS status,
       reason
FROM   r;

COMMENT ON TABLE cap_cfg_check IS 'One row per knob: value, status OK / MISSING (no CAP_CONFIG row) / BAD (breaks a range rule), reason.';

-- =====================================================================
-- CAP_TBSPC_OVERRIDE (M9.5) -- per-tablespace limit overrides / exclusions.
-- =====================================================================
-- Operator data, like CAP_CONFIG, so ddl/00_drop.sql leaves it alone and a re-install preserves it; only
-- uninstall.sql drops it.
--
-- Why it exists: the autoextend `maxsize` recorded in AWR is a promise the
-- STORAGE may not be able to keep -- a 32 GiB datafile maxsize on a 10 GiB
-- filesystem / ASM diskgroup is not 32 GiB of headroom, and forecasting
-- against it produces a comfortable days-to-full that is a lie. A row here
-- replaces the computed limit with the real ceiling. exclude_flag drops a
-- staging / scratch / import tablespace out of the analytics entirely, so it
-- stops generating noise in the report and in CAPR_ALERTS. The four
-- threshold columns (bottom of this file) replace the global dtf_* /
-- nearfull_* knobs for one tablespace.
--
-- Matching (see CAPD_TBSPC_DAILY): tablespace_name is an EXACT match (no
-- patterns), while dbid = 0 and/or con_dbid = 0 are WILDCARDS meaning "any".
-- So a fleet-wide rule is (0, 0, 'STAGING'), a per-database rule is
-- (<dbid>, 0, 'STAGING'), and a per-container rule names both. When several
-- rows match one tablespace the MOST SPECIFIC wins: a real dbid beats the 0
-- wildcard first, then a real con_dbid beats it.
--
-- Idempotent create, same pattern as CAP_CONFIG above: swallow ORA-00955 and
-- keep the operator's existing rows.
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

COMMENT ON TABLE  cap_tbspc_override                 IS 'M9.5: per-tablespace limit overrides / exclusions / alert thresholds. Applied by CAPD_TBSPC_DAILY; dbid/con_dbid = 0 mean "any".';
COMMENT ON COLUMN cap_tbspc_override.dbid            IS 'DBID this rule applies to, or 0 = any database.';
COMMENT ON COLUMN cap_tbspc_override.con_dbid        IS 'CON_DBID this rule applies to, or 0 = any container.';
COMMENT ON COLUMN cap_tbspc_override.tablespace_name IS 'Tablespace name, matched exactly (no patterns).';
COMMENT ON COLUMN cap_tbspc_override.limit_bytes     IS 'Real ceiling in bytes, replacing the AWR-derived autoextend maxsize / allocated size. NULL = keep the computed limit.';
COMMENT ON COLUMN cap_tbspc_override.exclude_flag    IS 'Y = drop this tablespace from CAPD_TBSPC_DAILY and everything downstream (forecasts, anomalies, alerts). N (default) = keep it.';
COMMENT ON COLUMN cap_tbspc_override.note            IS 'Free-text reason, for whoever reads the table in six months.';

-- Per-tablespace alert thresholds (CAPR_SEVERITY): a NULL column keeps the
-- global knob, so a row that only sets limit_bytes changes no threshold. A
-- fixed-size tablespace that is meant to run at 95% gets
-- nearfull_warn_pct = 98 here instead of an exclusion from every layer.
-- Added one column at a time so an install that already has some of them
-- still gains the rest. ORA-01430 = the column already exists.
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

COMMENT ON COLUMN cap_tbspc_override.dtf_warn          IS 'days_to_full at/below which TBSPC_FULL is a WARN for this tablespace. NULL = the dtf_warn knob.';
COMMENT ON COLUMN cap_tbspc_override.dtf_crit          IS 'days_to_full at/below which TBSPC_FULL is a CRIT for this tablespace. NULL = the dtf_crit knob.';
COMMENT ON COLUMN cap_tbspc_override.nearfull_warn_pct IS 'Percent used at/above which TBSPC_NEARFULL is a WARN for this tablespace. NULL = the nearfull_warn_pct knob.';
COMMENT ON COLUMN cap_tbspc_override.nearfull_crit_pct IS 'Percent used at/above which TBSPC_NEARFULL is a CRIT for this tablespace. NULL = the nearfull_crit_pct knob.';
