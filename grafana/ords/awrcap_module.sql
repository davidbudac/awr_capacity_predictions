--
-- grafana/ords/awrcap_module.sql -- publish the suite's CAPR_* views as the
-- ORDS REST module `awrcap` (contract: grafana/API.md).
--
--   As the schema owner:      SQL> @grafana/ords/awrcap_module.sql
--   As a DBA (e.g. SYSDBA):   SQL> ALTER SESSION SET CONTAINER = PDB1;
--                             SQL> @grafana/ords/awrcap_module.sql CAPDEMO
-- Optional &2 = URL alias (default: lower-case schema name), so the base URL
-- is http://<ords>/ords/<alias>/awrcap/.
--
-- The owner calls ORDS.*; anyone else calls ORDS_ADMIN.* with p_schema (needs
-- ORDS_ADMINISTRATOR_ROLE or EXECUTE ANY PROCEDURE). Idempotent: ENABLE_SCHEMA
-- re-maps the alias and DEFINE_MODULE replaces the module with its templates.
-- Writes only ORDS metadata (ORDS_METADATA), never suite or AWR data.
-- Handlers are public (no ORDS privilege), the same exposure as the suite's
-- other read-only reports; protect the module with ORDS.DEFINE_PRIVILEGE if
-- the network is not trusted.
--
-- Every handler is a json/collection query except `metrics`, a PL/SQL block
-- that prints the Prometheus text exposition format (text/plain;
-- version=0.0.4) over CAPR_ALERTS, CAPR_FIT and CAPR_FRESHNESS through HTP.
-- To try its body without ORDS, initialise the OWA environment, run the
-- block between plsql('metrics', q'~ and ~'); and print the page with
-- OWA_UTIL.SHOWPAGE (grafana/API.md shows how).
--
SET DEFINE ON
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;

DECLARE
    c_module CONSTANT VARCHAR2(30) := 'awrcap';
    v_schema VARCHAR2(128) := UPPER(NVL('&1', SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')));
    v_alias  VARCHAR2(128) := NVL('&2', LOWER(v_schema));
    v_pkg    VARCHAR2(30);
    v_sch    VARCHAR2(200);

    -- from/to: ISO-8601 (Grafana's ${__from:date:iso} sends milliseconds and
    -- Z; the mask also accepts no fraction). A daily point belongs to the
    -- range when its day overlaps it, hence TRUNC on the lower bound.
    c_range CONSTANT VARCHAR2(400) :=
        q'[ts >= NVL(TRUNC(CAST(SYS_EXTRACT_UTC(TO_TIMESTAMP_TZ(:p_from, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')) AS DATE)), TRUNC(SYSDATE) - 120)
  AND  ts <= NVL(CAST(SYS_EXTRACT_UTC(TO_TIMESTAMP_TZ(:p_to, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')) AS DATE), SYSDATE)]';
    -- Hour points take the range as given (no TRUNC), default the last 14 days.
    c_hour_range CONSTANT VARCHAR2(400) :=
        q'[ts >= NVL(CAST(SYS_EXTRACT_UTC(TO_TIMESTAMP_TZ(:p_from, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')) AS DATE), SYSDATE - 14)
  AND  ts <= NVL(CAST(SYS_EXTRACT_UTC(TO_TIMESTAMP_TZ(:p_to, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')) AS DATE), SYSDATE)]';

    PROCEDURE run(p_call VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'BEGIN ' || v_pkg || '.' || p_call || '; END;';
    END;

    -- p_items_per_page => 0 turns pagination off: the contract is every
    -- matching row in one response. p_mapped lists the URL parameters that
    -- are not legal bind names (from, to, mode); each binds as :p_<name>.
    PROCEDURE get(p_pattern VARCHAR2, p_source VARCHAR2, p_mapped VARCHAR2 := NULL) IS
    BEGIN
        run('define_template(' || v_sch || 'p_module_name => ''' || c_module
            || ''', p_pattern => ''' || p_pattern || ''')');
        run('define_handler(' || v_sch || 'p_module_name => ''' || c_module
            || ''', p_pattern => ''' || p_pattern || ''', p_method => ''GET'''
            || ', p_source_type => ''json/collection'', p_items_per_page => 0'
            || ', p_source => ' || DBMS_ASSERT.ENQUOTE_LITERAL(REPLACE(p_source, '''', '''''')) || ')');
        IF p_mapped IS NOT NULL THEN
            FOR b IN (SELECT REGEXP_SUBSTR(p_mapped, '[^,]+', 1, LEVEL) AS name FROM dual
                      CONNECT BY LEVEL <= REGEXP_COUNT(p_mapped, ',') + 1) LOOP
                run('define_parameter(' || v_sch || 'p_module_name => ''' || c_module
                    || ''', p_pattern => ''' || p_pattern || ''', p_method => ''GET'''
                    || ', p_name => ''' || b.name || ''', p_bind_variable_name => ''p_' || b.name
                    || ''', p_source_type => ''URI'', p_param_type => ''STRING'', p_access_method => ''IN'')');
            END LOOP;
        END IF;
    END;
    -- A PL/SQL handler: the block writes the response itself through HTP.
    PROCEDURE plsql(p_pattern VARCHAR2, p_source VARCHAR2) IS
    BEGIN
        run('define_template(' || v_sch || 'p_module_name => ''' || c_module
            || ''', p_pattern => ''' || p_pattern || ''')');
        run('define_handler(' || v_sch || 'p_module_name => ''' || c_module
            || ''', p_pattern => ''' || p_pattern || ''', p_method => ''GET'''
            || ', p_source_type => ''plsql/block'''
            || ', p_source => ' || DBMS_ASSERT.ENQUOTE_LITERAL(REPLACE(p_source, '''', '''''')) || ')');
    END;
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') = v_schema THEN
        v_pkg := 'ords';
    ELSE
        v_pkg := 'ords_admin';
        v_sch := 'p_schema => ' || DBMS_ASSERT.ENQUOTE_LITERAL(v_schema) || ', ';
    END IF;

    run('enable_schema(' || CASE WHEN v_sch IS NULL THEN 'p_enabled => TRUE, ' ELSE v_sch || 'p_enabled => TRUE, ' END
        || 'p_url_mapping_type => ''BASE_PATH'', p_url_mapping_pattern => '
        || DBMS_ASSERT.ENQUOTE_LITERAL(v_alias) || ', p_auto_rest_auth => FALSE)');

    run('define_module(' || v_sch || 'p_module_name => ''' || c_module
        || ''', p_base_path => ''/awrcap/'', p_items_per_page => 0, p_status => ''PUBLISHED'''
        || ', p_comments => ''Capacity suite CAPR_* views for Grafana; contract grafana/API.md'')');

    get('containers', q'[
SELECT dbid, con_dbid, db_name, con_name, db_pdb AS db
FROM   capr_container
ORDER  BY db_pdb]');

    get('series', q'[
SELECT ts, kind, series, db, con_dbid, value, limit_value, pct, unit,
       anomaly, anomaly_flag, z, expected, threshold, gap,
       used_bytes, size_bytes, limit_bytes, delta_bytes, rate_bpd,
       busy_pct, busy_p95, busy_peak_pct, anomaly_modes, how_hours_flagged
FROM   capr_series_points
WHERE  kind = UPPER(:kind)
  AND  (:db IS NULL OR db = :db)
  AND  (:series IS NULL OR series = :series)
  AND  ]' || c_range || q'[
ORDER  BY db, series, ts]', 'from,to');

    get('hourly', q'[
SELECT ts, kind, series, db, con_dbid, day_dt, dow, hour_of_day, unit, value,
       gap, ivl_hours, n_intervals, anomaly, how_expected, how_threshold, how_z,
       how_flag, how_n_hist
FROM   capr_hourly_points
WHERE  (:db IS NULL OR db = :db)
  AND  (:series IS NULL OR series = :series)
  AND  ]' || c_hour_range || q'[
ORDER  BY db, series, ts]', 'from,to');

    get('forecast', q'[
SELECT ts, kind, series, db, con_dbid, method, horizon_days, value, lo, hi,
       limit_value, pct, quality
FROM   capr_forecast_points
WHERE  kind = UPPER(:kind)
  AND  (:db IS NULL OR db = :db)
  AND  (:series IS NULL OR series = :series)
ORDER  BY db, series, method DESC, horizon_days]');

    get('fit', q'[
SELECT kind, series, db, con_dbid, unit, method, value, limit_value, pct,
       slope_per_day, r2, quality, days_to_full, days_to_full_lo, days_to_full_hi,
       accel, train_n, sev, sev_rank, limit_source, last_day
FROM   capr_fit
WHERE  (:kind IS NULL OR kind = UPPER(:kind))
  AND  (:db IS NULL OR db = :db)
ORDER  BY sev_rank, days_to_full NULLS LAST, db, kind, series]');

    get('anomalies', q'[
SELECT ts, kind, series, db, con_dbid, anomaly_kind, anomaly_flag, value,
       expected, threshold, z, shift_pct, unit, sev, sev_rank, message, obs_day,
       baseline_mode, grain, n_hist, alerting, raw_value
FROM   capr_anomalies
WHERE  (:kind IS NULL OR kind = UPPER(:kind))
  AND  (:db IS NULL OR db = :db)
  AND  (:p_mode IS NULL OR baseline_mode = UPPER(:p_mode))
  AND  ]' || c_range || q'[
ORDER  BY ts DESC, sev_rank, db, series]', 'from,to,mode');

    get('alerts', q'[
SELECT TRIM(severity) AS sev, sev_rank, kind AS alert_kind,
       CASE WHEN kind LIKE 'TBSPC%'  THEN 'TBSPC'
            WHEN kind LIKE 'SERIES%' THEN 'SERIES'
            ELSE 'CPU' END AS kind,
       series_key AS series, db_pdb AS db, con_dbid, day_dt AS obs_day,
       value, threshold, LOWER(unit) AS unit, message, baseline_mode, alert_key
FROM   capr_alerts
WHERE  (:db IS NULL OR db_pdb = :db)
ORDER  BY sev_rank, db_pdb, kind, series_key]');

    plsql('metrics', q'~
DECLARE
    -- Prometheus text exposition 0.0.4. Label values escape backslash,
    -- double quote and newline; numbers print with a leading zero and a '.'
    -- decimal, at most six decimals.
    PROCEDURE ln(p_text VARCHAR2) IS
    BEGIN
        HTP.PRN(p_text || CHR(10));
    END;
    FUNCTION lv(p_val VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(p_val, '', '\'), '"', '"'), CHR(10), '
');
    END;
    FUNCTION num(p_n NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN RTRIM(TO_CHAR(p_n, 'FM99999999999999990.999999', 'NLS_NUMERIC_CHARACTERS = ''.,'''), '.');
    END;
    PROCEDURE up(p_val PLS_INTEGER) IS
    BEGIN
        ln('# HELP awrcap_up 1 when the handler read every view, 0 when one raised.');
        ln('# TYPE awrcap_up gauge');
        ln('awrcap_up ' || p_val);
    END;
BEGIN
    OWA_UTIL.MIME_HEADER('text/plain; version=0.0.4', TRUE);
    ln('# HELP awrcap_alert Current CAPR_ALERTS rows per kind, severity, container, series and baseline mode (normally 1).');
    ln('# TYPE awrcap_alert gauge');
    FOR r IN (SELECT kind, TRIM(severity) AS severity, db_pdb, con_dbid, series_key,
                     NVL(baseline_mode, '-') AS b_mode, COUNT(*) AS n
              FROM   capr_alerts
              GROUP  BY kind, TRIM(severity), db_pdb, con_dbid, series_key, NVL(baseline_mode, '-')
              ORDER  BY kind, db_pdb, series_key, b_mode) LOOP
        ln('awrcap_alert{kind="' || lv(r.kind) || '",severity="' || lv(r.severity)
           || '",db="' || lv(r.db_pdb) || '",con_dbid="' || r.con_dbid
           || '",series="' || lv(r.series_key) || '",mode="' || lv(r.b_mode) || '"} ' || r.n);
    END LOOP;
    ln('# HELP awrcap_days_to_full Days until the series reaches its ceiling (tablespace full, CPU saturation, series limit) from CAPR_FIT; series with no projected crossing are omitted.');
    ln('# TYPE awrcap_days_to_full gauge');
    FOR r IN (SELECT kind, db, con_dbid, series, quality, days_to_full
              FROM   capr_fit
              WHERE  days_to_full IS NOT NULL
              ORDER  BY kind, db, series) LOOP
        ln('awrcap_days_to_full{kind="' || lv(r.kind) || '",db="' || lv(r.db)
           || '",con_dbid="' || r.con_dbid || '",series="' || lv(r.series)
           || '",quality="' || lv(r.quality) || '"} ' || num(r.days_to_full));
    END LOOP;
    ln('# HELP awrcap_pct_used Current value as a percent of its ceiling from CAPR_FIT (CPU: of the saturation line cpu_sat_pct).');
    ln('# TYPE awrcap_pct_used gauge');
    FOR r IN (SELECT kind, db, con_dbid, series, pct
              FROM   capr_fit
              WHERE  pct IS NOT NULL
              ORDER  BY kind, db, series) LOOP
        ln('awrcap_pct_used{kind="' || lv(r.kind) || '",db="' || lv(r.db)
           || '",con_dbid="' || r.con_dbid || '",series="' || lv(r.series) || '"} ' || num(r.pct));
    END LOOP;
    ln('# HELP awrcap_data_through_days Days since the newest AWR snapshot day of each database (CAPR_FRESHNESS); 0 = data through today.');
    ln('# TYPE awrcap_data_through_days gauge');
    FOR r IN (SELECT db_name, dbid, TRUNC(SYSDATE) - newest_day AS age_days
              FROM   capr_freshness
              ORDER  BY db_name, dbid) LOOP
        ln('awrcap_data_through_days{db="' || lv(r.db_name) || '",dbid="' || r.dbid || '"} ' || num(r.age_days));
    END LOOP;
    up(1);
EXCEPTION
    WHEN OTHERS THEN
        ln('# awrcap metrics failed: ' || REPLACE(REPLACE(SQLERRM, CHR(10), ' '), CHR(13), ' '));
        up(0);
END;
~');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('awrcap module published for ' || v_schema || ' at /ords/' || v_alias || '/awrcap/ (via ' || v_pkg || ')');
END;
/

UNDEFINE 1 2
