--
-- ddl/05_config.sql -- CAP_CONFIG name/value tuning table + idempotent seed.
-- =====================================================================
-- One of only three persisted tables in the suite (the others are
-- CAP_TBSPC_OVERRIDE, created at the bottom of this file, and CAP_ML_MODEL).
-- Every analytic view reads its knobs from here via a one-row `cfg` CTE, so
-- tuning the toolkit never requires editing SQL -- just UPDATE a value.
--
-- All values are numeric (NUMBER). Byte thresholds are in bytes, day windows
-- in days, percentages in whole percent. The MERGE below is re-runnable: it
-- inserts any missing key and leaves existing values untouched, so a
-- re-install never clobbers an operator's tuning. To reset a key to its
-- shipped default, DELETE it and re-run this script (or UPDATE it directly).
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
        cfg_desc   VARCHAR2(200)
    )';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

COMMENT ON TABLE  cap_config            IS 'AWR capacity toolkit tuning knobs (name/value). Read by CAPF_*/CAPA_* views via a one-row cfg CTE.';
COMMENT ON COLUMN cap_config.cfg_name   IS 'Knob name (primary key).';
COMMENT ON COLUMN cap_config.cfg_value  IS 'Numeric value. Units per cfg_desc (bytes / days / whole percent / ratio).';
COMMENT ON COLUMN cap_config.cfg_desc   IS 'Human description incl. units.';

-- Idempotent seed. INSERT-only: WHEN MATCHED does nothing, preserving any
-- operator override across re-installs.
MERGE INTO cap_config c
USING (
    SELECT 'train_days'          AS cfg_name, 90        AS cfg_value, 'Length of the primary linear-fit training window (days).'                              AS cfg_desc FROM dual
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
    UNION ALL SELECT 'nearfull_warn_pct',    90,        'Percent-used at/above which a tablespace raises a near-full-now WARN (any forecast quality).'          FROM dual
    UNION ALL SELECT 'nearfull_crit_pct',    97,        'Percent-used at/above which a tablespace raises a near-full-now CRIT (any forecast quality).'          FROM dual
    UNION ALL SELECT 'peak_hour_from',        8,         'Peak window start (hour of day, exclusive). A snapshot interval is "peak" when its end time falls in (from, to].' FROM dual
    UNION ALL SELECT 'peak_hour_to',          18,        'Peak window end (hour of day, inclusive). See peak_hour_from.'                                          FROM dual
    UNION ALL SELECT 'cpu_sat_on_p95',        1,         '1 = CPU_SAT alerts key off the BUSY_P95 (per-snapshot p95) trend; 0 = off the daily-average BUSY_PCT trend.' FROM dual
    UNION ALL SELECT 'backtest_holdout_days',28,        'Holdout window (days) CAPF_BACKTEST fits before and scores against; <=30 lets ESM cover it on 19c.'    FROM dual
    UNION ALL SELECT 'report_min_gb',         1,        'Report sections 2/6a print a tablespace only if it is growing, near-full, or at least this many GiB used.' FROM dual
    UNION ALL SELECT 'accel_slope_floor_bpd', 1048576,  'Minimum |slope| (bytes/day, default 1 MiB) before accel_ratio is computed; below it a near-flat series gets NULL.' FROM dual
) s
ON (c.cfg_name = s.cfg_name)
WHEN NOT MATCHED THEN
    INSERT (cfg_name, cfg_value, cfg_desc)
    VALUES (s.cfg_name, s.cfg_value, s.cfg_desc);

COMMIT;

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
