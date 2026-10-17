--
-- ddl/05_config.sql -- CAP_CONFIG name/value tuning table + idempotent seed.
-- =====================================================================
-- One of only three persisted tables in the suite (the others are
-- CAP_TBSPC_OVERRIDE, created at the bottom of this file, and CAP_ML_MODEL).
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
    UNION ALL SELECT 'dow_weeks',            8,         'Number of prior same-weekday observations forming the CPU seasonal baseline.'                          FROM dual
    UNION ALL SELECT 'dtf_warn',             90,        'days_to_full at/below this = WARN in the report.'                                                      FROM dual
    UNION ALL SELECT 'dtf_crit',             30,        'days_to_full at/below this = CRIT in the report.'                                                      FROM dual
    UNION ALL SELECT 'tbspc_min_hist',       7,         'Minimum trailing observations before a tablespace anomaly can flag.'                                   FROM dual
    UNION ALL SELECT 'cpu_min_mad_pct',      3,         'Floor (whole percent) on CPU MAD_sigma so an exactly-flat seasonal baseline still flags a real jump.' FROM dual
    UNION ALL SELECT 'cpu_min_dow_hist',     3,         'Minimum prior same-weekday observations before a CPU anomaly can flag.'                                FROM dual
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
    UNION ALL SELECT 'slope_method',           0,        'M9.2 slope estimator for the CAPF_* fits. NUMERIC ENCODING: 0 = OLS (REGR_SLOPE, default), 1 = THEILSEN (median pairwise slope, robust to steps).' FROM dual
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
    UNION ALL SELECT 'suite_version',          13,        'Suite release that built these objects (latest PLAN.md milestone). Set by every install; not a tuning knob.' FROM dual
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
       MAX(CASE WHEN cfg_name = 'tbspc_min_hist'         THEN cfg_value END) AS tbspc_min_hist,
       MAX(CASE WHEN cfg_name = 'cpu_min_mad_pct'        THEN cfg_value END) AS cpu_min_mad_pct,
       MAX(CASE WHEN cfg_name = 'cpu_min_dow_hist'       THEN cfg_value END) AS cpu_min_dow_hist,
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
       MAX(CASE WHEN cfg_name = 'suite_version'          THEN cfg_value END) AS suite_version
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
               dow_weeks, dtf_warn, dtf_crit, tbspc_min_hist, cpu_min_mad_pct,
               cpu_min_dow_hist, esm_prediction_step, esm_tbspc_model,
               esm_select_by_backtest, nearfull_warn_pct, nearfull_crit_pct,
               peak_hour_from, peak_hour_to, cpu_sat_on_p95, backtest_holdout_days,
               report_min_gb, accel_slope_floor_bpd, slope_method, reset_on_shrink,
               shrink_mad_k, cpu_gap_hours, shift_days, shift_baseline_days,
               shift_min_pct, series_sat_pct, esm_max_age_days, esm_auto_tie_pct,
               complete_day_pct, suite_version))
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
                   WHEN u.knob = 'mad_window_days'     AND u.value < c.tbspc_min_hist
                        THEN 'must be >= tbspc_min_hist (' || c.tbspc_min_hist || ')'
                   WHEN u.knob = 'shift_days'          AND u.value > c.shift_baseline_days
                        THEN 'must be <= shift_baseline_days (' || c.shift_baseline_days || ')'
                   WHEN u.knob = 'esm_prediction_step' AND u.value NOT BETWEEN 1 AND 30
                        THEN 'must be between 1 and 30: Oracle 19c caps the ESM horizon at 30'
                   WHEN u.knob = 'slope_method'        AND u.value NOT IN (0, 1)
                        THEN 'must be 0 (OLS) or 1 (THEILSEN)'
                   WHEN u.knob = 'esm_tbspc_model'     AND u.value NOT IN (0, 1, 2)
                        THEN 'must be 0 (HOLT), 1 (ADDWINTERS) or 2 (AUTO)'
                   WHEN u.knob = 'esm_max_age_days'    AND u.value < 0
                        THEN 'must be >= 0'
                   WHEN u.knob = 'esm_auto_tie_pct'    AND u.value < 0
                        THEN 'must be >= 0'
                   WHEN u.knob = 'complete_day_pct'    AND u.value NOT BETWEEN 1 AND 100
                        THEN 'must be between 1 and 100 (percent of a day)'
                   WHEN u.knob = 'suite_version'       AND u.value < 13
                        THEN 'older than this release (13): re-run install.sql'
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
-- The THIRD persisted table (with CAP_CONFIG and CAP_ML_MODEL). Operator data,
-- so ddl/00_drop.sql leaves it alone and a re-install preserves it; only
-- uninstall.sql drops it.
--
-- Why it exists: the autoextend `maxsize` recorded in AWR is a promise the
-- STORAGE may not be able to keep -- a 32 GiB datafile maxsize on a 10 GiB
-- filesystem / ASM diskgroup is not 32 GiB of headroom, and forecasting
-- against it produces a comfortable days-to-full that is a lie. A row here
-- replaces the computed limit with the real ceiling. exclude_flag drops a
-- staging / scratch / import tablespace out of the analytics entirely, so it
-- stops generating noise in the report and in CAPR_ALERTS.
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

COMMENT ON TABLE  cap_tbspc_override                 IS 'M9.5: per-tablespace limit overrides / exclusions. Applied by CAPD_TBSPC_DAILY; dbid/con_dbid = 0 mean "any".';
COMMENT ON COLUMN cap_tbspc_override.dbid            IS 'DBID this rule applies to, or 0 = any database.';
COMMENT ON COLUMN cap_tbspc_override.con_dbid        IS 'CON_DBID this rule applies to, or 0 = any container.';
COMMENT ON COLUMN cap_tbspc_override.tablespace_name IS 'Tablespace name, matched exactly (no patterns).';
COMMENT ON COLUMN cap_tbspc_override.limit_bytes     IS 'Real ceiling in bytes, replacing the AWR-derived autoextend maxsize / allocated size. NULL = keep the computed limit.';
COMMENT ON COLUMN cap_tbspc_override.exclude_flag    IS 'Y = drop this tablespace from CAPD_TBSPC_DAILY and everything downstream (forecasts, anomalies, alerts). N (default) = keep it.';
COMMENT ON COLUMN cap_tbspc_override.note            IS 'Free-text reason, for whoever reads the table in six months.';
