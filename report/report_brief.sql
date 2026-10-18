--
-- report/report_brief.sql -- read-only one-page capacity briefing (HTML).
-- =====================================================================
-- Spools reports/cap_brief_<db>_<ts>.html for a reader who wants "what
-- fills, when, what do I do": a headline, the dates each limit is reached on
-- a twelve-month runway, the actions in order, the evidence for the first
-- few and every tablespace as a fill bar. report/report_html.sql stays the
-- full report. READ-ONLY: it SELECTs the CAPR_* views and CAP_CFG only.
--
-- Two lists are read once at the top and everything else derives from them:
-- t_fit (CAPR_FIT, or CAPR_FIT_HISTORY of the last OK refresh run under
-- SNAPSHOT) and t_al (CAPR_ALERTS / CAPR_ALERTS_LATEST). t_act folds the
-- capacity and health alerts into one action per series (TBSPC_FULL and
-- TBSPC_NEARFULL of one tablespace are one action, the worse severity
-- wins); the headline, the lede, the timeline highlights and the evidence
-- panels all read t_act. t_beh is the unusual-behaviour list.
--
-- Run from the REPO ROOT so the @@report/defaults.sql include resolves:
--   SQL> @report/report_brief.sql
--   SQL> @report/report_brief.sql 25 60 Y
--   SQL> @report/report_brief.sql - - - 42424242 42424243
--   SQL> @report/report_brief.sql - - - - - SNAPSHOT
-- Arguments as in report/report_html.sql: [top_n] [anomaly_days] [show_esm]
-- [dbid] [con_dbid] [LIVE|SNAPSHOT], '-' skips one. show_esm only toggles
-- the "Second model" fact of the evidence panels.
--
-- Each section renders inside its own exception handler: a failing query
-- prints a visible "section failed" box and the page carries on.
--
SET DEFINE '&'
SET VERIFY     OFF
SET FEEDBACK   OFF
SET ECHO       OFF
SET TERMOUT    OFF
SET TRIMSPOOL  ON
SET LINESIZE   32767
SET PAGESIZE   0
SET LONG       1000000
SET NEWPAGE    NONE
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';

@@report/defaults.sql

-- An unpassed &1..&6 becomes empty instead of prompting (zero-row NEW_VALUE).
COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
COLUMN 4 NEW_VALUE 4 NOPRINT
COLUMN 5 NEW_VALUE 5 NOPRINT
COLUMN 6 NEW_VALUE 6 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3",
       NULL AS "4", NULL AS "5", NULL AS "6" FROM dual WHERE 1 = 0;

COLUMN eff_top_n NEW_VALUE top_n        NOPRINT
COLUMN eff_anom  NEW_VALUE anomaly_days NOPRINT
COLUMN eff_esm   NEW_VALUE show_esm     NOPRINT
SELECT NVL(NULLIF(TRIM('&1'), '-'), '&top_n')                  AS eff_top_n,
       NVL(NULLIF(TRIM('&2'), '-'), '&anomaly_days')           AS eff_anom,
       NVL(NULLIF(UPPER(TRIM('&3')), '-'), UPPER('&show_esm')) AS eff_esm
FROM   dual;

COLUMN eff_sdbid NEW_VALUE cap_sdbid NOPRINT
COLUMN eff_scon  NEW_VALUE cap_scon  NOPRINT
COLUMN eff_src   NEW_VALUE cap_src   NOPRINT
SELECT NVL(REGEXP_SUBSTR(TRIM('&4'), '^[0-9]+$'), 'NULL')                  AS eff_sdbid,
       NVL(REGEXP_SUBSTR(TRIM('&5'), '^[0-9]+$'), 'NULL')                  AS eff_scon,
       CASE WHEN UPPER(TRIM('&6')) = 'SNAPSHOT' THEN 'SNAPSHOT' ELSE 'LIVE' END AS eff_src
FROM   dual;

COLUMN cap_db   NEW_VALUE cap_db   NOPRINT
COLUMN cap_host NEW_VALUE cap_host NOPRINT
COLUMN cap_user NEW_VALUE cap_user NOPRINT
COLUMN cap_gen  NEW_VALUE cap_gen  NOPRINT
COLUMN cap_path NEW_VALUE cap_path NOPRINT
COLUMN cap_file NEW_VALUE cap_file NOPRINT
SELECT SYS_CONTEXT('USERENV','DB_NAME')                                       AS cap_db,
       SYS_CONTEXT('USERENV','SERVER_HOST')                                   AS cap_host,
       SYS_CONTEXT('USERENV','CURRENT_SCHEMA')                                AS cap_user,
       TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI:SS TZR')                      AS cap_gen,
       'cap_brief_'
         || REGEXP_REPLACE(SYS_CONTEXT('USERENV','DB_NAME'),'[^A-Za-z0-9]+','_') || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MI') || '.html'                      AS cap_file,
       'reports/cap_brief_'
         || REGEXP_REPLACE(SYS_CONTEXT('USERENV','DB_NAME'),'[^A-Za-z0-9]+','_') || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MI') || '.html'                      AS cap_path
FROM   dual;

-- Bound while substitution is on; the block below runs with DEFINE OFF so
-- its HTML entities are never read as substitution variables.
VARIABLE b_top_n        NUMBER
VARIABLE b_anomaly_days NUMBER
VARIABLE b_show_esm     VARCHAR2(10)
VARIABLE b_cap_db       VARCHAR2(200)
VARIABLE b_cap_host     VARCHAR2(200)
VARIABLE b_cap_user     VARCHAR2(200)
VARIABLE b_cap_gen      VARCHAR2(200)
VARIABLE b_cap_file     VARCHAR2(200)
VARIABLE b_sdbid        NUMBER
VARIABLE b_scon         NUMBER
VARIABLE b_src          VARCHAR2(10)

BEGIN
  :b_top_n        := &top_n;
  :b_anomaly_days := &anomaly_days;
  :b_show_esm     := UPPER('&show_esm');
  :b_cap_db       := '&cap_db';
  :b_cap_host     := '&cap_host';
  :b_cap_user     := '&cap_user';
  :b_cap_gen      := '&cap_gen';
  :b_cap_file     := '&cap_file';
  :b_sdbid        := &cap_sdbid;
  :b_scon         := &cap_scon;
  :b_src          := '&cap_src';
END;
/

-- reports/ is gitignored, so a fresh clone does not have it.
HOST mkdir -p reports
SPOOL &cap_path

SET DEFINE OFF

SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
  top_n        PLS_INTEGER  := :b_top_n;
  anomaly_days PLS_INTEGER  := :b_anomaly_days;
  show_esm     VARCHAR2(10) := :b_show_esm;
  cap_db   VARCHAR2(200) := :b_cap_db;
  cap_host VARCHAR2(200) := :b_cap_host;
  cap_user VARCHAR2(200) := :b_cap_user;
  cap_gen  VARCHAR2(200) := :b_cap_gen;
  cap_file VARCHAR2(200) := :b_cap_file;
  s_dbid   NUMBER        := :b_sdbid;
  s_con    NUMBER        := :b_scon;
  v_src    VARCHAR2(10)  := :b_src;

  dtf_warn NUMBER;
  dtf_crit NUMBER;
  cpu_sat  NUMBER;
  nf_warn  NUMBER;
  nf_crit  NUMBER;
  sat_pct  NUMBER;

  v_snap_run  NUMBER;
  v_scope_lbl VARCHAR2(1000);
  v_src_lbl   VARCHAR2(300);
  v_today     DATE;
  v_failed    PLS_INTEGER := 0;
  v_load_err  VARCHAR2(1000);
  v_n_info    PLS_INTEGER := 0;

  CURSOR c_fit IS
    SELECT dbid, con_dbid, db, db_name, con_name, kind, series, unit, value, limit_value, pct,
           slope_per_day, r2, quality, days_to_full, days_to_full_lo, days_to_full_hi, accel,
           train_n, sev, sev_rank, last_day, limit_below_used, cycle_days, cycle_peak_pct,
           need_gib_30, need_gib_90, add_by_day
    FROM  (SELECT dbid, con_dbid, db, db_name, con_name, kind, series, unit, value, limit_value, pct,
                  slope_per_day, r2, quality, days_to_full, days_to_full_lo, days_to_full_hi, accel,
                  train_n, sev, sev_rank, last_day, limit_below_used, cycle_days, cycle_peak_pct,
                  need_gib_30, need_gib_90, add_by_day, is_current
           FROM   capr_fit WHERE v_src = 'LIVE'
           UNION ALL
           SELECT dbid, con_dbid, db, db_name, con_name, kind, series, unit, value, limit_value, pct,
                  slope_per_day, r2, quality, days_to_full, days_to_full_lo, days_to_full_hi, accel,
                  train_n, sev, sev_rank, last_day, limit_below_used, cycle_days, cycle_peak_pct,
                  need_gib_30, need_gib_90, add_by_day, is_current
           FROM   capr_fit_history WHERE v_src = 'SNAPSHOT' AND run_id = v_snap_run)
    WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
      AND  is_current = 1
    ORDER  BY kind, days_to_full NULLS LAST, pct DESC NULLS LAST, series, con_dbid;

  CURSOR c_al IS
    SELECT severity, kind, dbid, con_dbid, db_pdb, series_key, day_dt, value, threshold, unit,
           message, first_day, n_days, max_z
    FROM  (SELECT severity, kind, dbid, con_dbid, db_pdb, series_key, day_dt, value, threshold,
                  unit, message, first_day, n_days, max_z
           FROM   capr_alerts        WHERE v_src = 'LIVE'
           UNION ALL
           SELECT severity, kind, dbid, con_dbid, db_pdb, series_key, day_dt, value, threshold,
                  unit, message, CAST(NULL AS DATE), CAST(NULL AS NUMBER), CAST(NULL AS NUMBER)
           FROM   capr_alerts_latest WHERE v_src = 'SNAPSHOT')
    WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);

  TYPE fit_tab IS TABLE OF c_fit%ROWTYPE INDEX BY PLS_INTEGER;
  TYPE al_tab  IS TABLE OF c_al%ROWTYPE  INDEX BY PLS_INTEGER;
  TYPE act_rec IS RECORD (
    sev    VARCHAR2(4),
    kind   VARCHAR2(30),     -- the alert kind the action is written from
    al_ix  PLS_INTEGER,
    fit_ix PLS_INTEGER,      -- NULL for DATA_STALE / MODEL_HEALTH
    by_day DATE,             -- NULL = now
    sent   VARCHAR2(2000),
    detail VARCHAR2(2000),
    ev     PLS_INTEGER);     -- evidence panel number, NULL = no panel
  TYPE act_tab IS TABLE OF act_rec     INDEX BY PLS_INTEGER;
  TYPE ix_tab  IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
  TYPE key_tab IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);
  TYPE num_tab IS TABLE OF NUMBER      INDEX BY PLS_INTEGER;
  t_fit fit_tab;
  t_al  al_tab;
  t_act act_tab;
  t_beh ix_tab;

  c_act_kinds CONSTANT VARCHAR2(200) := ',TBSPC_FULL,TBSPC_NEARFULL,CPU_SAT,DBCPU_SAT,CPU_HOT,DBCPU_HOT,'
                                        || 'SERIES_LIMIT,SERIES_NEARLIMIT,DATA_STALE,MODEL_HEALTH,';
  c_beh_kinds CONSTANT VARCHAR2(100) := ',TBSPC_ANOM,CPU_ANOM,DBCPU_ANOM,SERIES_ANOM,CPU_SHIFT,';
  c_gib CONSTANT NUMBER := 1073741824;
  c_mib CONSTANT NUMBER := 1048576;

  PROCEDURE p(line IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(line);
  END p;

  FUNCTION esc(s IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN REPLACE(REPLACE(REPLACE(s, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  END esc;

  -- A failure inside an <svg> would be invisible, so the box closes it first
  -- (a stray end tag outside one is ignored by the parser).
  PROCEDURE sec_failed(p_sec IN VARCHAR2, p_err IN VARCHAR2) IS
  BEGIN
    v_failed := v_failed + 1;
    p('</svg><div class="sec-fail"><b>Section ' || esc(p_sec) || ' failed:</b> '
      || esc(SUBSTR(p_err, 1, 800)) || '. The rest of the briefing is unaffected.</div>');
  END sec_failed;

  PROCEDURE need_load IS
  BEGIN
    IF v_load_err IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20001, 'the fits and alerts could not be read: ' || v_load_err);
    END IF;
  END need_load;

  FUNCTION nz(n IN NUMBER, fmt IN VARCHAR2 DEFAULT 'FM999999990.00') RETURN VARCHAR2 IS
  BEGIN
    IF n IS NULL THEN RETURN '&ndash;'; END IF;
    RETURN TO_CHAR(n, fmt);
  END nz;

  FUNCTION fx0(n IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(ROUND(n), 'FM999999999990');
  END fx0;

  FUNCTION fx1(n IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN RTRIM(TO_CHAR(ROUND(n, 1), 'FM999999999990.9'), '.');
  END fx1;

  -- Two significant figures or so: 1091, 65, 2.2, 0.15.
  FUNCTION num(n IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF n IS NULL THEN RETURN NULL; END IF;
    IF ABS(n) >= 100 THEN RETURN fx0(n); END IF;
    IF ABS(n) >= 1 THEN RETURN fx1(n); END IF;
    RETURN RTRIM(TO_CHAR(ROUND(n, 2), 'FM990.99'), '.');
  END num;

  FUNCTION crd(n IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(ROUND(n, 1), 'FM999990.0');
  END crd;

  FUNCTION words(n IN NUMBER, p_cap IN BOOLEAN DEFAULT FALSE) RETURN VARCHAR2 IS
    c_w CONSTANT VARCHAR2(200) := 'zero,one,two,three,four,five,six,seven,eight,nine,ten,eleven,twelve,'
                                  || 'thirteen,fourteen,fifteen,sixteen,seventeen,eighteen,nineteen,twenty';
    v VARCHAR2(40);
  BEGIN
    IF n BETWEEN 0 AND 20 AND n = TRUNC(n) THEN
      v := REGEXP_SUBSTR(c_w, '[^,]+', 1, n + 1);
    ELSE
      v := TO_CHAR(n);
    END IF;
    IF p_cap THEN v := UPPER(SUBSTR(v, 1, 1)) || SUBSTR(v, 2); END IF;
    RETURN v;
  END words;

  -- 'L' 3 November, 'S' 3 Nov (+ ' 2027' in another year), 'T' 3 Nov &rsquo;27.
  FUNCTION dfmt(d IN DATE, p_style IN VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(60);
  BEGIN
    IF d IS NULL THEN RETURN NULL; END IF;
    v := TO_CHAR(d, CASE p_style WHEN 'L' THEN 'FMDD Month' ELSE 'FMDD Mon' END, 'NLS_DATE_LANGUAGE=ENGLISH');
    IF TO_CHAR(d, 'YYYY') <> TO_CHAR(v_today, 'YYYY') THEN
      v := v || CASE p_style WHEN 'T' THEN ' &rsquo;' || TO_CHAR(d, 'YY') ELSE ' ' || TO_CHAR(d, 'YYYY') END;
    END IF;
    RETURN v;
  END dfmt;

  -- A worst / best date next to its forecast date: the year only when the two differ.
  FUNCTION day_mon(d IN DATE, p_ref IN DATE) RETURN VARCHAR2 IS
  BEGIN
    IF TO_CHAR(d, 'YYYY') = TO_CHAR(p_ref, 'YYYY') THEN
      RETURN TO_CHAR(d, 'FMDD Mon', 'NLS_DATE_LANGUAGE=ENGLISH');
    END IF;
    RETURN dfmt(d, 'S');
  END day_mon;

  FUNCTION mon_yy(d IN DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(d, 'Mon', 'NLS_DATE_LANGUAGE=ENGLISH') || ' &rsquo;' || TO_CHAR(d, 'YY');
  END mon_yy;

  FUNCTION rate_txt(bpd IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF ABS(NVL(bpd, 0)) >= c_gib THEN RETURN fx1(bpd / c_gib) || ' GiB'; END IF;
    RETURN fx0(NVL(bpd, 0) / c_mib) || ' MiB';
  END rate_txt;

  FUNCTION unit_sfx(p_unit IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE LOWER(p_unit) WHEN 'gib' THEN ' GiB' WHEN 'gib_per_day' THEN ' GiB/day' END;
  END unit_sfx;

  FUNCTION sev_col(p_sev IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE p_sev WHEN 'CRIT' THEN 'var(--crit)' WHEN 'WARN' THEN 'var(--warn)' ELSE 'var(--ink-2)' END;
  END sev_col;

  FUNCTION srank(p_sev IN VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    RETURN CASE p_sev WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END;
  END srank;

  FUNCTION fam(p_kind IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE WHEN p_kind LIKE 'TBSPC%' THEN 'TBSPC'
                WHEN p_kind LIKE 'CPU%' OR p_kind LIKE 'DBCPU%' THEN 'CPU'
                WHEN p_kind LIKE 'SERIES%' THEN 'SERIES'
                ELSE p_kind END;
  END fam;

  -- Inside one series the forecast kind outranks the level kind of the same
  -- severity: the action is written from TBSPC_FULL, not TBSPC_NEARFULL.
  FUNCTION kprio(p_kind IN VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    RETURN CASE WHEN p_kind IN ('TBSPC_FULL', 'CPU_SAT', 'DBCPU_SAT', 'SERIES_LIMIT') THEN 1 ELSE 2 END;
  END kprio;

  FUNCTION lbl(p_kind IN VARCHAR2, p_series IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE
             WHEN p_kind = 'CPU' AND p_series = 'BUSY_P95'   THEN 'Host CPU p95'
             WHEN p_kind = 'CPU' AND p_series = 'BUSY_PCT'   THEN 'Host CPU avg'
             WHEN p_kind = 'CPU' AND p_series = 'BUSY_PEAK'  THEN 'Host CPU peak'
             WHEN p_kind = 'CPU' AND p_series = 'DB_CPU_P95' THEN 'DB CPU p95'
             WHEN p_kind = 'CPU' AND p_series = 'DB_CPU_PCT' THEN 'DB CPU avg'
             WHEN p_kind = 'CPU' AND p_series = 'DB_CPU_SEC' THEN 'DB CPU seconds'
             WHEN p_kind = 'SERIES' AND p_series = 'DB_SIZE_GB'  THEN 'Database size'
             WHEN p_kind = 'SERIES' AND p_series = 'REDO_GB_DAY' THEN 'Redo per day'
             WHEN p_kind = 'SERIES' AND p_series LIKE 'UNDO_PEAK:%' THEN 'Undo peak ' || SUBSTR(p_series, 11)
             WHEN p_kind = 'SERIES' AND p_series LIKE 'TEMP_PEAK:%' THEN 'Temp peak ' || SUBSTR(p_series, 11)
             ELSE p_series
           END;
  END lbl;

  -- TRUE when another container in scope has the same series, so the label
  -- alone would not say which one is meant.
  FUNCTION amb(i IN PLS_INTEGER) RETURN BOOLEAN IS
  BEGIN
    FOR j IN 1 .. t_fit.COUNT LOOP
      IF j <> i AND t_fit(j).kind = t_fit(i).kind AND t_fit(j).series = t_fit(i).series THEN
        RETURN TRUE;
      END IF;
    END LOOP;
    RETURN FALSE;
  END amb;

  FUNCTION lbl_t(i IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN lbl(t_fit(i).kind, t_fit(i).series)
           || CASE WHEN amb(i) THEN ' in ' || t_fit(i).con_name END;
  END lbl_t;

  FUNCTION lbl_h(i IN PLS_INTEGER) RETURN VARCHAR2 IS
    v VARCHAR2(400) := lbl(t_fit(i).kind, t_fit(i).series);
  BEGIN
    RETURN CASE WHEN v = t_fit(i).series THEN '<code>' || esc(v) || '</code>' ELSE esc(v) END
           || CASE WHEN amb(i) THEN ' in ' || esc(t_fit(i).con_name) END;
  END lbl_h;

  FUNCTION cpu_what(i IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE t_fit(i).series
             WHEN 'BUSY_P95'   THEN 'host CPU busy-hour p95'
             WHEN 'BUSY_PCT'   THEN 'host CPU average'
             WHEN 'BUSY_PEAK'  THEN 'host CPU peak'
             WHEN 'DB_CPU_P95' THEN 'busy-hour DB CPU in ' || esc(t_fit(i).con_name)
             ELSE 'DB CPU in ' || esc(t_fit(i).con_name)
           END;
  END cpu_what;

  FUNCTION find_fit(p_dbid IN NUMBER, p_con IN NUMBER, p_kind IN VARCHAR2, p_series IN VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    FOR i IN 1 .. t_fit.COUNT LOOP
      IF t_fit(i).dbid = p_dbid AND t_fit(i).con_dbid = p_con
         AND t_fit(i).kind = p_kind AND t_fit(i).series = p_series THEN
        RETURN i;
      END IF;
    END LOOP;
    RETURN NULL;
  END find_fit;

  -- The runway events: a dated limit on a fit worth trusting. CPU keeps only
  -- the busy-hour metrics, the ones that alert.
  FUNCTION on_runway(i IN PLS_INTEGER) RETURN BOOLEAN IS
  BEGIN
    RETURN t_fit(i).days_to_full >= 0
           AND t_fit(i).quality IN ('OK', 'CYCLIC')
           AND (t_fit(i).kind <> 'CPU' OR t_fit(i).series IN ('BUSY_P95', 'DB_CPU_P95'));
  END on_runway;

  FUNCTION ev_what(i IN PLS_INTEGER, p_short IN BOOLEAN) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE t_fit(i).kind
             WHEN 'TBSPC' THEN 'full'
             WHEN 'CPU' THEN fx0(t_fit(i).limit_value) || '%' || CASE WHEN NOT p_short THEN ' busy' END
             ELSE fx0(sat_pct) || '%' || CASE WHEN NOT p_short THEN ' of ' || num(t_fit(i).limit_value)
                                                                    || unit_sfx(t_fit(i).unit) END
           END;
  END ev_what;

  ----------------------------------------------------------------------
  -- compose: the one kind-keyed template table. Writes the action sentence,
  -- the detail line and the by-date from the action's alert kind and its fit.
  ----------------------------------------------------------------------
  PROCEDURE compose(a IN OUT NOCOPY act_rec) IS
    al  c_al%ROWTYPE := t_al(a.al_ix);
    f   c_fit%ROWTYPE;
    ts  VARCHAR2(400);
    con VARCHAR2(400);
  BEGIN
    IF a.fit_ix IS NOT NULL THEN
      f   := t_fit(a.fit_ix);
      ts  := '<code>' || esc(f.series) || '</code>';
      con := esc(f.con_name);
    ELSIF a.kind NOT IN ('DATA_STALE', 'MODEL_HEALTH') THEN
      a.sent := esc(al.message) || '.';
      RETURN;
    END IF;
    CASE
      WHEN a.kind = 'TBSPC_FULL' THEN
        a.by_day := NVL(f.add_by_day, f.last_day + NVL(f.days_to_full_lo, f.days_to_full));
        a.sent   := 'Add ' || fx1(NVL(NULLIF(f.need_gib_90, 0), f.need_gib_30)) || ' GiB to ' || ts
                    || ' in ' || con || ', or purge.';
        a.detail := fx0(f.pct) || '% full, growing ' || rate_txt(f.slope_per_day) || ' a day'
                    || CASE WHEN f.accel > 1.5 THEN ', accelerating (&times;' || fx1(f.accel) || ' its 90-day rate)' END
                    || '.';
      WHEN a.kind = 'TBSPC_NEARFULL' THEN
        a.by_day := NULL;
        a.sent   := 'Check ' || ts || ': it is ' || fx0(f.pct) || '% full'
                    || CASE WHEN NVL(f.slope_per_day, 0) <= 0 THEN ' and not growing'
                            WHEN NVL(f.days_to_full, 999) > 180 THEN ' but barely growing' END || '.';
        a.detail := num(f.value / c_gib) || ' of ' || num(f.limit_value / c_gib) || ' GiB, '
                    || rate_txt(f.slope_per_day) || ' a day.'
                    || CASE WHEN f.days_to_full >= 60 THEN ' Full in about ' || fx0(f.days_to_full / 30.4) || ' months at this rate.'
                            WHEN f.days_to_full IS NOT NULL THEN ' Full in about ' || fx0(f.days_to_full) || ' days at this rate.' END;
      WHEN a.kind IN ('CPU_SAT', 'DBCPU_SAT') THEN
        a.by_day := f.last_day + NVL(f.days_to_full_lo, f.days_to_full);
        a.sent   := 'Plan CPU headroom: ' || cpu_what(a.fit_ix) || ' reaches ' || fx0(f.limit_value) || '%.';
        a.detail := fx0(f.value) || '% now, rising ' || num(f.slope_per_day) || ' points a day.';
      WHEN a.kind IN ('CPU_HOT', 'DBCPU_HOT') THEN
        a.by_day := NULL;
        a.sent   := UPPER(SUBSTR(cpu_what(a.fit_ix), 1, 1)) || SUBSTR(cpu_what(a.fit_ix), 2) || ' is at '
                    || fx0(f.value) || '% now, above the ' || fx0(f.limit_value) || '% line.';
        a.detail := CASE WHEN f.slope_per_day > 0 THEN 'Rising ' || num(f.slope_per_day) || ' points a day.'
                         ELSE 'Not rising, but already over the line.' END;
      WHEN a.kind IN ('SERIES_LIMIT', 'SERIES_NEARLIMIT') THEN
        a.by_day := CASE WHEN a.kind = 'SERIES_LIMIT' THEN f.last_day + NVL(f.days_to_full_lo, f.days_to_full) END;
        a.sent   := CASE WHEN f.series IN ('SESSIONS', 'PROCESSES')
                         THEN 'Raise ' || ts || ' above ' || num(f.limit_value) || ' or find what holds '
                              || LOWER(f.series) || ' open.'
                         WHEN a.kind = 'SERIES_LIMIT'
                         THEN 'Make room for ' || lbl_h(a.fit_ix) || ' before it reaches ' || fx0(sat_pct) || '% of '
                              || num(f.limit_value) || unit_sfx(f.unit) || '.'
                         ELSE 'Make room for ' || lbl_h(a.fit_ix) || ': it is at ' || fx0(f.pct) || '% of its limit.'
                    END;
        a.detail := num(f.value) || unit_sfx(f.unit) || ' now, ' || fx0(f.pct) || '% of the limit, '
                    || CASE WHEN f.slope_per_day >= 0 THEN '+' END || num(f.slope_per_day) || ' a day.';
      WHEN a.kind = 'DATA_STALE' THEN
        a.by_day := NULL;
        a.sent   := 'AWR snapshots stopped arriving. Everything below is frozen.';
        a.detail := esc(al.message) || '.';
      WHEN a.kind = 'MODEL_HEALTH' THEN
        a.by_day := NULL;
        a.sent   := 'Retrain the Tier 2 models (<code>cap_forecast_ml.train_all</code>).';
        a.detail := esc(al.message) || '.';
      ELSE
        a.sent := esc(al.message) || '.';
    END CASE;
    IF a.by_day <= v_today THEN a.by_day := NULL; END IF;
  END compose;

  -- Action order: DATA_STALE first, then severity, then the by-date (now =
  -- the report day).
  FUNCTION act_before(a IN act_rec, b IN act_rec) RETURN BOOLEAN IS
    ka PLS_INTEGER := CASE WHEN a.kind = 'DATA_STALE' THEN 0 ELSE 1 END;
    kb PLS_INTEGER := CASE WHEN b.kind = 'DATA_STALE' THEN 0 ELSE 1 END;
  BEGIN
    IF ka <> kb THEN RETURN ka < kb; END IF;
    IF srank(a.sev) <> srank(b.sev) THEN RETURN srank(a.sev) < srank(b.sev); END IF;
    RETURN NVL(a.by_day, v_today) < NVL(b.by_day, v_today);
  END act_before;

  PROCEDURE build_actions IS
    k   key_tab;
    key VARCHAR2(400);
    j   PLS_INTEGER;
    m   PLS_INTEGER;
    tmp act_rec;
    al  c_al%ROWTYPE;
    n_ev PLS_INTEGER := 0;
  BEGIN
    FOR i IN 1 .. t_al.COUNT LOOP
      al := t_al(i);
      IF al.severity IN ('CRIT', 'WARN') AND INSTR(c_act_kinds, ',' || al.kind || ',') > 0 THEN
        key := al.dbid || '|' || al.con_dbid || '|' || fam(al.kind) || '|' || al.series_key;
        IF k.EXISTS(key) THEN
          j := k(key);
          IF srank(al.severity) < srank(t_act(j).sev)
             OR (srank(al.severity) = srank(t_act(j).sev) AND kprio(al.kind) < kprio(t_act(j).kind)) THEN
            t_act(j).sev   := al.severity;
            t_act(j).kind  := al.kind;
            t_act(j).al_ix := i;
          END IF;
        ELSE
          j := t_act.COUNT + 1;
          k(key) := j;
          t_act(j).sev    := al.severity;
          t_act(j).kind   := al.kind;
          t_act(j).al_ix  := i;
          t_act(j).fit_ix := CASE WHEN fam(al.kind) IN ('TBSPC', 'CPU', 'SERIES')
                                  THEN find_fit(al.dbid, al.con_dbid, fam(al.kind), al.series_key) END;
        END IF;
      END IF;
    END LOOP;
    FOR j IN 1 .. t_act.COUNT LOOP
      compose(t_act(j));
    END LOOP;
    FOR j IN 2 .. t_act.COUNT LOOP
      tmp := t_act(j);
      m := j - 1;
      WHILE m >= 1 AND act_before(tmp, t_act(m)) LOOP
        t_act(m + 1) := t_act(m);
        m := m - 1;
      END LOOP;
      t_act(m + 1) := tmp;
    END LOOP;
    FOR j IN 1 .. LEAST(t_act.COUNT, top_n) LOOP
      IF t_act(j).fit_ix IS NOT NULL AND n_ev < 4 THEN
        n_ev := n_ev + 1;
        t_act(j).ev := n_ev;
      END IF;
    END LOOP;
  END build_actions;

  PROCEDURE build_beh IS
    m PLS_INTEGER;
  BEGIN
    FOR i IN 1 .. t_al.COUNT LOOP
      IF t_al(i).severity = 'INFO' THEN
        v_n_info := v_n_info + 1;
      ELSIF INSTR(c_beh_kinds, ',' || t_al(i).kind || ',') > 0
            AND t_al(i).day_dt > v_today - anomaly_days THEN
        m := t_beh.COUNT;
        WHILE m >= 1 AND t_al(t_beh(m)).day_dt < t_al(i).day_dt LOOP
          t_beh(m + 1) := t_beh(m);
          m := m - 1;
        END LOOP;
        t_beh(m + 1) := i;
      END IF;
    END LOOP;
  END build_beh;

  FUNCTION act_lbl(j IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    IF t_act(j).fit_ix IS NOT NULL THEN RETURN lbl_t(t_act(j).fit_ix); END IF;
    RETURN CASE t_act(j).kind WHEN 'DATA_STALE' THEN 'AWR snapshots'
                              WHEN 'MODEL_HEALTH' THEN 'the Tier 2 models'
                              ELSE t_al(t_act(j).al_ix).series_key END;
  END act_lbl;

  FUNCTION when_txt(j IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE WHEN t_act(j).by_day IS NULL THEN 'now' ELSE 'by ' || dfmt(t_act(j).by_day, 'S') END;
  END when_txt;

  -- "A by 21 Nov, B by 1 Dec and C now" over actions p_from .. p_from + p_max - 1.
  FUNCTION act_list(p_from IN PLS_INTEGER, p_max IN PLS_INTEGER) RETURN VARCHAR2 IS
    v    VARCHAR2(4000);
    last PLS_INTEGER := LEAST(t_act.COUNT, p_from + p_max - 1);
  BEGIN
    FOR j IN p_from .. last LOOP
      v := v || CASE WHEN j = p_from THEN NULL WHEN j = last THEN ' and ' ELSE ', ' END
             || esc(act_lbl(j)) || ' ' || when_txt(j);
    END LOOP;
    RETURN v;
  END act_list;

  FUNCTION crit_headline(j IN PLS_INTEGER) RETURN VARCHAR2 IS
    f     c_fit%ROWTYPE;
    dfull VARCHAR2(100);
  BEGIN
    IF t_act(j).fit_ix IS NULL THEN RETURN esc(t_al(t_act(j).al_ix).message) || '.'; END IF;
    f := t_fit(t_act(j).fit_ix);
    dfull := REPLACE(dfmt(f.last_day + f.days_to_full, 'L'), ' ', '&nbsp;');
    RETURN CASE t_act(j).kind
             WHEN 'TBSPC_FULL' THEN esc(f.series) || ' fills on ' || dfull || '. Add '
                                    || fx0(NVL(NULLIF(f.need_gib_90, 0), f.need_gib_30)) || ' GiB before then.'
             WHEN 'TBSPC_NEARFULL' THEN esc(f.series) || ' is ' || fx0(f.pct) || '% full now.'
             WHEN 'CPU_SAT'   THEN esc(lbl_t(t_act(j).fit_ix)) || ' reaches ' || fx0(f.limit_value) || '% on ' || dfull || '.'
             WHEN 'DBCPU_SAT' THEN esc(lbl_t(t_act(j).fit_ix)) || ' reaches ' || fx0(f.limit_value) || '% on ' || dfull || '.'
             WHEN 'SERIES_LIMIT' THEN esc(lbl_t(t_act(j).fit_ix)) || ' reaches ' || fx0(sat_pct)
                                      || '% of its limit on ' || dfull || '.'
             WHEN 'SERIES_NEARLIMIT' THEN esc(lbl_t(t_act(j).fit_ix)) || ' is at ' || fx0(f.pct) || '% of its limit now.'
             ELSE esc(lbl_t(t_act(j).fit_ix)) || ' is at ' || fx0(f.value) || '% now.'
           END;
  END crit_headline;

  ----------------------------------------------------------------------
  -- Runway: every dated limit inside 380 days on one axis, greedy lane
  -- packing over four lanes (an event that fits none is counted, not drawn).
  ----------------------------------------------------------------------
  PROCEDURE runway IS
    c_w    CONSTANT NUMBER := 1080;
    c_l    CONSTANT NUMBER := 24;
    c_r    CONSTANT NUMBER := 24;
    c_span CONSTANT NUMBER := 380;
    ev   ix_tab;
    far  ix_tab;
    ux   num_tab;
    ul   num_tab;
    ur   num_tab;
    ure  num_tab;
    uln  num_tab;
    nu   PLS_INTEGER := 0;
    n_drop PLS_INTEGER := 0;
    i    PLS_INTEGER;
    lane PLS_INTEGER;
    ok   BOOLEAN;
    flip BOOLEAN;
    m    DATE;
    d    DATE;
    x    NUMBER;
    w    NUMBER;
    l    NUMBER;
    r    NUMBER;
    re   NUMBER;
    y    NUMBER;
    col  VARCHAR2(20);
    lab  VARCHAR2(400);
    sfx  VARCHAR2(400);
    sub  VARCHAR2(400);
    rt   VARCHAR2(2000);
    rt_n PLS_INTEGER := 0;
    rt_x0 NUMBER;
    FUNCTION sx(p_d IN NUMBER) RETURN NUMBER IS
    BEGIN
      RETURN c_l + (c_w - c_l - c_r) * p_d / c_span;
    END sx;
    PROCEDURE ins(t IN OUT NOCOPY ix_tab, p_i IN PLS_INTEGER) IS
      k PLS_INTEGER := t.COUNT;
    BEGIN
      WHILE k >= 1 AND t_fit(t(k)).days_to_full > t_fit(p_i).days_to_full LOOP
        t(k + 1) := t(k);
        k := k - 1;
      END LOOP;
      t(k + 1) := p_i;
    END ins;
  BEGIN
    FOR k IN 1 .. t_fit.COUNT LOOP
      IF on_runway(k) THEN
        IF t_fit(k).days_to_full <= c_span THEN ins(ev, k); ELSE ins(far, k); END IF;
      END IF;
    END LOOP;

    p('<svg viewBox="0 0 1080 250" class="runway" role="img" aria-label="Dates each limit is reached">');
    p('<rect x="' || crd(sx(0)) || '" y="34" width="' || crd(sx(LEAST(dtf_crit, c_span)) - sx(0))
      || '" height="176" fill="var(--crit-wash)"/>');
    IF dtf_warn > dtf_crit THEN
      p('<rect x="' || crd(sx(LEAST(dtf_crit, c_span))) || '" y="34" width="'
        || crd(sx(LEAST(dtf_warn, c_span)) - sx(LEAST(dtf_crit, c_span))) || '" height="176" fill="var(--warn-wash)"/>');
      p('<text x="' || crd(sx((dtf_crit + LEAST(dtf_warn, c_span)) / 2)) || '" y="26" class="win" text-anchor="middle">warning, '
        || fx0(dtf_warn) || ' d</text>');
    END IF;
    p('<text x="' || crd(sx(LEAST(dtf_crit, c_span) / 2)) || '" y="26" class="win" text-anchor="middle">critical, '
      || fx0(dtf_crit) || ' d</text>');
    m := ADD_MONTHS(TRUNC(v_today, 'MM'), 1);
    WHILE m - v_today <= c_span - 12 LOOP
      x := sx(m - v_today);
      p('<line x1="' || crd(x) || '" x2="' || crd(x) || '" y1="34" y2="210" class="tick"/>');
      IF x - sx(0) >= 38 THEN
        p('<text x="' || crd(x + 4) || '" y="226" class="mon">' || TO_CHAR(m, 'Mon', 'NLS_DATE_LANGUAGE=ENGLISH')
          || CASE WHEN TO_CHAR(m, 'MM') = '01' THEN ' &rsquo;' || TO_CHAR(m, 'YY') END || '</text>');
      END IF;
      m := ADD_MONTHS(m, 1);
    END LOOP;
    p('<line x1="' || crd(sx(0)) || '" x2="' || crd(sx(c_span)) || '" y1="210" y2="210" class="axis"/>');
    p('<line x1="' || crd(sx(0)) || '" x2="' || crd(sx(0)) || '" y1="20" y2="210" class="today"/>');
    p('<text x="' || crd(sx(0) + 4) || '" y="226" class="mon strong">' || dfmt(v_today, 'S') || '</text>');

    FOR k IN 1 .. LEAST(2, far.COUNT) LOOP
      i := far(k);
      rt := rt || CASE WHEN k > 1 THEN ', ' END || esc(lbl_t(i)) || ' ' || ev_what(i, TRUE) || ' '
               || mon_yy(t_fit(i).last_day + t_fit(i).days_to_full);
      rt_n := rt_n + LENGTH(lbl_t(i)) + LENGTH(ev_what(i, TRUE)) + 11;
    END LOOP;
    rt_x0 := sx(c_span) - (rt_n + 12) * 6.2;

    FOR k IN 1 .. ev.COUNT LOOP
      i   := ev(k);
      d   := t_fit(i).last_day + t_fit(i).days_to_full;
      x   := sx(t_fit(i).days_to_full);
      lab := lbl(t_fit(i).kind, t_fit(i).series);
      sfx := CASE WHEN amb(i) THEN ' ' || t_fit(i).con_name END;
      sub := ev_what(i, FALSE) || ' &middot; ' || dfmt(d, 'T');
      w   := GREATEST(LENGTH(lab) * 7.9 + NVL(LENGTH(sfx), 0) * 6.4,
                      (LENGTH(ev_what(i, FALSE)) + 12) * 6.3);
      flip := x + 7 + w > c_w - 4;
      l  := CASE WHEN flip THEN x - 7 - w ELSE x END;
      re := CASE WHEN flip THEN x ELSE x + 7 + w END;
      r  := CASE WHEN flip THEN x ELSE GREATEST(re, x + 150) END;
      lane := NULL;
      FOR li IN 0 .. 3 LOOP
        ok := NOT (li = 0 AND re > rt_x0);
        FOR u IN 1 .. nu LOOP
          EXIT WHEN NOT ok;
          IF uln(u) = li AND l < ur(u) + 8 AND ul(u) < r + 8 THEN
            ok := FALSE;
          ELSIF uln(u) < li AND ux(u) BETWEEN l - 4 AND re + 4 THEN
            ok := FALSE;
          ELSIF uln(u) > li AND x BETWEEN ul(u) - 4 AND ure(u) + 4 THEN
            ok := FALSE;
          END IF;
        END LOOP;
        IF ok THEN lane := li; EXIT; END IF;
      END LOOP;
      IF lane IS NULL THEN
        n_drop := n_drop + 1;
      ELSE
        nu := nu + 1;
        ux(nu) := x; ul(nu) := l; ur(nu) := r; ure(nu) := re; uln(nu) := lane;
        y   := 60 + 40 * lane;
        col := sev_col(t_fit(i).sev);
        p('<line x1="' || crd(x) || '" x2="' || crd(x) || '" y1="' || crd(y + 6) || '" y2="210" stroke="' || col || '" class="stem"/>');
        p('<circle cx="' || crd(x) || '" cy="210" r="5" fill="' || col || '"/>');
        p('<text x="' || crd(CASE WHEN flip THEN x - 7 ELSE x + 7 END) || '" y="' || crd(y) || '" class="ev" fill="' || col || '"'
          || CASE WHEN flip THEN ' text-anchor="end"' END || '>' || esc(lab)
          || CASE WHEN sfx IS NOT NULL THEN '<tspan class="evc">' || esc(sfx) || '</tspan>' END || '</text>');
        p('<text x="' || crd(CASE WHEN flip THEN x - 7 ELSE x + 7 END) || '" y="' || crd(y + 15) || '" class="evs"'
          || CASE WHEN flip THEN ' text-anchor="end"' END || '>' || sub || '</text>');
      END IF;
    END LOOP;
    IF rt IS NOT NULL OR n_drop > 0 THEN
      p('<text x="' || crd(sx(c_span)) || '" y="60" class="evs" text-anchor="end">' || rt
        || CASE WHEN n_drop > 0 THEN CASE WHEN rt IS NOT NULL THEN ', ' END || '+' || n_drop || ' more' END
        || ' &rarr;</text>');
    END IF;
    IF ev.COUNT = 0 THEN
      p('<text x="540" y="125" class="evs" text-anchor="middle">No limit is reached in the next 12 months.</text>');
    END IF;
    p('</svg>');
  END runway;

  FUNCTION nice(p_raw IN NUMBER) RETURN NUMBER IS
    mag NUMBER;
    nrm NUMBER;
  BEGIN
    IF p_raw <= 0 THEN RETURN 1; END IF;
    mag := POWER(10, FLOOR(LOG(10, p_raw)));
    nrm := p_raw / mag;
    RETURN CASE WHEN nrm <= 1 THEN 1 WHEN nrm <= 2 THEN 2 WHEN nrm <= 2.5 THEN 2.5 WHEN nrm <= 3 THEN 3
                WHEN nrm <= 5 THEN 5 ELSE 10 END * mag;
  END nice;

  ----------------------------------------------------------------------
  -- One evidence panel: history (CAPR_SERIES_POINTS, last 150 days) and the
  -- REGR forecast (CAPR_FORECAST_POINTS) on the left, the facts on the right.
  ----------------------------------------------------------------------
  PROCEDURE panel(ai IN PLS_INTEGER) IS
    c_w  CONSTANT NUMBER := 700;
    c_h  CONSTANT NUMBER := 300;
    c_pl CONSTANT NUMBER := 46;
    c_pr CONSTANT NUMBER := 18;
    c_pt CONSTANT NUMBER := 18;
    c_pb CONSTANT NUMBER := 34;
    fi     PLS_INTEGER   := t_act(ai).fit_ix;
    f      c_fit%ROWTYPE := t_fit(t_act(ai).fit_ix);
    v_sc   NUMBER := CASE WHEN t_fit(t_act(ai).fit_ix).kind = 'TBSPC' THEN c_gib ELSE 1 END;
    v_xmin NUMBER := -150;
    v_xmax NUMBER := GREATEST(60, LEAST(365, NVL(t_fit(t_act(ai).fit_ix).days_to_full, 0) + 20));
    v_lim  NUMBER;
    v_line NUMBER;
    col    VARCHAR2(20) := sev_col(t_act(ai).sev);
    hx num_tab; hy num_tab; ha num_tab;
    gx num_tab; gv num_tab; glo num_tab; ghi num_tab;
    v_ymin NUMBER;
    v_ymax NUMBER;
    v_step NUMBER;
    v      NUMBER;
    w      NUMBER;
    x      NUMBER;
    y      NUMBER;
    ph NUMBER; pv NUMBER; plo NUMBER; phi NUMBER;
    pth    VARCHAR2(32767);
    blo    VARCHAR2(32767);
    bhi    VARCHAR2(32767);
    n_an   PLS_INTEGER := 0;
    ax     NUMBER;
    ay     NUMBER;
    m      DATE;
    v_esm  NUMBER;
    v_regr NUMBER;
    v_esmh NUMBER;
    v_who  VARCHAR2(4000);
    v_verd VARCHAR2(1000);
    best   PLS_INTEGER;
    lab    VARCHAR2(200);
    FUNCTION px(t IN NUMBER) RETURN NUMBER IS
    BEGIN
      RETURN c_pl + (c_w - c_pl - c_pr) * (t - v_xmin) / (v_xmax - v_xmin);
    END px;
    FUNCTION py(p_v IN NUMBER) RETURN NUMBER IS
    BEGIN
      RETURN c_pt + (c_h - c_pt - c_pb) * (1 - (p_v - v_ymin) / (v_ymax - v_ymin));
    END py;
    PROCEDURE grow(p_v IN NUMBER) IS
    BEGIN
      IF p_v IS NOT NULL THEN
        v_ymin := LEAST(NVL(v_ymin, p_v), p_v);
        v_ymax := GREATEST(NVL(v_ymax, p_v), p_v);
      END IF;
    END grow;
    PROCEDURE addf(p_t IN NUMBER, p_v IN NUMBER, p_lo IN NUMBER, p_hi IN NUMBER) IS
      k PLS_INTEGER := gx.COUNT + 1;
    BEGIN
      gx(k) := p_t; gv(k) := p_v; glo(k) := p_lo; ghi(k) := p_hi;
      grow(p_v); grow(p_lo); grow(p_hi);
    END addf;
  BEGIN
    v_lim  := f.limit_value / v_sc;
    v_line := CASE WHEN f.kind = 'SERIES' THEN f.limit_value * sat_pct / 100 ELSE f.limit_value END / v_sc;

    FOR rr IN (SELECT ts - f.last_day AS t, value / v_sc AS v, anomaly
               FROM   capr_series_points
               WHERE  dbid = f.dbid AND con_dbid = f.con_dbid AND kind = f.kind AND series = f.series
                 AND  ts > f.last_day + v_xmin AND ts <= f.last_day AND value IS NOT NULL
               ORDER  BY ts) LOOP
      hx(hx.COUNT + 1) := rr.t;
      hy(hy.COUNT + 1) := rr.v;
      ha(ha.COUNT + 1) := rr.anomaly;
      grow(rr.v);
    END LOOP;

    FOR rr IN (SELECT horizon_days AS h, value / v_sc AS v,
                      NVL(lo, value) / v_sc AS lo, NVL(hi, value) / v_sc AS hi
               FROM   capr_forecast_points
               WHERE  dbid = f.dbid AND con_dbid = f.con_dbid AND kind = f.kind AND series = f.series
                 AND  method = 'REGR' AND value IS NOT NULL
                 AND  (horizon_days IN (0, 30, 90) OR (f.kind = 'TBSPC' AND horizon_days IN (180, 365)))
               ORDER  BY horizon_days) LOOP
      IF rr.h <= v_xmax THEN
        addf(rr.h, rr.v, rr.lo, rr.hi);
      ELSIF ph IS NOT NULL AND ph < v_xmax THEN
        w := (v_xmax - ph) / (rr.h - ph);
        addf(v_xmax, pv + w * (rr.v - pv), plo + w * (rr.lo - plo), phi + w * (rr.hi - phi));
        EXIT;
      ELSE
        EXIT;
      END IF;
      ph := rr.h; pv := rr.v; plo := rr.lo; phi := rr.hi;
    END LOOP;

    grow(v_lim);
    grow(v_line);
    IF v_ymin IS NULL THEN v_ymin := 0; v_ymax := 1; END IF;
    v := v_ymax - v_ymin;
    IF v <= 0 THEN v := GREATEST(ABS(v_ymax), 1); END IF;
    y := v_ymin - 0.08 * v;
    IF v_ymin >= 0 THEN y := GREATEST(0, y); END IF;
    x := v_ymax + 0.08 * v;
    v_step := nice((x - y) / 5);
    v_ymin := FLOOR(y / v_step) * v_step;
    v_ymax := CEIL(x / v_step) * v_step;

    lab := lbl_t(fi);
    p('<section id="ev-' || ai || '" class="two">');
    p('<div><svg viewBox="0 0 700 300" class="chart" role="img" aria-label="' || esc(lab) || ' history and forecast">');
    p('<defs><linearGradient id="ga' || ai || '" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="var(--ink)" stop-opacity=".14"/>'
      || '<stop offset="1" stop-color="var(--ink)" stop-opacity="0"/></linearGradient></defs>');
    v := v_ymin;
    WHILE v <= v_ymax + v_step / 1000 LOOP
      p('<line x1="46" x2="682" y1="' || crd(py(v)) || '" y2="' || crd(py(v)) || '" class="grid"/><text x="38" y="'
        || crd(py(v) + 4) || '" class="ax" text-anchor="end">' || RTRIM(TO_CHAR(v, 'FM9999999990.99'), '.') || '</text>');
      v := v + v_step;
    END LOOP;
    m := TRUNC(f.last_day + v_xmin, 'MM');
    IF m <= f.last_day + v_xmin THEN m := ADD_MONTHS(m, 1); END IF;
    ax := -1000;
    WHILE m - f.last_day <= v_xmax LOOP
      x := px(m - f.last_day);
      IF ABS(x - px(0)) > 30 AND x - ax > 34 THEN
        p('<text x="' || crd(x) || '" y="288" class="ax" text-anchor="middle">'
          || TO_CHAR(m, 'Mon', 'NLS_DATE_LANGUAGE=ENGLISH') || '</text>');
        ax := x;
      END IF;
      m := ADD_MONTHS(m, 1);
    END LOOP;
    p('<text x="' || crd(px(0)) || '" y="288" class="ax" text-anchor="middle">today</text>');

    IF hx.COUNT > 0 THEN
      pth := NULL;
      FOR k IN 1 .. hx.COUNT LOOP
        pth := pth || CASE WHEN k = 1 THEN 'M' ELSE ' L' END || crd(px(hx(k))) || ',' || crd(py(hy(k)));
      END LOOP;
      p('<path d="' || pth || ' L' || crd(px(hx(hx.COUNT))) || ',' || crd(py(v_ymin)) || ' L' || crd(px(hx(1))) || ','
        || crd(py(v_ymin)) || ' Z" fill="url(#ga' || ai || ')"/>');
    END IF;
    IF gx.COUNT > 1 THEN
      blo := NULL;
      FOR k IN REVERSE 1 .. gx.COUNT LOOP
        blo := blo || ' L' || crd(px(gx(k))) || ',' || crd(py(glo(k)));
      END LOOP;
      bhi := NULL;
      FOR k IN 1 .. gx.COUNT LOOP
        bhi := bhi || CASE WHEN k = 1 THEN 'M' ELSE ' L' END || crd(px(gx(k))) || ',' || crd(py(ghi(k)));
      END LOOP;
      p('<path d="' || bhi || blo || ' Z" fill="' || col || '" opacity=".13"/>');
    END IF;
    IF hx.COUNT > 0 THEN
      p('<path d="' || pth || '" fill="none" stroke="var(--ink)" stroke-width="1.8"/>');
    END IF;
    IF gx.COUNT > 1 THEN
      bhi := NULL;
      FOR k IN 1 .. gx.COUNT LOOP
        bhi := bhi || CASE WHEN k = 1 THEN 'M' ELSE ' L' END || crd(px(gx(k))) || ',' || crd(py(gv(k)));
      END LOOP;
      p('<path d="' || bhi || '" fill="none" stroke="' || col || '" stroke-width="2" stroke-dasharray="5 4"/>');
    END IF;
    IF v_lim IS NOT NULL THEN
      p('<line x1="46" x2="682" y1="' || crd(py(v_lim)) || '" y2="' || crd(py(v_lim)) || '" stroke="' || col || '" stroke-width="1.2"/>');
      p('<text x="52" y="' || crd(py(v_lim) - 6) || '" class="lab" fill="' || col || '">'
        || CASE f.kind WHEN 'TBSPC' THEN 'limit ' || num(v_lim) || ' GiB'
                       WHEN 'CPU' THEN fx0(v_lim) || '% line'
                       ELSE 'limit ' || num(v_lim) || unit_sfx(f.unit) END || '</text>');
    END IF;
    p('<line x1="' || crd(px(0)) || '" x2="' || crd(px(0)) || '" y1="18" y2="266" class="today"/>');
    FOR k IN 1 .. hx.COUNT LOOP
      IF ha(k) = 1 THEN
        n_an := n_an + 1;
        ax := px(hx(k));
        ay := py(hy(k));
        p('<circle cx="' || crd(ax) || '" cy="' || crd(ay) || '" r="3.2" fill="var(--paper)" stroke="var(--warn)" stroke-width="1.8"/>');
      END IF;
    END LOOP;
    IF f.days_to_full > 0 AND f.days_to_full <= v_xmax AND v_line IS NOT NULL THEN
      x := px(f.days_to_full);
      y := py(v_line);
      p('<circle cx="' || crd(x) || '" cy="' || crd(y) || '" r="6" fill="' || col || '"/>');
      p('<text x="' || crd(CASE WHEN x + 100 > c_w THEN x - 10 ELSE x + 10 END) || '" y="'
        || crd(CASE WHEN x + 100 > c_w THEN y - 12 ELSE y + 20 END) || '" class="lab" fill="' || col || '"'
        || CASE WHEN x + 100 > c_w THEN ' text-anchor="end"' END || '>'
        || CASE f.kind WHEN 'TBSPC' THEN 'full ' ELSE ev_what(fi, TRUE) || ' on ' END
        || dfmt(f.last_day + f.days_to_full, 'S') || '</text>');
    END IF;
    IF n_an > 0 THEN
      p('<text x="' || crd(CASE WHEN ax - 110 < c_pl THEN ax + 10 ELSE ax - 10 END) || '" y="'
        || crd(CASE WHEN ax - 110 < c_pl THEN ay + 18 ELSE ay - 10 END)
        || '" class="lab" fill="var(--warn)"' || CASE WHEN ax - 110 >= c_pl THEN ' text-anchor="end"' END || '>'
        || CASE WHEN n_an = 1 THEN 'one unusual day' ELSE n_an || ' unusual days' END || '</text>');
    END IF;
    p('</svg></div>');

    FOR k IN 1 .. t_al.COUNT LOOP
      IF t_al(k).dbid = f.dbid AND t_al(k).con_dbid = f.con_dbid AND t_al(k).series_key = f.series
         AND fam(t_al(k).kind) = f.kind AND t_al(k).kind LIKE '%\_ANOM' ESCAPE '\'
         AND t_al(k).n_days IS NOT NULL
         AND (best IS NULL OR t_al(k).n_days > t_al(best).n_days) THEN
        best := k;
      END IF;
    END LOOP;
    IF best IS NOT NULL THEN
      v_verd := CASE WHEN t_al(best).n_days = 1 THEN 'An unusual day on ' || dfmt(t_al(best).first_day, 'S')
                     ELSE words(t_al(best).n_days, TRUE) || ' unusual days since ' || dfmt(t_al(best).first_day, 'S') END
                || ', peak robust z ' || NVL(TO_CHAR(t_al(best).max_z, 'FMS99990.0'), 'off the scale') || '.';
    ELSIF f.accel > 1.5 THEN
      v_verd := 'Growth is ' || fx1(f.accel) || '&times; its 90-day rate.';
    END IF;

    IF show_esm <> 'N' THEN
      SELECT MAX(CASE WHEN series_kind = 'TBSPC' THEN esm_gb ELSE esm END),
             MAX(CASE WHEN series_kind = 'TBSPC' THEN regr_gb ELSE regr END),
             MAX(esm_horizon_days)
      INTO   v_esm, v_regr, v_esmh
      FROM   capr_esm_compare
      WHERE  dbid = f.dbid AND con_dbid = f.con_dbid AND series_kind = f.kind AND series_key = f.series
        AND  esm IS NOT NULL AND horizon_days = esm_horizon_days;
    END IF;
    IF f.kind = 'TBSPC' THEN
      FOR rr IN (SELECT owner, object_name, share_pct
                 FROM   capr_segment_growth
                 WHERE  dbid = f.dbid AND con_dbid = f.con_dbid AND tablespace_name = f.series
                   AND  rank_in_tbspc <= 3
                 ORDER  BY rank_in_tbspc) LOOP
        v_who := v_who || CASE WHEN v_who IS NOT NULL THEN ', ' END || '<code>' || esc(rr.owner || '.' || rr.object_name)
                 || '</code> ' || fx0(rr.share_pct) || '%';
      END LOOP;
    END IF;

    p('<div>');
    IF v_verd IS NOT NULL THEN
      p('<p class="verdict ' || LOWER(t_act(ai).sev) || '">' || v_verd || '</p>');
    END IF;
    p('<dl class="facts">'
      || CASE f.kind
           WHEN 'TBSPC' THEN '<dt>Used</dt><dd>' || TO_CHAR(f.value / c_gib, 'FM999999990.0') || ' of '
                             || TO_CHAR(f.limit_value / c_gib, 'FM999999990.0') || ' GiB (' || TO_CHAR(f.pct, 'FM990.0') || '%)</dd>'
           WHEN 'CPU' THEN '<dt>Now</dt><dd>' || TO_CHAR(f.value, 'FM990.0') || '% (line ' || fx0(f.limit_value) || '%)</dd>'
           ELSE '<dt>Now</dt><dd>' || num(f.value) || unit_sfx(f.unit) || ' of ' || num(f.limit_value) || unit_sfx(f.unit)
                || ' (' || TO_CHAR(f.pct, 'FM990.0') || '%)</dd>'
         END
      || '<dt>Growth</dt><dd>'
      || CASE f.kind
           WHEN 'TBSPC' THEN rate_txt(f.slope_per_day) || '/day' || CASE WHEN f.accel > 1.5 THEN ', accelerating' END
           WHEN 'CPU' THEN TO_CHAR(f.slope_per_day, 'FMS990.00') || ' points/day'
           ELSE CASE WHEN f.slope_per_day >= 0 THEN '+' END || num(f.slope_per_day) || unit_sfx(f.unit) || '/day'
         END || '</dd>'
      || '<dt>' || CASE f.kind WHEN 'TBSPC' THEN 'Full' ELSE 'Reaches the line' END || '</dt><dd>'
      || CASE WHEN f.days_to_full IS NULL THEN 'not on the current trend'
              ELSE dfmt(f.last_day + f.days_to_full, 'S')
                   || CASE WHEN f.days_to_full_lo IS NOT NULL THEN ' (worst case ' || day_mon(f.last_day + f.days_to_full_lo, f.last_day + f.days_to_full)
                           || CASE WHEN f.days_to_full_hi IS NOT NULL THEN ', best ' || day_mon(f.last_day + f.days_to_full_hi, f.last_day + f.days_to_full) END
                           || ')' END
         END || '</dd>'
      || '<dt>Fit</dt><dd>' || esc(f.quality) || CASE WHEN f.r2 IS NOT NULL THEN ', R&sup2; ' || TO_CHAR(f.r2, 'FM990.00') END
      || ' over ' || f.train_n || ' days</dd>'
      || CASE WHEN v_esm IS NOT NULL THEN
                '<dt>Second model</dt><dd>Exponential smoothing '
                || CASE WHEN v_regr IS NOT NULL AND ABS(v_esm - v_regr) <= 0.1 * ABS(v_regr) THEN 'agrees: '
                        ELSE 'differs: ' END
                || num(v_esm) || CASE WHEN f.kind = 'TBSPC' THEN ' GiB' WHEN f.kind = 'CPU' THEN '%' ELSE unit_sfx(f.unit) END
                || ' at +' || v_esmh || ' d'
                || CASE WHEN v_regr IS NOT NULL AND ABS(v_esm - v_regr) > 0.1 * ABS(v_regr)
                        THEN ', against ' || num(v_regr) || ' on the trend line' END || '</dd>'
              WHEN show_esm = 'Y' THEN '<dt>Second model</dt><dd>no trained model for this series</dd>'
         END
      || CASE WHEN v_who IS NOT NULL THEN '<dt>Who fills it</dt><dd>' || v_who || '</dd>' END
      || '</dl></div>');
    p('</section>');
  END panel;

BEGIN
  p('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">');
  p('<title>Capacity briefing, ' || esc(cap_db) || '</title><style>');
  p(':root{--paper:#f6f7f9;--sheet:#fff;--ink:#16243b;--ink-2:#41506a;--mute:#6c778a;--rule:#dfe3ea;');
  p('--crit:#c4262e;--crit-wash:#fbe9e9;--warn:#b86e00;--warn-wash:#fdf3e1;--ok:#23775a;');
  p('--serif:Charter,"Bitstream Charter","Iowan Old Style","Sitka Text",C059,Georgia,serif;');
  p('--sans:"Avenir Next","Segoe UI Variable Text","Segoe UI","Noto Sans",system-ui,sans-serif;');
  p('--mono:"SF Mono","Cascadia Mono","JetBrains Mono",Hack,"DejaVu Sans Mono",monospace}');
  p('*{box-sizing:border-box} body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.55 var(--sans)}');
  p('.page{max-width:1180px;margin:0 auto;padding:40px 48px 80px;background:var(--sheet);min-height:100vh}');
  p('.mast{display:flex;justify-content:space-between;align-items:baseline;border-bottom:2px solid var(--ink);padding-bottom:10px;font-size:13px;color:var(--mute)}');
  p('.mast b{color:var(--ink);font-size:15px;letter-spacing:.01em}');
  p('.gen{color:var(--mute);font-size:12px;margin:8px 0 0}');
  p('h1{font:400 44px/1.12 var(--serif);margin:34px 0 10px;max-width:26ch;letter-spacing:-.01em}');
  p('.lede{font:17px/1.6 var(--serif);color:var(--ink-2);max-width:62ch;margin:0 0 30px}');
  p('.runway{width:100%;height:auto;display:block}');
  p('.runway .win{font:12px var(--sans);fill:var(--mute)} .runway .tick{stroke:var(--rule)}');
  p('.runway .axis{stroke:var(--ink);stroke-width:1.2} .runway .mon{font:12px var(--sans);fill:var(--mute)}');
  p('.runway .strong{fill:var(--ink);font-weight:600} .today{stroke:var(--ink);stroke-width:1.2;stroke-dasharray:2 3}');
  p('.runway .stem{stroke-width:1.2;opacity:.6} .runway .ev{font:600 13px var(--mono)} .runway .evs{font:12px var(--sans);fill:var(--mute)}');
  p('.runway .evc{font:400 12px var(--sans);fill:var(--mute)}');
  p('h2{font:400 26px/1.2 var(--serif);margin:56px 0 6px} .sub{color:var(--mute);margin:0 0 20px;max-width:70ch}');
  p('h3{font:400 20px/1.25 var(--serif);margin:40px 0 14px} h3 code{font-size:17px} h3 .h3c{font:13px var(--sans);color:var(--mute);margin-left:8px}');
  p('.todo{list-style:none;padding:0;margin:0;counter-reset:t;display:grid;gap:0}');
  p('.todo li{display:grid;grid-template-columns:110px 1fr auto;gap:20px;padding:16px 0;border-top:1px solid var(--rule);align-items:baseline}');
  p('.todo li:last-child{border-bottom:1px solid var(--rule)}');
  p('.todo .by{font-weight:600;font-variant-numeric:tabular-nums}');
  p('.todo li.crit .by{color:var(--crit)} .todo li.warn .by{color:var(--warn)}');
  p('.todo p{margin:0;font:16px/1.5 var(--serif)} .todo small{display:block;color:var(--mute);font:13px var(--sans);margin-top:2px}');
  p('.todo a{color:var(--ink-2);font-size:13px;white-space:nowrap}');
  p('.beh{list-style:none;padding:0;margin:0}');
  p('.beh li{display:grid;grid-template-columns:110px 1fr;gap:20px;padding:9px 0;border-top:1px solid var(--rule);font-size:13.5px;color:var(--ink-2)}');
  p('.beh li:last-child{border-bottom:1px solid var(--rule)} .beh .by{font-weight:600;color:var(--warn);font-variant-numeric:tabular-nums}');
  p('.beh li.crit .by{color:var(--crit)}');
  p('code{font:13px var(--mono)}');
  p('.two{display:grid;grid-template-columns:1.55fr 1fr;gap:40px;align-items:start}');
  p('.chart{width:100%;height:auto} .chart .grid{stroke:var(--rule)} .chart .ax{font:11.5px var(--sans);fill:var(--mute)} .chart .lab{font:600 12px var(--sans)}');
  p('.facts{margin:0;display:grid;grid-template-columns:auto 1fr;gap:10px 18px;font-size:14px}');
  p('.facts dt{color:var(--mute)} .facts dd{margin:0;font-variant-numeric:tabular-nums}');
  p('.verdict{font:18px/1.5 var(--serif);border-left:3px solid var(--crit);padding:2px 0 2px 16px;margin:0 0 22px} .verdict.warn{border-left-color:var(--warn)}');
  p('table{width:100%;border-collapse:collapse} th{text-align:left;font-weight:500;color:var(--mute);font-size:12.5px;padding:0 0 8px;border-bottom:1px solid var(--ink)}');
  p('td{padding:11px 0;border-bottom:1px solid var(--rule);vertical-align:middle} td small{display:block;color:var(--mute);font-size:12px}');
  p('td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;padding-left:20px} td.n span{color:var(--mute);font-size:12.5px}');
  p('td.when span{display:block} tr.crit td.when{color:var(--crit);font-weight:600} tr.warn td:first-child code{color:var(--warn)} tr.crit td:first-child code{color:var(--crit)}');
  p('.tank{width:34%;padding-left:24px} .track{position:relative;height:10px;background:#eceff4;border-radius:2px}');
  p('.track i{position:absolute;top:0;bottom:0;left:0;border-radius:2px} .track .now{background:var(--ink)}');
  p('tr.crit .track .now{background:var(--crit)} tr.warn .track .now{background:var(--warn)}');
  p('.track .ghost{background:repeating-linear-gradient(135deg,var(--ink-2) 0 2px,transparent 2px 5px);opacity:.55}');
  p('.track .ghost.over{background:repeating-linear-gradient(135deg,var(--crit) 0 2px,transparent 2px 5px);opacity:.9}');
  p('.legend{display:flex;gap:22px;color:var(--mute);font-size:12.5px;margin:10px 0 0} .legend i{display:inline-block;width:22px;height:8px;vertical-align:middle;margin-right:6px;border-radius:2px}');
  p('.quiet{color:var(--mute);font-size:14px;margin-top:26px;max-width:80ch} .quiet code{color:var(--ink-2)}');
  p('.sec-fail{border:1px solid var(--crit);background:var(--crit-wash);color:var(--crit);padding:10px 14px;margin:18px 0;font-size:14px}');
  p('footer{margin-top:56px;padding-top:12px;border-top:1px solid var(--rule);color:var(--mute);font-size:12.5px;max-width:110ch}');
  p('@media print{body{background:#fff} .page{padding:0}}');
  p('</style></head><body><div class="page">');

  BEGIN
    SELECT dtf_warn, dtf_crit, cpu_sat_pct, nearfull_warn_pct, nearfull_crit_pct, series_sat_pct
    INTO   dtf_warn, dtf_crit, cpu_sat, nf_warn, nf_crit, sat_pct
    FROM   cap_cfg;
    SELECT MAX(last_ok_run_id) INTO v_snap_run FROM capr_runs;
    IF s_dbid IS NOT NULL OR s_con IS NOT NULL THEN
      SELECT 'scope ' || TRIM(CASE WHEN s_dbid IS NOT NULL THEN 'dbid ' || s_dbid END
                              || CASE WHEN s_con IS NOT NULL THEN ' con_dbid ' || s_con END)
             || ' (' || NVL(LISTAGG(db_pdb, ', ') WITHIN GROUP (ORDER BY db_pdb), 'no such container') || ')'
        INTO v_scope_lbl
        FROM capr_container
       WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
    END IF;
    IF v_src = 'SNAPSHOT' THEN
      v_src_lbl := 'SNAPSHOT: no OK refresh run yet, so there are no fits or alerts to brief';
      FOR r IN (SELECT run_id, started_at, as_of_day FROM capr_runs WHERE run_id = last_ok_run_id) LOOP
        v_src_lbl := 'SNAPSHOT: fits and alerts from refresh run ' || r.run_id || ' at '
                     || TO_CHAR(r.started_at, 'YYYY-MM-DD HH24:MI') || ' (as of ' || TO_CHAR(r.as_of_day, 'YYYY-MM-DD') || ')';
      END LOOP;
    ELSE
      v_src_lbl := 'live evaluation';
    END IF;
    OPEN c_fit;
    FETCH c_fit BULK COLLECT INTO t_fit;
    CLOSE c_fit;
    OPEN c_al;
    FETCH c_al BULK COLLECT INTO t_al;
    CLOSE c_al;
    FOR i IN 1 .. t_fit.COUNT LOOP
      v_today := GREATEST(NVL(v_today, t_fit(i).last_day), t_fit(i).last_day);
    END LOOP;
    v_today := NVL(v_today, TRUNC(SYSDATE));
    build_actions;
    build_beh;
  EXCEPTION
    WHEN OTHERS THEN
      v_load_err := SQLERRM;
      v_today := NVL(v_today, TRUNC(SYSDATE));
  END;

  -- Masthead
  DECLARE
    v_dbn  VARCHAR2(1000);
    v_ncon PLS_INTEGER;
    v_hist NUMBER;
    v_nesm PLS_INTEGER := 0;
  BEGIN
    SELECT LISTAGG(db_name, ', ') WITHIN GROUP (ORDER BY db_name)
    INTO   v_dbn
    FROM  (SELECT DISTINCT db_name FROM capr_container
           WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con));
    SELECT COUNT(*) INTO v_ncon FROM capr_container
    WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
    SELECT MAX(history_days) INTO v_hist FROM capr_coverage WHERE (s_dbid IS NULL OR dbid = s_dbid);
    IF show_esm <> 'N' THEN
      SELECT COUNT(DISTINCT dbid || '|' || con_dbid || '|' || series_kind || '|' || series_key) INTO v_nesm
      FROM   capr_esm_compare
      WHERE  esm IS NOT NULL
        AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
    END IF;
    p('<div class="mast"><span><b>' || esc(NVL(v_dbn, cap_db)) || '</b> &nbsp;' || esc(cap_host)
      || ', ' || words(v_ncon) || CASE WHEN v_ncon = 1 THEN ' container' ELSE ' containers' END
      || CASE WHEN v_hist IS NOT NULL THEN ', ' || fx0(v_hist) || ' days of AWR' END
      || '</span><span>Capacity briefing for ' || TO_CHAR(v_today, 'FMDD Month YYYY', 'NLS_DATE_LANGUAGE=ENGLISH') || '</span></div>');
    p('<p class="gen">Generated ' || esc(cap_gen) || ' from schema ' || esc(cap_user)
      || CASE WHEN v_scope_lbl IS NOT NULL THEN ' &middot; ' || esc(v_scope_lbl) END
      || ' &middot; ' || esc(v_src_lbl)
      || CASE WHEN v_nesm > 0 THEN ' &middot; Tier 2: ' || v_nesm || ' series also modelled by exponential smoothing'
              WHEN show_esm = 'Y' THEN ' &middot; Tier 2: no trained models' END
      || '</p>');
  EXCEPTION
    WHEN OTHERS THEN sec_failed('masthead', SQLERRM);
  END;

  -- Headline and lede
  DECLARE
    n_crit PLS_INTEGER := 0;
    n_ok   PLS_INTEGER := 0;
    n      PLS_INTEGER;
    h      VARCHAR2(2000);
    l      VARCHAR2(4000);
    nx     PLS_INTEGER;
  BEGIN
    need_load;
    n := t_act.COUNT;
    FOR j IN 1 .. n LOOP
      IF t_act(j).sev = 'CRIT' THEN n_crit := n_crit + 1; END IF;
    END LOOP;
    FOR i IN 1 .. t_fit.COUNT LOOP
      IF t_fit(i).quality = 'OK' THEN n_ok := n_ok + 1; END IF;
    END LOOP;
    IF n > 0 AND t_act(1).kind = 'DATA_STALE' THEN
      h := 'AWR data stopped arriving ' || fx0(t_al(t_act(1).al_ix).value) || ' hours ago.';
      l := 'Every date below is frozen at the last snapshot.';
      IF n > 1 THEN
        l := l || ' ' || words(n - 1, TRUE) || ' more ' || CASE WHEN n = 2 THEN 'item needs' ELSE 'items need' END
             || ' attention: ' || act_list(2, 3) || '.';
      END IF;
    ELSIF n > 0 AND t_act(1).sev = 'CRIT' THEN
      h := crit_headline(1);
      l := CASE WHEN n_crit = 1 THEN 'That is the only critical item.'
                ELSE 'It is one of ' || words(n_crit) || ' critical items.' END;
      IF n > 1 THEN
        l := l || ' ' || words(n - 1, TRUE) || ' more ' || CASE WHEN n = 2 THEN 'needs' ELSE 'need' END
             || ' attention: ' || act_list(2, 3) || '.';
      END IF;
    ELSIF n > 0 THEN
      h := 'Nothing is critical. ' || words(n, TRUE) || CASE WHEN n = 1 THEN ' item needs' ELSE ' items need' END
           || ' attention, '
           || CASE WHEN t_act(1).by_day IS NULL THEN CASE WHEN n = 1 THEN 'now' ELSE 'one of them now' END
                   ELSE CASE WHEN n > 1 THEN 'the first ' END || 'by ' || dfmt(t_act(1).by_day, 'S') END || '.';
      l := 'In order: ' || act_list(1, 3) || '.';
    ELSIF t_fit.COUNT = 0 THEN
      h := 'There is nothing to brief from yet.';
      l := CASE WHEN v_src = 'SNAPSHOT' AND v_snap_run IS NULL
                THEN 'SNAPSHOT reads the last OK refresh run and there is none. Run <code>cap_results.refresh</code>, or brief LIVE.'
                ELSE 'There are no current forecasts or alerts in this scope.' END;
    ELSE
      h := 'Nothing needs attention.';
      FOR i IN 1 .. t_fit.COUNT LOOP
        IF on_runway(i) AND t_fit(i).days_to_full <= 365
           AND (nx IS NULL OR t_fit(i).days_to_full < t_fit(nx).days_to_full) THEN
          nx := i;
        END IF;
      END LOOP;
      IF nx IS NOT NULL THEN
        l := 'The next limit is ' || esc(lbl_t(nx)) || ' on ' || dfmt(t_fit(nx).last_day + t_fit(nx).days_to_full, 'L') || '.';
      END IF;
    END IF;
    IF t_fit.COUNT > 0 THEN
      l := LTRIM(l || ' ' || words(n_ok, TRUE) || ' of ' || words(t_fit.COUNT) || ' forecasts are reliable.');
    END IF;
    p('<h1>' || h || '</h1>');
    p('<p class="lede">' || l || '</p>');
  EXCEPTION
    WHEN OTHERS THEN sec_failed('headline', SQLERRM);
  END;

  BEGIN
    need_load;
    runway;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('runway', SQLERRM);
  END;

  -- What to do, by date
  BEGIN
    need_load;
    p('<h2>What to do, by date</h2>');
    IF t_act.COUNT = 0 AND t_fit.COUNT = 0 THEN
      p('<p class="quiet">Nothing to list without forecasts.</p>');
    ELSIF t_act.COUNT = 0 THEN
      p('<p class="quiet">Nothing to do. Every forecast stays clear of its limit for at least ' || fx0(dtf_warn) || ' days.</p>');
    ELSE
      p('<p class="sub">Each item has a worst-case date, taken from the upper 95% band of its forecast.</p>');
      p('<ol class="todo">');
      FOR j IN 1 .. LEAST(t_act.COUNT, top_n) LOOP
        p('<li class="' || LOWER(t_act(j).sev) || '"><span class="by">' || when_txt(j) || '</span><p>' || t_act(j).sent
          || CASE WHEN t_act(j).detail IS NOT NULL THEN '<small>' || t_act(j).detail || '</small>' END || '</p>'
          || CASE WHEN t_act(j).ev IS NOT NULL THEN '<a href="#ev-' || j || '">Show evidence</a>' ELSE '<span></span>' END
          || '</li>');
      END LOOP;
      p('</ol>');
      IF t_act.COUNT > top_n THEN
        p('<p class="quiet">' || words(t_act.COUNT - top_n, TRUE) || ' more, in report/report_html.sql.</p>');
      END IF;
    END IF;
    IF t_beh.COUNT > 0 THEN
      p('<h3>Also unusual, last ' || anomaly_days || ' days</h3>');
      p('<ul class="beh">');
      FOR k IN 1 .. LEAST(t_beh.COUNT, top_n) LOOP
        p('<li class="' || LOWER(t_al(t_beh(k)).severity) || '"><span class="by">' || dfmt(t_al(t_beh(k)).day_dt, 'S')
          || '</span><span>' || esc(t_al(t_beh(k)).message) || '</span></li>');
      END LOOP;
      p('</ul>');
      IF t_beh.COUNT > top_n THEN
        p('<p class="quiet">+' || (t_beh.COUNT - top_n) || ' more.</p>');
      END IF;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('what to do', SQLERRM);
  END;

  -- Evidence
  DECLARE
    first BOOLEAN := TRUE;
  BEGIN
    need_load;
    FOR j IN 1 .. t_act.COUNT LOOP
      IF t_act(j).ev IS NOT NULL THEN
        BEGIN
          IF first THEN
            p('<h2>' || CASE WHEN t_act(j).sev = 'CRIT' THEN 'The critical one' ELSE 'Evidence' END || '</h2>');
          END IF;
          IF NOT first OR t_act(j).sev <> 'CRIT' THEN
            p('<h3>' || lbl_h(t_act(j).fit_ix) || '<span class="h3c">' || esc(t_fit(t_act(j).fit_ix).con_name) || '</span></h3>');
          END IF;
          first := FALSE;
          panel(j);
        EXCEPTION
          WHEN OTHERS THEN sec_failed('evidence ' || t_act(j).ev, SQLERRM);
        END;
      END IF;
    END LOOP;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('evidence', SQLERRM);
  END;

  -- Every tablespace
  DECLARE
    n_ts   PLS_INTEGER := 0;
    n_rest PLS_INTEGER := 0;
    n_hot  PLS_INTEGER := 0;
    f      c_fit%ROWTYPE;
    v_p90  NUMBER;
    v_gh   NUMBER;
    v_when VARCHAR2(400);
    v_gro  VARCHAR2(200);
  BEGIN
    need_load;
    FOR i IN 1 .. t_fit.COUNT LOOP
      IF t_fit(i).kind = 'TBSPC' THEN n_ts := n_ts + 1; END IF;
    END LOOP;
    IF n_ts > 0 THEN
      p('<h2>Every tablespace</h2>');
      p('<p class="sub">Solid bar: used today. Hatched: where it will be in 90 days. Red hatching runs past the limit.</p>');
      p('<table><thead><tr><th>Tablespace</th><th class="tank">Fill, now and in 90 days</th><th class="n">Used</th>'
        || '<th class="n">Growth</th><th class="n">Full in</th></tr></thead><tbody>');
      n_ts := 0;
      FOR i IN 1 .. t_fit.COUNT LOOP
        IF t_fit(i).kind = 'TBSPC' THEN
          n_ts := n_ts + 1;
          f := t_fit(i);
          IF n_ts > top_n THEN
            n_rest := n_rest + 1;
            IF f.sev <> 'OK' THEN n_hot := n_hot + 1; END IF;
          ELSE
            v_p90 := (f.value + 90 * NVL(f.slope_per_day, 0)) / NULLIF(f.limit_value, 0) * 100;
            v_gh  := GREATEST(LEAST(NVL(v_p90, 0), 100) - NVL(f.pct, 0), 0);
            v_when := CASE WHEN f.limit_below_used = 1 THEN 'limit below usage'
                           WHEN f.quality = 'CYCLIC' THEN 'purges every ' || NVL(fx0(f.cycle_days), '?') || ' d'
                           WHEN f.quality = 'FLAT' THEN 'not growing'
                           WHEN f.days_to_full IS NOT NULL THEN fx0(f.days_to_full) || ' d <span>'
                                || dfmt(f.last_day + f.days_to_full, 'T') || '</span>'
                           ELSE LOWER(REPLACE(f.quality, '_', ' ')) END;
            v_gro := CASE WHEN ABS(NVL(f.slope_per_day, 0)) >= c_gib
                          THEN TO_CHAR(f.slope_per_day / c_gib, 'FMS9990.00') || ' <span>GiB/d</span>'
                          WHEN ROUND(NVL(f.slope_per_day, 0) / c_mib) = 0 THEN '0 <span>MiB/d</span>'
                          ELSE TO_CHAR(ROUND(f.slope_per_day / c_mib), 'FMS999990') || ' <span>MiB/d</span>' END;
            p('<tr' || CASE f.sev WHEN 'CRIT' THEN ' class="crit"' WHEN 'WARN' THEN ' class="warn"' END || '>'
              || '<td><code>' || esc(f.series) || '</code><small>' || esc(f.con_name) || '</small></td>'
              || '<td class="tank"><div class="track"><i class="now" style="width:' || TO_CHAR(LEAST(NVL(f.pct, 0), 100), 'FM990.0')
              || '%"></i><i class="ghost' || CASE WHEN v_p90 > 100 THEN ' over' END || '" style="left:'
              || TO_CHAR(LEAST(NVL(f.pct, 0), 100), 'FM990.0') || '%;width:' || TO_CHAR(v_gh, 'FM990.0') || '%"></i></div></td>'
              || '<td class="n">' || nz(f.value / c_gib, 'FM999999990.0') || ' <span>/ ' || num(f.limit_value / c_gib) || ' GiB</span></td>'
              || '<td class="n">' || v_gro || '</td>'
              || '<td class="n when">' || v_when || '</td></tr>');
          END IF;
        END IF;
      END LOOP;
      p('</tbody></table>');
      p('<div class="legend"><span><i style="background:var(--ink)"></i>used today</span>'
        || '<span><i style="background:repeating-linear-gradient(135deg,var(--ink-2) 0 2px,transparent 2px 5px);opacity:.55"></i>in 90 days</span>'
        || '<span><i style="background:repeating-linear-gradient(135deg,var(--crit) 0 2px,transparent 2px 5px)"></i>past the limit in 90 days</span></div>');
      IF n_rest > 0 THEN
        p('<p class="quiet">' || words(n_rest, TRUE) || ' more ' || CASE WHEN n_rest = 1 THEN 'tablespace' ELSE 'tablespaces' END
          || CASE WHEN n_hot = 0 THEN ', none near a limit.' ELSE '.' END || '</p>');
      END IF;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('every tablespace', SQLERRM);
  END;

  -- Quiet line: the healthy series nobody needs to look at.
  DECLARE
    TYPE s_tab IS TABLE OF VARCHAR2(800) INDEX BY PLS_INTEGER;
    nm    s_tab;
    used  ix_tab;
    n_ts  PLS_INTEGER := 0;
    n_all PLS_INTEGER := 0;
    v     VARCHAR2(8000);
    shown BOOLEAN;
  BEGIN
    need_load;
    FOR j IN 1 .. t_act.COUNT LOOP
      IF t_act(j).fit_ix IS NOT NULL THEN used(t_act(j).fit_ix) := 1; END IF;
    END LOOP;
    FOR i IN 1 .. t_fit.COUNT LOOP
      shown := FALSE;
      IF t_fit(i).kind = 'TBSPC' THEN
        n_ts := n_ts + 1;
        shown := n_ts <= top_n;
      END IF;
      IF t_fit(i).sev = 'OK' AND NOT used.EXISTS(i) AND NOT shown
         AND NOT (t_fit(i).kind = 'CPU' AND t_fit(i).series NOT IN ('BUSY_P95', 'DB_CPU_P95')) THEN
        n_all := n_all + 1;
        IF n_all <= 12 THEN
          nm(n_all) := lbl_h(i) || CASE WHEN t_fit(i).days_to_full <= 365
                                        THEN '&nbsp;(' || fx0(t_fit(i).days_to_full) || '&nbsp;d)' END;
        END IF;
      END IF;
    END LOOP;
    FOR k IN 1 .. nm.COUNT LOOP
      v := v || CASE WHEN k = 1 THEN NULL WHEN k = nm.COUNT AND n_all = nm.COUNT THEN ' and ' ELSE ', ' END || nm(k);
    END LOOP;
    IF n_all > nm.COUNT THEN
      v := v || ' and ' || words(n_all - nm.COUNT) || ' more';
    END IF;
    IF v IS NOT NULL THEN
      p('<p class="quiet">Nothing to do for ' || v || '.</p>');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('quiet line', SQLERRM);
  END;

  p('<footer>Read-only briefing from the CAPR views. The full report, with every table and the anomaly detail, is '
    || '<code>report/report_html.sql</code>. Thresholds: critical within ' || fx0(dtf_crit) || ' days, warning within '
    || fx0(dtf_warn) || ' days, CPU line ' || fx0(cpu_sat) || '%, near full at ' || fx0(nf_warn) || '% (critical '
    || fx0(nf_crit) || '%).'
    || CASE WHEN v_n_info > 0 THEN ' ' || words(v_n_info, TRUE) || ' informational '
                                   || CASE WHEN v_n_info = 1 THEN 'alert is' ELSE 'alerts are' END || ' not listed.' END
    || CASE WHEN v_failed > 0 THEN ' ' || words(v_failed, TRUE) || ' section' || CASE WHEN v_failed > 1 THEN 's' END
                                   || ' failed to render; see the red boxes above.' END
    || ' Written to reports/' || esc(cap_file) || '.</footer>');
  p('</div></body></html>');
END;
/

SPOOL OFF

SET DEFINE '&'
SET TERMOUT ON

UNDEFINE 1
UNDEFINE 2
UNDEFINE 3
UNDEFINE 4
UNDEFINE 5
UNDEFINE 6
PROMPT
PROMPT Report written to: &cap_path
PROMPT
