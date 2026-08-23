--
-- report/report_html.sql -- read-only, self-contained HTML capacity report.
-- =====================================================================
-- Spools a single-file HTML dashboard from the CAPF_/CAPA_ views to
-- reports/cap_report_<db>_<ts>.html. READ-ONLY: only SELECTs (the CAPF_ESM
-- views call a pipelined function, which writes nothing). Creates/modifies no
-- database object. This is a SIBLING of report/report.sql (the plain-text
-- report) -- it duplicates that SQL logic to render HTML instead; report.sql
-- and report/sections/*.sql are untouched.
--
-- Run from the REPO ROOT so the @@report/defaults.sql include resolves
-- (SQL*Plus @@ is relative to the outermost caller's directory on 19c):
--   sqlplus user/pw@svc
--   SQL> @report/report_html.sql
--
-- Requires the suite installed (any seam mode). Tier 2 rows appear only if
-- cap_forecast_ml.train_all has been run.
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

-- Presentation knobs (top_n / anomaly_days / show_esm). Loaded here so a bare
-- `@report/report_html.sql` never prompts / hangs on an undefined substitution
-- var. To change them, edit report/defaults.sql (single source of truth,
-- shared with the text report).
@@report/defaults.sql

-- --------------------------------------------------------------------
-- Resolve identity, config knobs, ESM availability, report path (once).
-- --------------------------------------------------------------------
COLUMN cap_db   NEW_VALUE cap_db   NOPRINT
COLUMN cap_host NEW_VALUE cap_host NOPRINT
COLUMN cap_user NEW_VALUE cap_user NOPRINT
COLUMN cap_gen  NEW_VALUE cap_gen  NOPRINT
COLUMN cap_path NEW_VALUE cap_path NOPRINT
COLUMN cap_file NEW_VALUE cap_file NOPRINT
COLUMN dtf_warn NEW_VALUE dtf_warn NOPRINT
COLUMN dtf_crit NEW_VALUE dtf_crit NOPRINT
COLUMN cpu_sat  NEW_VALUE cpu_sat  NOPRINT
COLUMN nf_warn  NEW_VALUE nf_warn  NOPRINT
COLUMN nf_crit  NEW_VALUE nf_crit  NOPRINT
COLUMN esm_ok   NEW_VALUE esm_ok   NOPRINT
COLUMN train_days     NEW_VALUE train_days     NOPRINT
COLUMN min_train_days NEW_VALUE min_train_days NOPRINT
COLUMN r2_gate        NEW_VALUE r2_gate        NOPRINT

-- Identity via SYS_CONTEXT (no catalog/v$ privileges needed, so the report
-- runs from any monitoring schema, not just one with SELECT_CATALOG_ROLE).
SELECT SYS_CONTEXT('USERENV','DB_NAME')
         || CASE WHEN TO_NUMBER(SYS_CONTEXT('USERENV','CON_ID')) NOT IN (0,1)
                 THEN ' / ' || SYS_CONTEXT('USERENV','CON_NAME') ELSE '' END  AS cap_db,
       SYS_CONTEXT('USERENV','SERVER_HOST')                                   AS cap_host,
       USER                                                                  AS cap_user,
       TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI:SS TZR')                      AS cap_gen,
       'cap_report_'
         || REGEXP_REPLACE(SYS_CONTEXT('USERENV','DB_NAME'),'[^A-Za-z0-9]+','_') || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MI') || '.html'                      AS cap_file,
       'reports/cap_report_'
         || REGEXP_REPLACE(SYS_CONTEXT('USERENV','DB_NAME'),'[^A-Za-z0-9]+','_') || '_'
         || TO_CHAR(SYSDATE,'YYYYMMDDHH24MI') || '.html'                       AS cap_path
FROM   dual;

-- Forecast knobs (train_days / min_train_days / r2_gate) are read here from
-- CAP_CONFIG -- the SAME knobs CAPF_TBSPC_FORECAST uses -- so the whole-database
-- hero in section 0 mirrors the per-tablespace training window and quality gates
-- exactly (never hard-coded, never able to drift from the per-tablespace method).
SELECT (SELECT cfg_value FROM cap_config WHERE cfg_name='dtf_warn')       AS dtf_warn,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='dtf_crit')       AS dtf_crit,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='cpu_sat_pct')    AS cpu_sat,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='nearfull_warn_pct') AS nf_warn,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='nearfull_crit_pct') AS nf_crit,
       (SELECT COUNT(*)  FROM cap_ml_model WHERE status='OK')             AS esm_ok,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='train_days')     AS train_days,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='min_train_days') AS min_train_days,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='r2_gate')        AS r2_gate
FROM   dual;

-- --------------------------------------------------------------------
-- Bind the substitution-variable knobs into SQL*Plus bind variables while
-- substitution is still active. The main PL/SQL block below emits a
-- number of HTML entity references as string literals; if substitution
-- stayed active while that block was scanned, SQL*Plus would try to treat
-- each one as an undefined substitution variable and prompt for a value.
-- Binding here, then disabling substitution before the main block,
-- sidesteps that entirely.
-- --------------------------------------------------------------------
VARIABLE b_top_n        NUMBER
VARIABLE b_anomaly_days NUMBER
VARIABLE b_show_esm     VARCHAR2(10)
VARIABLE b_dtf_warn     NUMBER
VARIABLE b_dtf_crit     NUMBER
VARIABLE b_cpu_sat      NUMBER
VARIABLE b_nf_warn      NUMBER
VARIABLE b_nf_crit      NUMBER
VARIABLE b_esm_ok       NUMBER
VARIABLE b_train_days     NUMBER
VARIABLE b_min_train_days NUMBER
VARIABLE b_r2_gate        NUMBER
VARIABLE b_cap_db       VARCHAR2(200)
VARIABLE b_cap_host     VARCHAR2(200)
VARIABLE b_cap_user     VARCHAR2(200)
VARIABLE b_cap_gen      VARCHAR2(200)
VARIABLE b_cap_file     VARCHAR2(200)

BEGIN
  :b_top_n        := &top_n;
  :b_anomaly_days := &anomaly_days;
  :b_show_esm     := UPPER('&show_esm');
  :b_dtf_warn     := &dtf_warn;
  :b_dtf_crit     := &dtf_crit;
  :b_cpu_sat      := &cpu_sat;
  :b_nf_warn      := &nf_warn;
  :b_nf_crit      := &nf_crit;
  :b_esm_ok       := &esm_ok;
  :b_train_days     := &train_days;
  :b_min_train_days := &min_train_days;
  :b_r2_gate        := &r2_gate;
  :b_cap_db       := '&cap_db';
  :b_cap_host     := '&cap_host';
  :b_cap_user     := '&cap_user';
  :b_cap_gen      := '&cap_gen';
  :b_cap_file     := '&cap_file';
END;
/

SPOOL &cap_path

SET DEFINE OFF

-- ======================================================================
-- Single anonymous PL/SQL block: builds the entire HTML document via
-- DBMS_OUTPUT.PUT_LINE, captured by SPOOL. Read-only: SELECTs only.
-- DEFINE is OFF here (see above) so literal HTML entities in string
-- literals are never mistaken for substitution variables.
-- ======================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
  top_n        PLS_INTEGER := :b_top_n;
  anomaly_days PLS_INTEGER := :b_anomaly_days;
  show_esm     VARCHAR2(10) := :b_show_esm;
  dtf_warn     NUMBER := :b_dtf_warn;
  dtf_crit     NUMBER := :b_dtf_crit;
  cpu_sat      NUMBER := :b_cpu_sat;
  nf_warn      NUMBER := :b_nf_warn;   -- near-full-now WARN percent (M7.1)
  nf_crit      NUMBER := :b_nf_crit;   -- near-full-now CRIT percent (M7.1)
  esm_ok       PLS_INTEGER := :b_esm_ok;
  -- Forecast knobs, same source (CAP_CONFIG) and meaning as CAPF_TBSPC_FORECAST.
  train_days     NUMBER := :b_train_days;      -- primary linear-fit window (days)
  min_train_days NUMBER := :b_min_train_days;  -- below this REGR_COUNT => INSUFFICIENT_HISTORY
  r2_gate        NUMBER := :b_r2_gate;         -- R2 below this => LOW_CONFIDENCE

  cap_db   VARCHAR2(200) := :b_cap_db;
  cap_host VARCHAR2(200) := :b_cap_host;
  cap_user VARCHAR2(200) := :b_cap_user;
  cap_gen  VARCHAR2(200) := :b_cap_gen;
  cap_file VARCHAR2(200) := :b_cap_file;

  do_esm   BOOLEAN;
  any_rows BOOLEAN;

  ----------------------------------------------------------------------
  -- Chart geometry constants (shared viewBox for every inline-SVG chart)
  -- and scratch variables for chart building. c_epoch matches the day_n
  -- epoch used by ddl/30_forecast_views.sql (DATE '2020-01-01') so day_n
  -- offsets computed here line up with slope_bpd / slope_per_day (per-day
  -- rates against that same epoch).
  ----------------------------------------------------------------------
  c_cw     CONSTANT NUMBER := 560;
  c_ch     CONSTANT NUMBER := 230;
  c_ml     CONSTANT NUMBER := 46;
  c_mr     CONSTANT NUMBER := 12;
  c_mt     CONSTANT NUMBER := 14;
  c_mb     CONSTANT NUMBER := 28;
  c_epoch  CONSTANT DATE   := DATE '2020-01-01';

  TYPE num_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  xs  num_tab;
  ys  num_tab;
  px1 num_tab;
  py1 num_tab;

  v_cnt        PLS_INTEGER;
  v_total_ts   PLS_INTEGER;
  v_last_day_n NUMBER;
  v_xmin       NUMBER;
  v_xmax       NUMBER;
  v_ymin       NUMBER;
  v_ymax       NUMBER;
  v_proj_y     NUMBER;
  v_esm_val    NUMBER;
  v_esm_lo     NUMBER;
  v_esm_hi     NUMBER;
  v_limit_gb   NUMBER;
  v_range      NUMBER;
  v_show_limit BOOLEAN;
  v_quality    VARCHAR2(30);
  v_slope      NUMBER;
  v_subtitle   VARCHAR2(500);

  ----------------------------------------------------------------------
  -- "At a glance" (section 0) scratch: plain-English best-guess cards +
  -- anomaly timeline. Timeline geometry is its own (full-width) viewBox,
  -- independent of the c_cw/c_ch chart box used by the per-series charts.
  ----------------------------------------------------------------------
  c_tlw   CONSTANT NUMBER := 1120;  -- timeline viewBox width
  c_tllm  CONSTANT NUMBER := 156;   -- timeline left margin (lane labels)
  c_tlrm  CONSTANT NUMBER := 18;    -- timeline right margin
  c_tlmt  CONSTANT NUMBER := 12;    -- timeline top margin
  c_tlmb  CONSTANT NUMBER := 26;    -- timeline bottom margin (date axis)
  c_lane  CONSTANT NUMBER := 26;    -- vertical pixels per lane

  v_card_count PLS_INTEGER;         -- cards emitted into the glance grid
  v_roll       VARCHAR2(2000);
  v_msg        VARCHAR2(1000);
  v_dom        VARCHAR2(40);
  v_n_flat     PLS_INTEGER;
  v_n_low      PLS_INTEGER;
  v_n_insuf    PLS_INTEGER;
  v_accent     VARCHAR2(8);
  v_conf       VARCHAR2(60);

  v_tl_min     DATE;
  v_tl_max     DATE;
  v_lane_total PLS_INTEGER;
  v_lane_i     PLS_INTEGER;
  v_lane_shown PLS_INTEGER;
  v_tl_h       NUMBER;
  v_axis_y     NUMBER;
  v_base_y     NUMBER;
  v_gd         DATE;
  v_tip        VARCHAR2(400);
  v_mult       NUMBER;
  v_delta_gb   NUMBER;

  ----------------------------------------------------------------------
  -- Hero charts (whole-database total size + host-CPU busy%, side by side in
  -- .hero-duo): a shared 560x250 viewBox -- each duo panel is about half width,
  -- so both use the same geometry through the explicit-geometry emit_*_box
  -- helpers. A touch taller than the per-series 560x230 charts to give the
  -- headline chart more room.
  ----------------------------------------------------------------------
  c_hw   CONSTANT NUMBER := 560;   -- hero chart viewBox width (both duo panels)
  c_hh   CONSTANT NUMBER := 250;   -- hero chart viewBox height
  c_hml  CONSTANT NUMBER := 48;    -- hero left margin (axis labels)
  c_hmr  CONSTANT NUMBER := 14;    -- hero right margin
  c_hmt  CONSTANT NUMBER := 14;    -- hero top margin
  c_hmb  CONSTANT NUMBER := 26;    -- hero bottom margin (date axis)

  v_con_count   PLS_INTEGER;       -- distinct con_dbid in the daily facts
  v_hlabel      VARCHAR2(200);
  v_hquality    VARCHAR2(30);
  v_hero_gb     NUMBER;
  v_proj_gb     NUMBER;
  v_hlimit_gb   NUMBER;            -- total allocated limit (GB), NULL if not meaningful
  v_rate_gb_mo  NUMBER;           -- signed slope in GB/month
  v_days_to_lim NUMBER;
  v_head        VARCHAR2(600);
  v_hpill       VARCHAR2(120);

  ----------------------------------------------------------------------
  -- Attention/status banner (very top of section 0): collect items into a
  -- string table, track the max severity, then render one banner. v_items
  -- entries are complete <li> strings so each is emitted on its own p() line
  -- (never approaching the 32767 DBMS_OUTPUT cap even with many items).
  ----------------------------------------------------------------------
  TYPE str_tab IS TABLE OF VARCHAR2(500) INDEX BY PLS_INTEGER;
  v_items      str_tab;
  v_nitems     PLS_INTEGER;
  v_max_sev    PLS_INTEGER;        -- 0 none, 1 warn, 2 crit
  v_anom_count PLS_INTEGER;        -- flagged tbspc+cpu days in the anomaly window
  v_banner_cls VARCHAR2(20);

  ----------------------------------------------------------------------
  -- cur_hero: the whole-database regression, one row per (dbid, con_dbid).
  -- Declared once and iterated TWICE -- first to gather the attention banner's
  -- whole-DB days-to-limit item, then to emit the hero(es) -- so the banner and
  -- the hero can never disagree. Gap-filled (day x tablespace grid +
  -- LAST_VALUE IGNORE NULLS) so an AWR-gap day cannot dip the total; mirrors
  -- CAPF_TBSPC_FORECAST's day_n epoch, train_days window and REGR_* aggregates.
  ----------------------------------------------------------------------
  CURSOR cur_hero IS
    SELECT f.dbid, f.con_dbid, f.last_day, f.last_day_n,
           f.slope, f.r2, f.n, c.cur_used, c.cur_limit, c.limit_all,
           f.icept + f.slope * (f.last_day_n + 180) AS proj_180
    FROM (
       SELECT t.dbid, t.con_dbid,
              MAX(t.last_day)   AS last_day,
              MAX(t.last_day_n) AS last_day_n,
              REGR_SLOPE(t.used_total, t.day_n)     AS slope,
              REGR_INTERCEPT(t.used_total, t.day_n) AS icept,
              REGR_R2(t.used_total, t.day_n)        AS r2,
              REGR_COUNT(t.used_total, t.day_n)     AS n
       FROM (
          SELECT g.dbid, g.con_dbid, g.day_dt,
                 g.day_dt - DATE '2020-01-01' AS day_n,
                 g.used_total,
                 MAX(g.day_dt) OVER (PARTITION BY g.dbid, g.con_dbid)                     AS last_day,
                 MAX(g.day_dt) OVER (PARTITION BY g.dbid, g.con_dbid) - DATE '2020-01-01' AS last_day_n
          FROM (
             SELECT gg.dbid, gg.con_dbid, gg.day_dt, SUM(gg.used_fill) AS used_total
             FROM (
               SELECT gr.dbid, gr.con_dbid, gr.day_dt,
                      LAST_VALUE(fb.used_bytes IGNORE NULLS) OVER
                        (PARTITION BY gr.dbid, gr.con_dbid, gr.tablespace_name
                         ORDER BY gr.day_dt
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS used_fill
               FROM (
                  SELECT dd.dbid, dd.con_dbid, dd.day_dt, tt.tablespace_name
                  FROM   (SELECT DISTINCT dbid, con_dbid, day_dt
                          FROM capd_tbspc_daily) dd
                  JOIN   (SELECT DISTINCT dbid, con_dbid, tablespace_name
                          FROM capd_tbspc_daily) tt
                    ON   tt.dbid = dd.dbid AND tt.con_dbid = dd.con_dbid
               ) gr
               LEFT JOIN capd_tbspc_daily fb
                 ON  fb.dbid = gr.dbid AND fb.con_dbid = gr.con_dbid
                 AND fb.tablespace_name = gr.tablespace_name
                 AND fb.day_dt = gr.day_dt
             ) gg
             GROUP  BY gg.dbid, gg.con_dbid, gg.day_dt
          ) g
       ) t
       WHERE t.day_dt > t.last_day - train_days
       GROUP BY t.dbid, t.con_dbid
    ) f
    JOIN (
       SELECT dbid, con_dbid,
              MAX(used_total)  KEEP (DENSE_RANK LAST ORDER BY day_dt) AS cur_used,
              MAX(limit_total) KEEP (DENSE_RANK LAST ORDER BY day_dt) AS cur_limit,
              MAX(all_nn)      KEEP (DENSE_RANK LAST ORDER BY day_dt) AS limit_all
       FROM (
          SELECT dbid, con_dbid, day_dt,
                 SUM(used_bytes)  AS used_total,
                 SUM(limit_bytes) AS limit_total,
                 CASE WHEN COUNT(*) = COUNT(limit_bytes) THEN 1 ELSE 0 END AS all_nn
          FROM   capd_tbspc_daily
          GROUP  BY dbid, con_dbid, day_dt
       )
       GROUP BY dbid, con_dbid
    ) c ON c.dbid = f.dbid AND c.con_dbid = f.con_dbid
    ORDER BY f.dbid, f.con_dbid;

  ----------------------------------------------------------------------
  -- p: emit one line. Lines are kept well under 32K; DBMS_OUTPUT itself
  -- caps a single PUT_LINE at 32767 bytes, which we never approach here.
  ----------------------------------------------------------------------
  PROCEDURE p(line IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(line);
  END p;

  ----------------------------------------------------------------------
  -- esc: manual HTML-escape (no HTF/OWA dependency -- the monitoring
  -- schema may lack execute on those packages).
  ----------------------------------------------------------------------
  FUNCTION esc(s IN VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(4000) := s;
  BEGIN
    IF v IS NULL THEN RETURN NULL; END IF;
    v := REPLACE(v, '&', '&amp;');
    v := REPLACE(v, '<', '&lt;');
    v := REPLACE(v, '>', '&gt;');
    RETURN v;
  END esc;

  ----------------------------------------------------------------------
  -- db_label: (dbid, con_dbid) -> the same DB/PDB display string the text
  -- report prints (CAPR_CONTAINER.db_pdb), falling back to the raw con_dbid
  -- when the container is unnamed. p_dbid may be NULL where a loop only has
  -- con_dbid (section 4's per-container chart grid); MAX() keeps the lookup
  -- deterministic if one con_dbid ever spans dbids.
  ----------------------------------------------------------------------
  FUNCTION db_label(p_dbid IN NUMBER, p_con_dbid IN NUMBER) RETURN VARCHAR2 IS
    v VARCHAR2(300);
  BEGIN
    SELECT MAX(db_pdb) INTO v
    FROM   capr_container
    WHERE  con_dbid = p_con_dbid
      AND  (p_dbid IS NULL OR dbid = p_dbid);
    RETURN NVL(v, TO_CHAR(p_con_dbid));
  END db_label;

  FUNCTION nz(n IN NUMBER, fmt IN VARCHAR2 DEFAULT 'FM999999990.00') RETURN VARCHAR2 IS
  BEGIN
    IF n IS NULL THEN RETURN '&ndash;'; END IF;
    RETURN TO_CHAR(n, fmt);
  END nz;

  FUNCTION pct_of(cur IN NUMBER, lim IN NUMBER) RETURN NUMBER IS
  BEGIN
    IF lim IS NULL OR lim <= 0 THEN RETURN NULL; END IF;
    RETURN LEAST(100, GREATEST(0, ROUND(cur / lim * 100, 1)));
  END pct_of;

  FUNCTION bar(pctval IN NUMBER, cls IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
  BEGIN
    IF pctval IS NULL THEN RETURN '&ndash;'; END IF;
    RETURN '<div class="bar-cell"><div class="bar-track"><div class="bar-fill '
           || cls || '" style="width:' || TO_CHAR(pctval, 'FM990.0') || '%"></div></div>'
           || '<span class="bar-pct">' || TO_CHAR(pctval, 'FM990') || '%</span></div>';
  END bar;

  ----------------------------------------------------------------------
  -- info_icon: a small circled-"i" tooltip. txt is one plain-English sentence
  -- shown three ways -- as the .tip bubble (CSS hover/focus), the aria-label
  -- (screen readers), and the native title (no-CSS fallback). txt is
  -- author-supplied constant copy: ASCII only, and NEVER contains a double
  -- quote (it sits inside two double-quoted HTML attributes).
  ----------------------------------------------------------------------
  FUNCTION info_icon(txt IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN '<span class="info" tabindex="0" role="note" aria-label="' || txt
           || '" title="' || txt || '">i<span class="tip">' || txt || '</span></span>';
  END info_icon;

  FUNCTION quality_pill(q IN VARCHAR2) RETURN VARCHAR2 IS
    cls VARCHAR2(20);
    ttl VARCHAR2(120);
  BEGIN
    IF q IS NULL THEN RETURN '&ndash;'; END IF;
    cls := CASE q WHEN 'OK'                    THEN 'pill-ok'
                  WHEN 'LOW_CONFIDENCE'        THEN 'pill-warn'
                  WHEN 'FLAT'                  THEN 'pill-flat'
                  WHEN 'INSUFFICIENT_HISTORY'  THEN 'pill-crit'
                  ELSE 'pill-flat' END;
    -- Plain-English gloss per quality value, shown as a native tooltip on hover.
    ttl := CASE q WHEN 'OK'                   THEN 'steady enough to forecast reliably'
                  WHEN 'LOW_CONFIDENCE'       THEN 'growth is too erratic for a dependable estimate'
                  WHEN 'FLAT'                 THEN 'not growing at all'
                  WHEN 'INSUFFICIENT_HISTORY' THEN 'not enough days of AWR history yet'
                  ELSE NULL END;
    RETURN '<span class="pill ' || cls || '"'
           || CASE WHEN ttl IS NOT NULL THEN ' title="' || ttl || '"' END
           || '>' || esc(q) || '</span>';
  END quality_pill;

  FUNCTION sev_pill(sev IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF sev = 'CRIT' THEN RETURN '<span class="sev-crit">CRIT</span>';
    ELSIF sev = 'WARN' THEN RETURN '<span class="sev-warn">WARN</span>';
    ELSE RETURN '<span class="sev-ok">ok</span>';
    END IF;
  END sev_pill;

  ----------------------------------------------------------------------
  -- Inline-SVG chart helpers. No JS, no external assets: every chart is a
  -- plain <svg viewBox="0 0 560 230"> built from the same p()/DBMS_OUTPUT
  -- mechanism as the rest of the document. All numbers going into SVG
  -- attributes go through fmt_px (explicit TO_CHAR mask, never the session
  -- default), and every mask has a forced '0' digit immediately left of the
  -- decimal point so a value like 0.5 never renders as the invalid ".50".
  ----------------------------------------------------------------------
  FUNCTION fmt_px(n IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    -- Five integer digits: the per-series charts never exceed the 560-wide
    -- box, but the full-width anomaly timeline (viewBox 1120) needs > 3
    -- digits. Byte-identical to the old FM990.00 for any value < 1000.
    RETURN TO_CHAR(n, 'FM99990.00');
  END fmt_px;

  ----------------------------------------------------------------------
  -- lin: generic linear map of a value in [vmin,vmax] to pixels in
  -- [p0,p1]. Degenerate guard: a zero-width domain maps to the midpoint
  -- (used by the full-width anomaly timeline, whose x-domain can collapse
  -- to a single day). Every result flows through fmt_px for SVG output.
  ----------------------------------------------------------------------
  FUNCTION lin(v IN NUMBER, vmin IN NUMBER, vmax IN NUMBER, p0 IN NUMBER, p1 IN NUMBER) RETURN NUMBER IS
  BEGIN
    IF vmax = vmin THEN RETURN (p0 + p1) / 2; END IF;
    RETURN p0 + (v - vmin) / (vmax - vmin) * (p1 - p0);
  END lin;

  ----------------------------------------------------------------------
  -- time_phrase: turn a day count into plain English for a non-statistician.
  -- < 60 days -> "about N days"; < 365 -> "about N months"; else
  -- "about X years" with a single decimal, dropping a redundant ".0"
  -- ("about 2 years" / "about 1.5 years"). NULL -> "unknown".
  ----------------------------------------------------------------------
  FUNCTION time_phrase(d IN NUMBER) RETURN VARCHAR2 IS
    yrs NUMBER;
  BEGIN
    IF d IS NULL THEN RETURN 'unknown'; END IF;
    IF d < 1 THEN
      RETURN 'within a day';
    ELSIF d < 60 THEN
      RETURN 'about ' || TO_CHAR(ROUND(d), 'FM999990') || ' days';
    ELSIF d < 365 THEN
      RETURN 'about ' || TO_CHAR(ROUND(d / 30), 'FM99990') || ' months';
    ELSE
      yrs := ROUND(d / 365, 1);
      IF yrs = TRUNC(yrs) THEN
        RETURN 'about ' || TO_CHAR(yrs, 'FM99990') || ' years';
      ELSE
        RETURN 'about ' || TO_CHAR(yrs, 'FM99990.0') || ' years';
      END IF;
    END IF;
  END time_phrase;

  ----------------------------------------------------------------------
  -- fmt_size_gb: format a GB quantity for humans, promoting to TB once it
  -- reaches 1024 GB. One decimal for GB, two for TB. NULL -> "unknown".
  -- Callers pass ABS() when they want a magnitude (e.g. a shrink rate).
  ----------------------------------------------------------------------
  FUNCTION fmt_size_gb(gb IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF gb IS NULL THEN RETURN 'unknown'; END IF;
    IF ABS(gb) >= 1024 THEN
      RETURN TO_CHAR(gb / 1024, 'FM999999990.00') || ' TB';
    END IF;
    RETURN TO_CHAR(gb, 'FM999999990.0') || ' GB';
  END fmt_size_gb;

  FUNCTION scale_x(day_n IN NUMBER, xmin IN NUMBER, xmax IN NUMBER) RETURN NUMBER IS
  BEGIN
    IF xmax = xmin THEN RETURN c_ml + (c_cw - c_ml - c_mr) / 2; END IF;
    RETURN c_ml + (day_n - xmin) / (xmax - xmin) * (c_cw - c_ml - c_mr);
  END scale_x;

  FUNCTION scale_y(val IN NUMBER, ymin IN NUMBER, ymax IN NUMBER) RETURN NUMBER IS
  BEGIN
    IF ymax = ymin THEN RETURN c_mt + (c_ch - c_mt - c_mb) / 2; END IF;
    RETURN c_mt + (c_ch - c_mt - c_mb) - (val - ymin) / (ymax - ymin) * (c_ch - c_mt - c_mb);
  END scale_y;

  ----------------------------------------------------------------------
  -- emit_polyline: draws a (possibly hundreds-of-points) series as one
  -- <polyline points="...">. The opening tag, each coordinate chunk, and
  -- the closing quote/tag are each their own DBMS_OUTPUT line (newlines
  -- inside a "points" attribute are legal SVG whitespace), so no single
  -- PUT_LINE call is ever anywhere near the 32767-byte cap even for a
  -- multi-hundred-day series. css_class selects solid vs. dashed styling
  -- entirely via the <style> block (e.g. hist-line vs proj-line) so no
  -- color/dash literal is hard-coded here.
  -- Degenerate guard: a single point renders as a dot (a 2-point line has
  -- no direction), not a <polyline>.
  ----------------------------------------------------------------------
  PROCEDURE emit_polyline(xs IN num_tab, ys IN num_tab, n IN PLS_INTEGER,
                          xmin IN NUMBER, xmax IN NUMBER, ymin IN NUMBER, ymax IN NUMBER,
                          css_class IN VARCHAR2) IS
    buf VARCHAR2(4000);
  BEGIN
    IF n <= 0 THEN
      RETURN;
    ELSIF n = 1 THEN
      p('<circle class="' || css_class || '-pt" cx="' || fmt_px(scale_x(xs(1), xmin, xmax))
        || '" cy="' || fmt_px(scale_y(ys(1), ymin, ymax)) || '" r="2.6"/>');
      RETURN;
    END IF;
    p('<polyline class="' || css_class || '" points="');
    buf := NULL;
    FOR i IN 1 .. n LOOP
      buf := buf || fmt_px(scale_x(xs(i), xmin, xmax)) || ',' || fmt_px(scale_y(ys(i), ymin, ymax)) || ' ';
      IF LENGTH(buf) > 2000 THEN
        p(buf);
        buf := NULL;
      END IF;
    END LOOP;
    IF buf IS NOT NULL THEN p(buf); END IF;
    p('"/>');
  END emit_polyline;

  ----------------------------------------------------------------------
  -- emit_poly_box / emit_yaxis_box: generalized siblings of emit_polyline /
  -- emit_y_axis that take an EXPLICIT pixel plot-box (pl,pr = left/right x;
  -- pt,pb = top/bottom y) instead of the hard-wired 560x230 geometry, so the
  -- full-width whole-database hero (viewBox 1120x250) can reuse the exact same
  -- chunking and CSS classes. lin() does the value->pixel mapping (y inverted:
  -- ymin->pb bottom, ymax->pt top). Same 32K-safe chunking as emit_polyline.
  ----------------------------------------------------------------------
  PROCEDURE emit_poly_box(xs IN num_tab, ys IN num_tab, n IN PLS_INTEGER,
                          xmin IN NUMBER, xmax IN NUMBER, ymin IN NUMBER, ymax IN NUMBER,
                          pl IN NUMBER, pr IN NUMBER, pt IN NUMBER, pb IN NUMBER,
                          css_class IN VARCHAR2) IS
    buf VARCHAR2(4000);
  BEGIN
    IF n <= 0 THEN
      RETURN;
    ELSIF n = 1 THEN
      p('<circle class="' || css_class || '-pt" cx="' || fmt_px(lin(xs(1), xmin, xmax, pl, pr))
        || '" cy="' || fmt_px(lin(ys(1), ymin, ymax, pb, pt)) || '" r="2.6"/>');
      RETURN;
    END IF;
    p('<polyline class="' || css_class || '" points="');
    buf := NULL;
    FOR i IN 1 .. n LOOP
      buf := buf || fmt_px(lin(xs(i), xmin, xmax, pl, pr)) || ',' || fmt_px(lin(ys(i), ymin, ymax, pb, pt)) || ' ';
      IF LENGTH(buf) > 2000 THEN
        p(buf);
        buf := NULL;
      END IF;
    END LOOP;
    IF buf IS NOT NULL THEN p(buf); END IF;
    p('"/>');
  END emit_poly_box;

  ----------------------------------------------------------------------
  -- emit_yaxis_box: n_lines evenly spaced gridlines + value labels across an
  -- explicit plot box. Same step-based label precision as emit_y_axis (so a
  -- small-range total does not label every gridline the same rounded value).
  ----------------------------------------------------------------------
  PROCEDURE emit_yaxis_box(ymin IN NUMBER, ymax IN NUMBER, unit IN VARCHAR2,
                           pl IN NUMBER, pr IN NUMBER, pt IN NUMBER, pb IN NUMBER,
                           n_lines IN PLS_INTEGER DEFAULT 5) IS
    step NUMBER;
    val  NUMBER;
    ypx  NUMBER;
    fmt  VARCHAR2(20);
  BEGIN
    IF ymax = ymin OR n_lines < 2 THEN RETURN; END IF;
    step := (ymax - ymin) / (n_lines - 1);
    fmt := CASE WHEN step < 1  THEN 'FM999999990.00'
                WHEN step < 10 THEN 'FM999999990.0'
                ELSE 'FM999999990' END;
    FOR i IN 0 .. (n_lines - 1) LOOP
      val := ymin + i * step;
      ypx := lin(val, ymin, ymax, pb, pt);
      p('<line class="grid-line" x1="' || fmt_px(pl) || '" y1="' || fmt_px(ypx)
        || '" x2="' || fmt_px(pr) || '" y2="' || fmt_px(ypx) || '"/>');
      p('<text class="axis-label" x="2" y="' || fmt_px(ypx + 3) || '">'
        || TO_CHAR(val, fmt) || unit || '</text>');
    END LOOP;
  END emit_yaxis_box;

  ----------------------------------------------------------------------
  -- emit_y_axis: n_lines evenly spaced horizontal gridlines with rounded
  -- value labels (e.g. GB or %). unit is appended to the label as literal
  -- text (a leading space is the caller's responsibility).
  ----------------------------------------------------------------------
  PROCEDURE emit_y_axis(ymin IN NUMBER, ymax IN NUMBER, unit IN VARCHAR2, n_lines IN PLS_INTEGER DEFAULT 5) IS
    step NUMBER;
    val  NUMBER;
    ypx  NUMBER;
    fmt  VARCHAR2(20);
  BEGIN
    IF ymax = ymin OR n_lines < 2 THEN RETURN; END IF;
    step := (ymax - ymin) / (n_lines - 1);
    -- Label precision follows the gridline step, else small-range charts
    -- (e.g. a 0-1.5 GB tablespace) would label every line "0" or "1".
    fmt := CASE WHEN step < 1  THEN 'FM999999990.00'
                WHEN step < 10 THEN 'FM999999990.0'
                ELSE 'FM999999990' END;
    FOR i IN 0 .. (n_lines - 1) LOOP
      val := ymin + i * step;
      ypx := scale_y(val, ymin, ymax);
      p('<line class="grid-line" x1="' || fmt_px(c_ml) || '" y1="' || fmt_px(ypx)
        || '" x2="' || fmt_px(c_cw - c_mr) || '" y2="' || fmt_px(ypx) || '"/>');
      p('<text class="axis-label" x="2" y="' || fmt_px(ypx + 3) || '">'
        || TO_CHAR(val, fmt) || unit || '</text>');
    END LOOP;
  END emit_y_axis;

  ----------------------------------------------------------------------
  -- emit_x_axis: first/middle/last date labels (YYYY-MM-DD) across the
  -- chart's day_n extent, which may run past the last history day when a
  -- projection or ESM point extends it.
  ----------------------------------------------------------------------
  PROCEDURE emit_x_axis(xmin IN NUMBER, xmax IN NUMBER) IS
    xmid NUMBER := ROUND((xmin + xmax) / 2);
  BEGIN
    p('<text class="axis-label" x="' || fmt_px(scale_x(xmin, xmin, xmax)) || '" y="' || fmt_px(c_ch - 6)
      || '" text-anchor="start">' || TO_CHAR(c_epoch + xmin, 'YYYY-MM-DD') || '</text>');
    IF xmax > xmin THEN
      p('<text class="axis-label" x="' || fmt_px(scale_x(xmid, xmin, xmax)) || '" y="' || fmt_px(c_ch - 6)
        || '" text-anchor="middle">' || TO_CHAR(c_epoch + xmid, 'YYYY-MM-DD') || '</text>');
      p('<text class="axis-label" x="' || fmt_px(scale_x(xmax, xmin, xmax)) || '" y="' || fmt_px(c_ch - 6)
        || '" text-anchor="end">' || TO_CHAR(c_epoch + xmax, 'YYYY-MM-DD') || '</text>');
    END IF;
  END emit_x_axis;

  PROCEDURE chart_axes_frame IS
  BEGIN
    p('<line class="axis-line" x1="' || fmt_px(c_ml) || '" y1="' || fmt_px(c_ch - c_mb)
      || '" x2="' || fmt_px(c_cw - c_mr) || '" y2="' || fmt_px(c_ch - c_mb) || '"/>');
    p('<line class="axis-line" x1="' || fmt_px(c_ml) || '" y1="' || fmt_px(c_mt)
      || '" x2="' || fmt_px(c_ml) || '" y2="' || fmt_px(c_ch - c_mb) || '"/>');
  END chart_axes_frame;

  PROCEDURE chart_open(title IN VARCHAR2, subtitle IN VARCHAR2) IS
  BEGIN
    p('<div class="chart-card">');
    p('<h4>' || title || '</h4>');
    IF subtitle IS NOT NULL THEN
      p('<div class="chart-sub">' || esc(subtitle) || '</div>');
    END IF;
  END chart_open;

  ----------------------------------------------------------------------
  -- chart_legend: static swatches (rendered once, above the first chart
  -- grid) explaining the line styles / markers used by every chart below.
  -- Each swatch is a tiny inline SVG reusing the exact same CSS classes as
  -- the real charts, so the legend can never visually drift from them.
  ----------------------------------------------------------------------
  PROCEDURE chart_legend IS
  BEGIN
    p('<div class="chart-legend">');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="hist-line" x1="1" y1="5" x2="19" y2="5"/></svg> History</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="proj-line" x1="1" y1="5" x2="19" y2="5"/></svg> Projection (REGR)</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="esm-line" x1="10" y1="1" x2="10" y2="9"/><circle class="esm-dot" cx="10" cy="5" r="2"/></svg> ESM +30 (95% CI)</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="limit-line" x1="1" y1="5" x2="19" y2="5"/></svg> Limit</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="thresh-line" x1="1" y1="5" x2="19" y2="5"/></svg> Threshold</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><circle class="anom-dot" cx="10" cy="5" r="3"/></svg> Anomaly</span>');
    p('</div>');
  END chart_legend;

BEGIN
  do_esm := NOT (show_esm = 'N' OR (show_esm = 'AUTO' AND esm_ok = 0));

  ----------------------------------------------------------------------
  -- Document head + styles
  ----------------------------------------------------------------------
  p('<!doctype html>');
  p('<html lang="en"><head>');
  p('<meta charset="UTF-8">');
  p('<title>AWR Capacity Report - ' || esc(cap_db) || '</title>');
  p('<style>');
  p(':root{');
  p('  --bg:#f5f6f8; --panel:#ffffff; --text:#1b2430; --muted:#5b6675; --border:#dde2e8;');
  p('  --crit:#c0392b; --crit-bg:#fdecea; --warn:#b7791f; --warn-bg:#fef6e7;');
  p('  --ok:#1e7e46; --ok-bg:#eaf6ee; --flat-bg:#eef0f3; --flat-fg:#5b6675;');
  p('  --accent:#2b5fad; --bar-track:#e7eaef; --bar-fill:#2b5fad; --bar-crit:#c0392b; --bar-warn:#b7791f;');
  p('}');
  p('@media (prefers-color-scheme: dark){ :root{');
  p('  --bg:#12151a; --panel:#1a1e25; --text:#e6e9ee; --muted:#96a0ad; --border:#2b313b;');
  p('  --crit:#ff6b5e; --crit-bg:#3a201d; --warn:#e0b04c; --warn-bg:#3a2f18;');
  p('  --ok:#5fd489; --ok-bg:#173424; --flat-bg:#242830; --flat-fg:#96a0ad;');
  p('  --accent:#7aa2e8; --bar-track:#2a2f37; --bar-fill:#7aa2e8; --bar-crit:#ff6b5e; --bar-warn:#e0b04c;');
  p('}}');
  p(':root[data-theme="dark"]{');
  p('  --bg:#12151a; --panel:#1a1e25; --text:#e6e9ee; --muted:#96a0ad; --border:#2b313b;');
  p('  --crit:#ff6b5e; --crit-bg:#3a201d; --warn:#e0b04c; --warn-bg:#3a2f18;');
  p('  --ok:#5fd489; --ok-bg:#173424; --flat-bg:#242830; --flat-fg:#96a0ad;');
  p('  --accent:#7aa2e8; --bar-track:#2a2f37; --bar-fill:#7aa2e8; --bar-crit:#ff6b5e; --bar-warn:#e0b04c;');
  p('}');
  p(':root[data-theme="light"]{');
  p('  --bg:#f5f6f8; --panel:#ffffff; --text:#1b2430; --muted:#5b6675; --border:#dde2e8;');
  p('  --crit:#c0392b; --crit-bg:#fdecea; --warn:#b7791f; --warn-bg:#fef6e7;');
  p('  --ok:#1e7e46; --ok-bg:#eaf6ee; --flat-bg:#eef0f3; --flat-fg:#5b6675;');
  p('  --accent:#2b5fad; --bar-track:#e7eaef; --bar-fill:#2b5fad; --bar-crit:#c0392b; --bar-warn:#b7791f;');
  p('}');
  p('*{box-sizing:border-box} html,body{margin:0;padding:0}');
  p('body{background:var(--bg); color:var(--text); font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; font-size:14px; line-height:1.5;}');
  p('.wrap{max-width:1180px;margin:0 auto;padding:0 20px 60px}');
  p('nav.topnav{position:sticky; top:0; z-index:10; background:var(--panel); border-bottom:1px solid var(--border); padding:10px 20px; display:flex; gap:4px; flex-wrap:wrap; align-items:center;}');
  p('nav.topnav a{color:var(--muted); text-decoration:none; font-size:12.5px; padding:6px 10px; border-radius:6px;}');
  p('nav.topnav a:hover{background:var(--flat-bg); color:var(--text)}');
  p('nav.topnav .brand{font-weight:700;color:var(--text);margin-right:12px;font-size:13px}');
  p('.card{background:var(--panel); border:1px solid var(--border); border-radius:10px; padding:18px 20px; margin:20px 0;}');
  p('.header-card h1{margin:0 0 4px;font-size:19px}');
  p('.header-card .sub{color:var(--muted);font-size:12.5px;margin-bottom:14px}');
  p('.kv-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px 24px}');
  p('.kv-grid .kv dt{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.04em}');
  p('.kv-grid .kv dd{margin:2px 0 0;font-size:13.5px;font-variant-numeric:tabular-nums}');
  p('.note{margin-top:14px;padding:10px 12px;border-radius:8px;background:var(--flat-bg);color:var(--muted); font-size:12.5px;border-left:3px solid var(--warn);}');
  p('section{scroll-margin-top:56px;margin:26px 0}');
  p('section h2{font-size:15.5px;margin:0 0 4px;display:flex;align-items:center;gap:8px}');
  p('section .desc{color:var(--muted);font-size:12.5px;margin:0 0 12px}');
  p('table{width:100%;border-collapse:collapse;font-size:13px;background:var(--panel)}');
  -- overflow:visible (not hidden) so an inline info-tooltip bubble can escape
  -- the table/cell box instead of being clipped; the rounded outer corners are
  -- restored on the corner cells below.
  p('table.tbl{border:1px solid var(--border);border-radius:8px;overflow:visible}');
  p('thead th{text-align:left;background:var(--flat-bg);color:var(--muted);font-weight:600; font-size:11px;text-transform:uppercase;letter-spacing:.03em;padding:8px 10px;border-bottom:1px solid var(--border);overflow:visible}');
  p('table.tbl thead tr:first-child th:first-child{border-top-left-radius:8px}');
  p('table.tbl thead tr:first-child th:last-child{border-top-right-radius:8px}');
  p('table.tbl tbody tr:last-child td:first-child{border-bottom-left-radius:8px}');
  p('table.tbl tbody tr:last-child td:last-child{border-bottom-right-radius:8px}');
  p('tbody td{padding:7px 10px;border-bottom:1px solid var(--border);overflow:visible}');
  p('tbody tr:last-child td{border-bottom:none}');
  p('tbody tr:hover td{background:var(--flat-bg)}');
  p('td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}');
  p('.pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:600}');
  p('.pill-ok{background:var(--ok-bg);color:var(--ok)}');
  p('.pill-warn{background:var(--warn-bg);color:var(--warn)}');
  p('.pill-crit{background:var(--crit-bg);color:var(--crit)}');
  p('.pill-flat{background:var(--flat-bg);color:var(--flat-fg)}');
  p('.sev-crit{color:var(--crit);font-weight:700}');
  p('.sev-warn{color:var(--warn);font-weight:700}');
  p('.sev-ok{color:var(--ok);font-weight:600}');
  p('.bar-cell{display:flex;align-items:center;gap:8px;min-width:140px}');
  p('.bar-track{flex:1;height:8px;border-radius:4px;background:var(--bar-track);overflow:hidden}');
  p('.bar-fill{height:100%;border-radius:4px;background:var(--bar-fill)}');
  p('.bar-fill.warn{background:var(--bar-warn)}');
  p('.bar-fill.crit{background:var(--bar-crit)}');
  p('.bar-pct{font-size:11px;color:var(--muted);width:38px;text-align:right;font-variant-numeric:tabular-nums}');
  p('.z-hi{color:var(--crit);font-weight:700}');
  p('.empty-note{color:var(--muted);font-style:italic;padding:12px;background:var(--flat-bg);border-radius:8px;font-size:12.5px}');
  p('footer{margin-top:40px;padding:16px 0;border-top:1px solid var(--border);color:var(--muted);font-size:12px;text-align:center}');
  p('@media print{ nav.topnav{position:static} .card,table.tbl{break-inside:avoid} body{background:#fff;color:#000} .info .tip{display:none} }');
  ------------------------------------------------------------------------
  -- Inline info tooltips (pure CSS, no JS): a circled lowercase "i" the reader
  -- hovers or keyboard-focuses (tabindex=0) for a one-sentence plain-English
  -- gloss. The bubble opens DOWNWARD (over the table body) so a header tooltip
  -- is never clipped at the top edge; tables use overflow:visible so it can
  -- escape sideways too. A native title attribute is the no-CSS fallback.
  ------------------------------------------------------------------------
  p('.info{position:relative;display:inline-flex;align-items:center;justify-content:center;width:13px;height:13px;margin-left:4px;border:1px solid var(--muted);border-radius:50%;color:var(--muted);font:italic 700 9px/1 Georgia,"Times New Roman",serif;text-transform:none;letter-spacing:0;cursor:help;vertical-align:middle;user-select:none}');
  p('.info:focus-visible{outline:2px solid var(--accent);outline-offset:1px}');
  p('.info .tip{position:absolute;left:50%;top:calc(100% + 7px);transform:translateX(-50%);width:max-content;max-width:260px;background:var(--panel);color:var(--text);border:1px solid var(--border);border-radius:8px;box-shadow:0 6px 18px rgba(0,0,0,.20);padding:7px 10px;font:400 12px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;text-transform:none;letter-spacing:normal;text-align:left;white-space:normal;opacity:0;visibility:hidden;pointer-events:none;z-index:60}');
  p('.info:hover .tip,.info:focus .tip,.info:focus-visible .tip{opacity:1;visibility:visible}');
  -- Collapsible plain-English glossary at the end of section 0 (details/summary,
  -- no JS; prints collapsed by default). ASCII-only +/- markers.
  p('.glossary{margin:18px 0 6px;border:1px solid var(--border);border-radius:10px;background:var(--panel);font-size:12.5px}');
  p('.glossary>summary{cursor:pointer;padding:12px 16px;font-weight:600;color:var(--text);list-style:none}');
  p('.glossary>summary::-webkit-details-marker{display:none}');
  p('.glossary>summary::before{content:"+ ";color:var(--muted);font-weight:700}');
  p('.glossary[open]>summary::before{content:"- "}');
  p('.glossary .gl-body{padding:0 16px 14px}');
  p('.glossary dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:0}');
  p('.glossary dt{font-weight:700;color:var(--text);white-space:nowrap}');
  p('.glossary dd{margin:0;color:var(--muted)}');
  p('@media(max-width:640px){.glossary dl{grid-template-columns:1fr;gap:2px 0} .glossary dt{margin-top:6px}}');
  ------------------------------------------------------------------------
  -- Chart CSS. All stroke/fill colors reference the same page-level CSS
  -- variables used elsewhere (--accent/--ok/--crit/--warn/--muted/--border),
  -- so inline SVG inherits light/dark theming with no extra variables.
  ------------------------------------------------------------------------
  p('.chart-legend{display:flex;flex-wrap:wrap;gap:16px;font-size:11.5px;color:var(--muted);margin:10px 0 6px;align-items:center}');
  p('.chart-legend .lg-item{display:inline-flex;align-items:center;gap:5px}');
  p('.chart-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:16px;margin:6px 0 20px}');
  p('.chart-card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px 14px 8px}');
  p('.chart-card h4{margin:0 0 2px;font-size:13px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}');
  p('.chart-sub{color:var(--muted);font-size:11px;margin:0 0 6px}');
  p('.chart-svg{width:100%;height:auto;display:block}');
  p('.axis-line{stroke:var(--border);stroke-width:1}');
  p('.grid-line{stroke:var(--border);stroke-width:1;stroke-dasharray:2 3;opacity:.6}');
  p('.axis-label{fill:var(--muted);font-size:9px}');
  p('.thresh-label{fill:var(--warn);font-size:9px}');
  p('.hist-line{fill:none;stroke:var(--accent);stroke-width:1.8;stroke-linejoin:round}');
  p('.hist-line-pt{fill:var(--accent)}');
  p('.proj-line{fill:none;stroke:var(--accent);stroke-width:1.6;stroke-dasharray:5 4;opacity:.85}');
  p('.proj-line-pt{fill:var(--accent)}');
  p('.esm-line{stroke:var(--ok);stroke-width:1.4}');
  p('.esm-dot{fill:var(--ok)}');
  p('.limit-line{stroke:var(--crit);stroke-width:1.2;stroke-dasharray:3 3}');
  p('.thresh-line{stroke:var(--warn);stroke-width:1.2;stroke-dasharray:3 3}');
  p('.anom-dot{fill:var(--crit);stroke:var(--panel);stroke-width:0.6}');
  ------------------------------------------------------------------------
  -- "At a glance" (section 0): plain-English best-guess cards + a
  -- full-width anomaly timeline. Accent colors reuse the same page-level
  -- --crit/--warn/--ok variables so light/dark theming is automatic; the
  -- confidence pills reuse the existing .pill / .pill-ok / .pill-flat.
  ------------------------------------------------------------------------
  p('.glance-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px;margin:10px 0 8px}');
  p('.gcard{background:var(--panel);border:1px solid var(--border);border-left-width:4px;border-radius:10px;padding:14px 16px;display:flex;flex-direction:column;gap:5px}');
  p('.gcard.g-crit{border-left-color:var(--crit)}');
  p('.gcard.g-warn{border-left-color:var(--warn)}');
  p('.gcard.g-ok{border-left-color:var(--ok)}');
  p('.gcard .g-head{margin:0;font-size:14px;font-weight:700;line-height:1.35;display:flex;flex-wrap:wrap;align-items:baseline;gap:8px}');
  p('.gcard .g-line{color:var(--muted);font-size:12.5px}');
  p('.gcard .g-date{color:var(--text);font-size:12.5px;font-variant-numeric:tabular-nums}');
  p('.glance-rollup{color:var(--muted);font-size:12.5px;margin:2px 0 16px;line-height:1.6}');
  p('.glance-ok{background:var(--ok-bg);color:var(--ok);border:1px solid var(--ok);border-radius:10px;padding:14px 16px;font-size:13.5px;font-weight:600;margin:10px 0 6px}');
  -- Attention banner: warn/crit tints mirror .glance-ok with --warn/--crit.
  p('.glance-warn{background:var(--warn-bg);color:var(--warn);border:1px solid var(--warn);border-radius:10px;padding:14px 16px;font-size:13.5px;margin:10px 0 6px}');
  p('.glance-crit{background:var(--crit-bg);color:var(--crit);border:1px solid var(--crit);border-radius:10px;padding:14px 16px;font-size:13.5px;margin:10px 0 6px}');
  p('.attn-lead{font-weight:700}');
  p('.attn-list{margin:8px 0 0;padding-left:22px;font-weight:400;line-height:1.55}');
  p('.attn-list li{margin:2px 0}');
  p('.attn-note{margin-top:8px;font-weight:400;font-size:12.5px;opacity:.85}');
  p('.timeline-card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px 16px 10px;margin:6px 0 8px}');
  p('.timeline-svg{width:100%;height:auto;display:block}');
  p('.tl-baseline{stroke:var(--border);stroke-width:1}');
  p('.tl-grid{stroke:var(--border);stroke-width:1;stroke-dasharray:2 3;opacity:.5}');
  p('.tl-lane-label{fill:var(--muted);font-size:11px}');
  p('.tl-axis-label{fill:var(--muted);font-size:9px}');
  -- Hero duo: the whole-database hero and the host-CPU hero side by side on
  -- desktop, stacking when narrow. Each is a .gcard g-hero (reuses .gcard +
  -- .g-* accents and pills) holding a headline and a 560x250 chart.
  p('.hero-duo{display:grid;grid-template-columns:repeat(auto-fit,minmax(430px,1fr));gap:14px;margin:10px 0 8px}');
  p('.g-hero{gap:6px}');
  p('.g-hero .g-head{font-size:16px}');
  p('.g-hero .hero-svg{width:100%;height:auto;display:block;margin-top:8px}');
  p('</style>');
  p('</head><body>');

  ----------------------------------------------------------------------
  -- Top nav
  ----------------------------------------------------------------------
  p('<nav class="topnav">');
  p('<span class="brand">AWR Capacity Report</span>');
  p('<a href="#s0">At a glance</a>');
  p('<a href="#s1">1. Days-to-full</a>');
  p('<a href="#s2">2. Forecast</a>');
  p('<a href="#s3">3. Tbspc anomalies</a>');
  p('<a href="#s4">4. CPU trend</a>');
  p('<a href="#s5">5. CPU anomalies</a>');
  p('<a href="#s6">6. ESM vs REGR</a>');
  p('</nav>');
  p('<div class="wrap">');

  ----------------------------------------------------------------------
  -- Header card
  ----------------------------------------------------------------------
  p('<div class="card header-card">');
  p('<h1>AWR Capacity Predictions</h1>');
  p('<div class="sub">capacity + anomaly report -- read-only</div>');
  p('<dl class="kv-grid">');
  p('<div class="kv"><dt>Database</dt><dd>' || esc(cap_db) || '</dd></div>');
  p('<div class="kv"><dt>Host</dt><dd>' || esc(cap_host) || '</dd></div>');
  p('<div class="kv"><dt>Schema</dt><dd>' || esc(cap_user) || '</dd></div>');
  p('<div class="kv"><dt>Generated</dt><dd>' || esc(cap_gen) || '</dd></div>');
  p('<div class="kv"><dt>Thresholds</dt><dd>days-to-full WARN&lt;=' || dtf_warn
      || ' CRIT&lt;=' || dtf_crit || '; CPU saturation ' || cpu_sat || '%</dd></div>');
  p('<div class="kv"><dt>Tier 2 models</dt><dd>' || esm_ok || ' OML ESM model(s) trained (OK)</dd></div>');
  p('</dl>');
  p('<div class="note">NOTE: forecasts degrade loudly on short AWR retention -- watch TRAIN_N and '
      || 'QUALITY. INSUFFICIENT_HISTORY means fewer than the configured minimum training days; raise '
      || 'DBMS_WORKLOAD_REPOSITORY retention for real trends.</div>');
  p('</div>');

  ----------------------------------------------------------------------
  -- Section 0: "At a glance" -- plain-English best-guess prediction cards
  -- and an anomaly timeline, for readers who do not want the statistics.
  -- Everything below is SELECT-only over the same CAPF_/CAPA_/CAPD_ views
  -- the detailed sections use; nothing new is computed.
  ----------------------------------------------------------------------
  p('<section id="s0">');
  p('<h2>At a glance</h2>');
  p('<p class="desc">The short version, in plain language: what is most likely to need '
      || 'attention, and anything unusual lately. The detailed tables and charts follow below.</p>');

  ----------------------------------------------------------------------
  -- Attention banner: is anything about to need attention? Gather items
  -- (SELECT-only, reusing the same views/knobs as the detail sections, and
  -- cur_hero for the whole-DB days-to-limit so the banner can never disagree
  -- with the heroes), then render ONE status banner at the very top.
  ----------------------------------------------------------------------
  SELECT COUNT(DISTINCT con_dbid) INTO v_con_count FROM capd_tbspc_daily;

  v_nitems := 0; v_max_sev := 0;

  -- (a) tablespaces forecast to fill within the warning window.
  FOR ta IN (
    SELECT tablespace_name, days_to_full,
           CASE WHEN days_to_full <= dtf_crit THEN 2 ELSE 1 END AS sev
    FROM   capf_tbspc_forecast
    WHERE  quality = 'OK' AND days_to_full IS NOT NULL AND days_to_full <= dtf_warn
    ORDER  BY days_to_full
  ) LOOP
    v_nitems := v_nitems + 1;
    v_items(v_nitems) := '<li>' || esc(ta.tablespace_name)
                         || ' could be full in ' || time_phrase(ta.days_to_full) || '</li>';
    v_max_sev := GREATEST(v_max_sev, ta.sev);
  END LOOP;

  -- (a2) tablespaces nearly full RIGHT NOW regardless of fit quality (M7.1),
  -- from CAPR_ALERTS so this banner and the text report's section 0 agree.
  FOR nf IN (
    SELECT series_key, db_pdb, value AS pct_used,
           CASE WHEN severity = 'CRIT' THEN 2 ELSE 1 END AS sev
    FROM   capr_alerts
    WHERE  kind = 'TBSPC_NEARFULL'
    ORDER  BY value DESC
  ) LOOP
    v_nitems := v_nitems + 1;
    v_items(v_nitems) := '<li>' || esc(nf.series_key)
                         || CASE WHEN v_con_count > 1 THEN ' (' || esc(nf.db_pdb) || ')' END
                         || ' is ' || TO_CHAR(nf.pct_used, 'FM990.0')
                         || '% full right now</li>';
    v_max_sev := GREATEST(v_max_sev, nf.sev);
  END LOOP;

  -- (b) whole database projected to reach its total allocated limit within the
  -- warning window (same regression + gates as the hero, via cur_hero).
  FOR hf IN cur_hero LOOP
    IF hf.n < min_train_days THEN            v_hquality := 'INSUFFICIENT_HISTORY';
    ELSIF hf.slope = 0 OR hf.r2 IS NULL THEN v_hquality := 'FLAT';
    ELSIF hf.r2 < r2_gate THEN               v_hquality := 'LOW_CONFIDENCE';
    ELSE                                     v_hquality := 'OK'; END IF;
    v_hlimit_gb := CASE WHEN hf.limit_all = 1 THEN hf.cur_limit / 1073741824 END;
    v_days_to_lim := NULL;
    IF v_hquality = 'OK' AND hf.slope > 0 AND v_hlimit_gb IS NOT NULL
       AND hf.cur_limit > hf.cur_used THEN
      v_days_to_lim := FLOOR((hf.cur_limit - hf.cur_used) / hf.slope);
    END IF;
    IF v_days_to_lim IS NOT NULL AND v_days_to_lim <= dtf_warn THEN
      v_hlabel := 'The whole database'
                  || CASE WHEN v_con_count > 1 THEN ' (' || db_label(hf.dbid, hf.con_dbid) || ')' END;
      v_nitems := v_nitems + 1;
      v_items(v_nitems) := '<li>' || esc(v_hlabel)
                           || ' could reach its total allocated limit in '
                           || time_phrase(v_days_to_lim) || '</li>';
      v_max_sev := GREATEST(v_max_sev, CASE WHEN v_days_to_lim <= dtf_crit THEN 2 ELSE 1 END);
    END IF;
  END LOOP;

  -- (c) host CPU projected to reach saturation within the warning window.
  FOR cc IN (
    SELECT dbid, con_dbid, days_to_sat,
           CASE WHEN days_to_sat <= dtf_crit THEN 2 ELSE 1 END AS sev
    FROM   capf_cpu_trend
    WHERE  metric = 'BUSY_PCT' AND quality = 'OK'
      AND  days_to_sat IS NOT NULL AND days_to_sat <= dtf_warn
    ORDER  BY con_dbid
  ) LOOP
    v_nitems := v_nitems + 1;
    v_items(v_nitems) := '<li>Host CPU'
                         || CASE WHEN v_con_count > 1 THEN ' (' || esc(db_label(cc.dbid, cc.con_dbid)) || ')' END
                         || ' could reach ' || TO_CHAR(cpu_sat, 'FM990') || '% busy in '
                         || time_phrase(cc.days_to_sat) || '</li>';
    v_max_sev := GREATEST(v_max_sev, cc.sev);
  END LOOP;

  -- (d) neutral info: flagged unusual days in the window (never raises severity).
  SELECT (SELECT COUNT(*) FROM capa_tbspc_anom
          WHERE anomaly_flag IS NOT NULL
            AND day_dt > (SELECT MAX(day_dt) FROM capd_tbspc_daily) - anomaly_days)
       + (SELECT COUNT(*) FROM capa_cpu_anom
          WHERE anomaly_flag IS NOT NULL
            AND day_dt > (SELECT MAX(day_dt) FROM capd_cpu_daily) - anomaly_days)
    INTO v_anom_count FROM dual;

  IF v_nitems = 0 THEN
    v_msg := 'All clear -- nothing needs attention: nothing is near-full now, no tablespace or '
             || 'whole-database limit within '
             || TO_CHAR(dtf_warn, 'FM999990') || ' days, and CPU saturation is not in sight.';
    IF v_anom_count > 0 THEN
      v_msg := v_msg || ' ' || TO_CHAR(v_anom_count, 'FM999990') || ' unusual day'
               || CASE WHEN v_anom_count = 1 THEN '' ELSE 's' END
               || ' in the last ' || TO_CHAR(anomaly_days, 'FM999990') || ' days -- see the timeline below.';
    END IF;
    p('<div class="glance-ok">' || v_msg || '</div>');
  ELSE
    v_banner_cls := CASE WHEN v_max_sev >= 2 THEN 'glance-crit' ELSE 'glance-warn' END;
    p('<div class="' || v_banner_cls || '"><span class="attn-lead">Needs attention:</span>');
    p('<ul class="attn-list">');
    FOR i IN 1 .. v_nitems LOOP
      p(v_items(i));
    END LOOP;
    p('</ul>');
    IF v_anom_count > 0 THEN
      p('<div class="attn-note">' || TO_CHAR(v_anom_count, 'FM999990') || ' unusual day'
        || CASE WHEN v_anom_count = 1 THEN '' ELSE 's' END
        || ' in the last ' || TO_CHAR(anomaly_days, 'FM999990') || ' days -- see the timeline below.</div>');
    END IF;
    p('</div>');
  END IF;

  ----------------------------------------------------------------------
  -- Hero duo: whole-database total-size hero, then host-CPU hero, side by side.
  -- Both use cur_hero / capf_cpu_trend, the same views/knobs as the detail
  -- sections, so a hero can never contradict the tables below.
  ----------------------------------------------------------------------
  p('<div class="hero-duo">');

  -- Whole-database hero: cumulative total size, one per (dbid, con_dbid), from
  -- cur_hero (gap-filled regression mirroring CAPF_TBSPC_FORECAST exactly:
  -- same day_n epoch, train_days window, REGR_* aggregates and quality ladder).
  FOR hf IN cur_hero LOOP
    v_hlabel := 'Whole database'
                || CASE WHEN v_con_count > 1 THEN ' (' || db_label(hf.dbid, hf.con_dbid) || ')' END;

    -- Quality ladder, identical priority + gates to CAPF_TBSPC_FORECAST.
    IF hf.n < min_train_days THEN
      v_hquality := 'INSUFFICIENT_HISTORY';
    ELSIF hf.slope = 0 OR hf.r2 IS NULL THEN
      v_hquality := 'FLAT';
    ELSIF hf.r2 < r2_gate THEN
      v_hquality := 'LOW_CONFIDENCE';
    ELSE
      v_hquality := 'OK';
    END IF;

    v_hero_gb    := hf.cur_used / 1073741824;
    v_proj_gb    := hf.proj_180 / 1073741824;
    v_rate_gb_mo := hf.slope * 30 / 1073741824;
    v_hlimit_gb  := CASE WHEN hf.limit_all = 1 THEN hf.cur_limit / 1073741824 END;

    -- Days until the (meaningful) total allocated limit is reached: OK &
    -- growing & not already over, using the same slope-based arithmetic as
    -- days_to_full.
    v_days_to_lim := NULL;
    IF v_hquality = 'OK' AND hf.slope > 0 AND v_hlimit_gb IS NOT NULL
       AND hf.cur_limit > hf.cur_used THEN
      v_days_to_lim := FLOOR((hf.cur_limit - hf.cur_used) / hf.slope);
    END IF;

    -- Accent: reuse dtf day thresholds when a limit-reached date exists.
    IF v_days_to_lim IS NOT NULL THEN
      v_accent := CASE WHEN v_days_to_lim <= dtf_crit THEN 'g-crit'
                       WHEN v_days_to_lim <= dtf_warn THEN 'g-warn'
                       ELSE 'g-ok' END;
    ELSE
      v_accent := 'g-ok';
    END IF;

    -- Confidence pill (OK only, same r2 rule as the prediction cards).
    v_hpill := CASE WHEN v_hquality = 'OK'
                    THEN ' <span class="pill '
                         || CASE WHEN hf.r2 >= 0.9 THEN 'pill-ok">high confidence'
                                 ELSE 'pill-flat">good confidence' END
                         || '</span>'
               END;

    -- Headline copy per quality / slope sign.
    IF v_hquality = 'OK' AND hf.slope > 0 THEN
      v_head := esc(v_hlabel) || ' &mdash; growing about ' || fmt_size_gb(v_rate_gb_mo) || ' per month';
    ELSIF v_hquality = 'OK' AND hf.slope < 0 THEN
      v_head := esc(v_hlabel) || ' &mdash; shrinking about ' || fmt_size_gb(ABS(v_rate_gb_mo)) || ' per month';
    ELSIF v_hquality = 'FLAT' THEN
      v_head := esc(v_hlabel) || ' &mdash; not growing';
    ELSIF v_hquality = 'INSUFFICIENT_HISTORY' THEN
      v_head := esc(v_hlabel) || ' &mdash; not enough history yet for a whole-database estimate';
    ELSE
      v_head := esc(v_hlabel) || ' &mdash; size is changing too unevenly for a reliable estimate';
    END IF;

    p('<div class="gcard g-hero ' || v_accent || '">');
    p('<h4 class="g-head">' || v_head || v_hpill
      || CASE WHEN v_hpill IS NOT NULL
              THEN info_icon('based on how closely past growth follows a straight line') END
      || '</h4>');

    IF v_hquality = 'OK' THEN
      p('<div class="g-line">now using ' || fmt_size_gb(v_hero_gb)
        || ', likely around ' || fmt_size_gb(v_proj_gb)
        || ' by ' || TO_CHAR(hf.last_day + 180, 'FMMonth YYYY') || '</div>');
    ELSE
      p('<div class="g-line">now using ' || fmt_size_gb(v_hero_gb) || '</div>');
    END IF;
    IF v_days_to_lim IS NOT NULL THEN
      p('<div class="g-line">at this pace, the total allocated limit of ' || fmt_size_gb(v_hlimit_gb)
        || ' would be reached around ' || TO_CHAR(hf.last_day + v_days_to_lim, 'FMMonth YYYY') || '</div>');
    END IF;

    -- Full-width chart: total-size history (+ projection when OK) + limit line.
    -- Same gap-fill as the regression series above (carry each tablespace's
    -- last known size across missing days), so the plotted line matches the
    -- fitted one and never shows a phantom dip on an AWR-gap day.
    xs.DELETE; ys.DELETE; v_cnt := 0;
    FOR d IN (
      SELECT gg.day_dt, SUM(gg.used_fill) / 1073741824 AS gb
      FROM (
        SELECT gr.day_dt,
               LAST_VALUE(fb.used_bytes IGNORE NULLS) OVER
                 (PARTITION BY gr.tablespace_name ORDER BY gr.day_dt
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS used_fill
        FROM (
           SELECT dd.day_dt, tt.tablespace_name
           FROM   (SELECT DISTINCT day_dt FROM capd_tbspc_daily
                   WHERE dbid = hf.dbid AND con_dbid = hf.con_dbid) dd
           CROSS JOIN (SELECT DISTINCT tablespace_name FROM capd_tbspc_daily
                       WHERE dbid = hf.dbid AND con_dbid = hf.con_dbid) tt
        ) gr
        LEFT JOIN capd_tbspc_daily fb
          ON  fb.dbid = hf.dbid AND fb.con_dbid = hf.con_dbid
          AND fb.tablespace_name = gr.tablespace_name
          AND fb.day_dt = gr.day_dt
      ) gg
      GROUP  BY gg.day_dt
      ORDER  BY gg.day_dt
    ) LOOP
      v_cnt := v_cnt + 1;
      xs(v_cnt) := d.day_dt - c_epoch;
      ys(v_cnt) := d.gb;
    END LOOP;

    IF v_cnt = 0 THEN
      p('<div class="empty-note">No daily totals collected yet to chart.</div>');
    ELSE
      v_last_day_n := xs(v_cnt);
      v_xmin := xs(1); v_xmax := v_last_day_n; v_proj_y := NULL;
      IF v_hquality = 'OK' AND hf.slope IS NOT NULL THEN
        v_proj_y := ys(v_cnt) + (hf.slope / 1073741824) * 180;
        v_xmax   := v_last_day_n + 180;
      END IF;

      v_ymin := 0; v_ymax := ys(1);
      FOR i IN 1 .. v_cnt LOOP
        IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF;
        IF ys(i) < v_ymin THEN v_ymin := ys(i); END IF;
      END LOOP;
      IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
      IF v_proj_y IS NOT NULL AND v_proj_y < v_ymin THEN v_ymin := v_proj_y; END IF;

      -- Limit line: only when meaningful (all tablespaces non-null on the last
      -- day) AND within 3x the data range (same heuristic as per-tablespace).
      v_limit_gb   := v_hlimit_gb;
      v_range      := v_ymax - v_ymin;
      v_show_limit := (v_limit_gb IS NOT NULL) AND (v_limit_gb - v_ymax) <= 3 * v_range;
      IF v_show_limit THEN
        v_ymax := GREATEST(v_ymax, v_limit_gb * 1.04);
      END IF;
      IF (v_ymax - v_ymin) < 0.001 THEN v_ymax := v_ymin + 1; END IF; -- flat guard
      v_ymax := v_ymax + (v_ymax - v_ymin) * 0.08;

      IF v_limit_gb IS NOT NULL AND NOT v_show_limit THEN
        p('<div class="g-line">(allocated-limit line hidden: off the chart scale)</div>');
      END IF;

      p('<svg viewBox="0 0 ' || TO_CHAR(c_hw, 'FM9990') || ' ' || TO_CHAR(c_hh, 'FM9990')
        || '" class="hero-svg" role="img" aria-label="Whole database total size chart">');
      emit_yaxis_box(v_ymin, v_ymax, ' GB', c_hml, c_hw - c_hmr, c_hmt, c_hh - c_hmb, 5);
      p('<text class="axis-label" x="' || fmt_px(lin(v_xmin, v_xmin, v_xmax, c_hml, c_hw - c_hmr))
        || '" y="' || fmt_px(c_hh - 6) || '" text-anchor="start">'
        || TO_CHAR(c_epoch + v_xmin, 'YYYY-MM-DD') || '</text>');
      IF v_xmax > v_xmin THEN
        p('<text class="axis-label" x="'
          || fmt_px(lin(ROUND((v_xmin + v_xmax) / 2), v_xmin, v_xmax, c_hml, c_hw - c_hmr))
          || '" y="' || fmt_px(c_hh - 6) || '" text-anchor="middle">'
          || TO_CHAR(c_epoch + ROUND((v_xmin + v_xmax) / 2), 'YYYY-MM-DD') || '</text>');
        p('<text class="axis-label" x="' || fmt_px(lin(v_xmax, v_xmin, v_xmax, c_hml, c_hw - c_hmr))
          || '" y="' || fmt_px(c_hh - 6) || '" text-anchor="end">'
          || TO_CHAR(c_epoch + v_xmax, 'YYYY-MM-DD') || '</text>');
      END IF;
      p('<line class="axis-line" x1="' || fmt_px(c_hml) || '" y1="' || fmt_px(c_hh - c_hmb)
        || '" x2="' || fmt_px(c_hw - c_hmr) || '" y2="' || fmt_px(c_hh - c_hmb) || '"/>');
      p('<line class="axis-line" x1="' || fmt_px(c_hml) || '" y1="' || fmt_px(c_hmt)
        || '" x2="' || fmt_px(c_hml) || '" y2="' || fmt_px(c_hh - c_hmb) || '"/>');
      IF v_show_limit THEN
        p('<line class="limit-line" x1="' || fmt_px(c_hml)
          || '" y1="' || fmt_px(lin(v_limit_gb, v_ymin, v_ymax, c_hh - c_hmb, c_hmt))
          || '" x2="' || fmt_px(c_hw - c_hmr)
          || '" y2="' || fmt_px(lin(v_limit_gb, v_ymin, v_ymax, c_hh - c_hmb, c_hmt)) || '"/>');
      END IF;
      emit_poly_box(xs, ys, v_cnt, v_xmin, v_xmax, v_ymin, v_ymax,
                    c_hml, c_hw - c_hmr, c_hmt, c_hh - c_hmb, 'hist-line');
      IF v_proj_y IS NOT NULL THEN
        px1(1) := v_last_day_n;       py1(1) := ys(v_cnt);
        px1(2) := v_last_day_n + 180; py1(2) := v_proj_y;
        emit_poly_box(px1, py1, 2, v_xmin, v_xmax, v_ymin, v_ymax,
                      c_hml, c_hw - c_hmr, c_hmt, c_hh - c_hmb, 'proj-line');
      END IF;
      p('</svg>');
    END IF;

    p('</div>');  -- .g-hero
  END LOOP;

  -- Host-CPU hero: one per con_dbid with BUSY_PCT data (same multiplicity rule
  -- as the DB hero). Headline reuses the CPU card copy; below it a busy% chart
  -- like section 4's (threshold line at cpu_sat, dashed REGR projection to +90
  -- when quality=OK, red anomaly dots) at the same 560x250 hero geometry.
  FOR ch IN (
    SELECT dbid, con_dbid, cur_val, days_to_sat, r2, quality, slope_per_day
    FROM   capf_cpu_trend
    WHERE  metric = 'BUSY_PCT'
    ORDER  BY con_dbid
  ) LOOP
    v_hlabel := 'Host CPU'
                || CASE WHEN v_con_count > 1 THEN ' (' || db_label(ch.dbid, ch.con_dbid) || ')' END;
    v_hpill := NULL;
    IF ch.quality = 'OK' AND ch.days_to_sat IS NOT NULL THEN
      v_accent := CASE WHEN ch.days_to_sat <= dtf_crit THEN 'g-crit'
                       WHEN ch.days_to_sat <= dtf_warn THEN 'g-warn'
                       ELSE 'g-ok' END;
      v_head := esc(v_hlabel) || ' &mdash; reaches ' || TO_CHAR(cpu_sat, 'FM990')
                || '% busy in ' || time_phrase(ch.days_to_sat);
      v_hpill := ' <span class="pill '
                 || CASE WHEN ch.r2 >= 0.9 THEN 'pill-ok">high confidence'
                         ELSE 'pill-flat">good confidence' END || '</span>';
    ELSE
      v_accent := 'g-ok';
      IF ch.quality = 'INSUFFICIENT_HISTORY' THEN
        v_head := esc(v_hlabel) || ' &mdash; not enough history yet for a reliable estimate';
      ELSIF ch.quality = 'LOW_CONFIDENCE' THEN
        v_head := esc(v_hlabel) || ' &mdash; recent CPU is too erratic for a reliable estimate';
      ELSE
        v_head := esc(v_hlabel) || ' &mdash; no saturation in sight at the current trend';
      END IF;
    END IF;

    p('<div class="gcard g-hero ' || v_accent || '">');
    p('<h4 class="g-head">' || v_head || v_hpill
      || CASE WHEN v_hpill IS NOT NULL
              THEN info_icon('based on how closely past growth follows a straight line') END
      || '</h4>');
    IF ch.quality = 'OK' AND ch.days_to_sat IS NOT NULL THEN
      p('<div class="g-date">around ' || TO_CHAR(SYSDATE + ch.days_to_sat, 'FMMonth YYYY') || '</div>');
    END IF;
    p('<div class="g-line">now at ' || TO_CHAR(ch.cur_val, 'FM990.0') || '% busy</div>');

    xs.DELETE; ys.DELETE; v_cnt := 0;
    FOR d IN (SELECT day_dt, busy_pct FROM capd_cpu_daily
              WHERE con_dbid = ch.con_dbid ORDER BY day_dt) LOOP
      v_cnt := v_cnt + 1;
      xs(v_cnt) := d.day_dt - c_epoch;
      ys(v_cnt) := d.busy_pct;
    END LOOP;

    IF v_cnt = 0 THEN
      p('<div class="empty-note">No daily CPU history collected yet to chart.</div>');
    ELSE
      v_last_day_n := xs(v_cnt); v_xmin := xs(1); v_xmax := v_last_day_n; v_proj_y := NULL;
      IF ch.quality = 'OK' AND ch.slope_per_day IS NOT NULL THEN
        v_proj_y := ys(v_cnt) + ch.slope_per_day * 90;
        v_xmax   := v_last_day_n + 90;
      END IF;
      v_ymin := 0; v_ymax := ys(1);
      FOR i IN 1 .. v_cnt LOOP
        IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF;
      END LOOP;
      IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
      v_ymax := GREATEST(100, v_ymax);   -- 0..100+ keeps the cpu_sat line in range
      IF (v_ymax - v_ymin) < 1 THEN v_ymax := v_ymin + 1; END IF;
      v_ymax := v_ymax + (v_ymax - v_ymin) * 0.08;

      p('<svg viewBox="0 0 ' || TO_CHAR(c_hw, 'FM9990') || ' ' || TO_CHAR(c_hh, 'FM9990')
        || '" class="hero-svg" role="img" aria-label="Host CPU busy percent chart">');
      emit_yaxis_box(v_ymin, v_ymax, '%', c_hml, c_hw - c_hmr, c_hmt, c_hh - c_hmb, 5);
      p('<text class="axis-label" x="' || fmt_px(lin(v_xmin, v_xmin, v_xmax, c_hml, c_hw - c_hmr))
        || '" y="' || fmt_px(c_hh - 6) || '" text-anchor="start">'
        || TO_CHAR(c_epoch + v_xmin, 'YYYY-MM-DD') || '</text>');
      IF v_xmax > v_xmin THEN
        p('<text class="axis-label" x="'
          || fmt_px(lin(ROUND((v_xmin + v_xmax) / 2), v_xmin, v_xmax, c_hml, c_hw - c_hmr))
          || '" y="' || fmt_px(c_hh - 6) || '" text-anchor="middle">'
          || TO_CHAR(c_epoch + ROUND((v_xmin + v_xmax) / 2), 'YYYY-MM-DD') || '</text>');
        p('<text class="axis-label" x="' || fmt_px(lin(v_xmax, v_xmin, v_xmax, c_hml, c_hw - c_hmr))
          || '" y="' || fmt_px(c_hh - 6) || '" text-anchor="end">'
          || TO_CHAR(c_epoch + v_xmax, 'YYYY-MM-DD') || '</text>');
      END IF;
      p('<line class="axis-line" x1="' || fmt_px(c_hml) || '" y1="' || fmt_px(c_hh - c_hmb)
        || '" x2="' || fmt_px(c_hw - c_hmr) || '" y2="' || fmt_px(c_hh - c_hmb) || '"/>');
      p('<line class="axis-line" x1="' || fmt_px(c_hml) || '" y1="' || fmt_px(c_hmt)
        || '" x2="' || fmt_px(c_hml) || '" y2="' || fmt_px(c_hh - c_hmb) || '"/>');
      p('<line class="thresh-line" x1="' || fmt_px(c_hml)
        || '" y1="' || fmt_px(lin(cpu_sat, v_ymin, v_ymax, c_hh - c_hmb, c_hmt))
        || '" x2="' || fmt_px(c_hw - c_hmr)
        || '" y2="' || fmt_px(lin(cpu_sat, v_ymin, v_ymax, c_hh - c_hmb, c_hmt)) || '"/>');
      p('<text class="thresh-label" x="' || fmt_px(c_hw - c_hmr - 2)
        || '" y="' || fmt_px(lin(cpu_sat, v_ymin, v_ymax, c_hh - c_hmb, c_hmt) - 3)
        || '" text-anchor="end">sat ' || TO_CHAR(cpu_sat, 'FM990') || '%</text>');
      emit_poly_box(xs, ys, v_cnt, v_xmin, v_xmax, v_ymin, v_ymax,
                    c_hml, c_hw - c_hmr, c_hmt, c_hh - c_hmb, 'hist-line');
      IF v_proj_y IS NOT NULL THEN
        px1(1) := v_last_day_n;      py1(1) := ys(v_cnt);
        px1(2) := v_last_day_n + 90; py1(2) := v_proj_y;
        emit_poly_box(px1, py1, 2, v_xmin, v_xmax, v_ymin, v_ymax,
                      c_hml, c_hw - c_hmr, c_hmt, c_hh - c_hmb, 'proj-line');
      END IF;
      FOR a IN (SELECT day_dt, busy_pct FROM capa_cpu_anom
                WHERE con_dbid = ch.con_dbid AND anomaly_flag IS NOT NULL) LOOP
        p('<circle class="anom-dot" cx="' || fmt_px(lin(a.day_dt - c_epoch, v_xmin, v_xmax, c_hml, c_hw - c_hmr))
          || '" cy="' || fmt_px(lin(a.busy_pct, v_ymin, v_ymax, c_hh - c_hmb, c_hmt)) || '" r="3"/>');
      END LOOP;
      p('</svg>');
    END IF;

    p('</div>');  -- .g-hero (CPU)
  END LOOP;

  p('</div>');  -- .hero-duo

  -- Anomaly timeline (second, per DBA priority: is anything spiking?) --------
  p('<h3 style="font-size:13px;margin:18px 0 6px">Unusual activity in the last '
      || TO_CHAR(anomaly_days, 'FM999990') || ' days</h3>');

  -- Window: [max(day) - anomaly_days, max(day)] across both daily fact
  -- views. NULL max => no daily data at all.
  SELECT MAX(mx) INTO v_tl_max FROM (
    SELECT MAX(day_dt) AS mx FROM capd_tbspc_daily
    UNION ALL
    SELECT MAX(day_dt) AS mx FROM capd_cpu_daily
  );

  IF v_tl_max IS NULL THEN
    p('<div class="empty-note">No daily history collected yet to scan for unusual activity.</div>');
  ELSE
    v_tl_min := v_tl_max - anomaly_days;

    -- Total number of series (lanes) with >=1 flagged anomaly in-window.
    SELECT COUNT(*) INTO v_lane_total FROM (
      SELECT con_dbid, tablespace_name
      FROM   capa_tbspc_anom
      WHERE  anomaly_flag IS NOT NULL AND day_dt > v_tl_min AND day_dt <= v_tl_max
      GROUP  BY con_dbid, tablespace_name
      UNION ALL
      SELECT con_dbid, TO_CHAR(NULL)
      FROM   capa_cpu_anom
      WHERE  anomaly_flag IS NOT NULL AND day_dt > v_tl_min AND day_dt <= v_tl_max
      GROUP  BY con_dbid
    );

    IF v_lane_total = 0 THEN
      p('<div class="glance-ok">No unusual activity in the last '
        || TO_CHAR(anomaly_days, 'FM999990') || ' days.</div>');
    ELSE
      v_lane_shown := LEAST(v_lane_total, 12);
      v_tl_h  := c_tlmt + v_lane_shown * c_lane + c_tlmb;
      v_axis_y := c_tlmt + v_lane_shown * c_lane + 16;
      v_xmin  := v_tl_min - c_epoch;   -- reuse chart x-extent scratch as day numbers
      v_xmax  := v_tl_max - c_epoch;

      p('<div class="timeline-card">');
      p('<svg viewBox="0 0 ' || TO_CHAR(c_tlw, 'FM9990') || ' ' || TO_CHAR(v_tl_h, 'FM99990')
        || '" class="timeline-svg" role="img" aria-label="Anomaly timeline">');

      -- Light weekly gridlines, anchored to the newest day.
      v_gd := v_tl_max;
      WHILE v_gd > v_tl_min LOOP
        p('<line class="tl-grid" x1="' || fmt_px(lin(v_gd - c_epoch, v_xmin, v_xmax, c_tllm, c_tlw - c_tlrm))
          || '" y1="' || fmt_px(c_tlmt - 2)
          || '" x2="' || fmt_px(lin(v_gd - c_epoch, v_xmin, v_xmax, c_tllm, c_tlw - c_tlrm))
          || '" y2="' || fmt_px(c_tlmt + v_lane_shown * c_lane + 2) || '"/>');
        v_gd := v_gd - 7;
      END LOOP;

      -- Date labels: start / middle / end.
      p('<text class="tl-axis-label" x="' || fmt_px(c_tllm) || '" y="' || fmt_px(v_axis_y)
        || '" text-anchor="start">' || TO_CHAR(v_tl_min, 'YYYY-MM-DD') || '</text>');
      p('<text class="tl-axis-label" x="' || fmt_px((c_tllm + c_tlw - c_tlrm) / 2) || '" y="' || fmt_px(v_axis_y)
        || '" text-anchor="middle">' || TO_CHAR(v_tl_min + (v_tl_max - v_tl_min) / 2, 'YYYY-MM-DD') || '</text>');
      p('<text class="tl-axis-label" x="' || fmt_px(c_tlw - c_tlrm) || '" y="' || fmt_px(v_axis_y)
        || '" text-anchor="end">' || TO_CHAR(v_tl_max, 'YYYY-MM-DD') || '</text>');

      -- One lane per affected series, most-active first, capped at 12.
      v_lane_i := 0;
      FOR ln IN (
        SELECT kind, con_dbid, skey, label, ac FROM (
          SELECT 'TBSPC' AS kind, con_dbid, tablespace_name AS skey,
                 tablespace_name AS label, COUNT(*) AS ac
          FROM   capa_tbspc_anom
          WHERE  anomaly_flag IS NOT NULL AND day_dt > v_tl_min AND day_dt <= v_tl_max
          GROUP  BY con_dbid, tablespace_name
          UNION ALL
          SELECT 'CPU' AS kind, con_dbid, TO_CHAR(NULL) AS skey,
                 'Host CPU' AS label, COUNT(*) AS ac
          FROM   capa_cpu_anom
          WHERE  anomaly_flag IS NOT NULL AND day_dt > v_tl_min AND day_dt <= v_tl_max
          GROUP  BY con_dbid
        )
        ORDER  BY ac DESC, label
        FETCH FIRST 12 ROWS ONLY
      ) LOOP
        v_lane_i := v_lane_i + 1;
        v_base_y := c_tlmt + (v_lane_i - 0.5) * c_lane;
        p('<line class="tl-baseline" x1="' || fmt_px(c_tllm) || '" y1="' || fmt_px(v_base_y)
          || '" x2="' || fmt_px(c_tlw - c_tlrm) || '" y2="' || fmt_px(v_base_y) || '"/>');
        p('<text class="tl-lane-label" x="6" y="' || fmt_px(v_base_y + 3) || '">'
          || esc(ln.label) || '</text>');

        IF ln.kind = 'TBSPC' THEN
          FOR a IN (
            SELECT TO_CHAR(day_dt, 'YYYY-MM-DD') AS d_str, day_dt,
                   used_delta_bytes, used_rate_bpd, median_rate_bpd
            FROM   capa_tbspc_anom
            WHERE  con_dbid = ln.con_dbid AND tablespace_name = ln.skey
              AND  anomaly_flag IS NOT NULL AND day_dt > v_tl_min AND day_dt <= v_tl_max
          ) LOOP
            v_delta_gb := NVL(a.used_delta_bytes, 0) / 1073741824;
            IF NVL(a.used_delta_bytes, 0) >= 0 THEN
              v_tip := a.d_str || ': grew ' || TO_CHAR(v_delta_gb, 'FM999990.0') || ' GB in one day';
              IF a.median_rate_bpd IS NULL OR a.median_rate_bpd <= 0 THEN
                v_tip := v_tip || ', vs almost no usual growth';
              ELSE
                v_mult := a.used_rate_bpd / a.median_rate_bpd;
                IF v_mult >= 10 THEN
                  v_tip := v_tip || ', about ' || TO_CHAR(ROUND(v_mult), 'FM999990') || 'x its usual pace';
                ELSIF v_mult > 0 THEN
                  v_tip := v_tip || ', about ' || TO_CHAR(ROUND(v_mult, 1), 'FM990.0') || 'x its usual pace';
                END IF;
              END IF;
            ELSE
              v_tip := a.d_str || ': shrank ' || TO_CHAR(ABS(v_delta_gb), 'FM999990.0') || ' GB in one day';
            END IF;
            p('<circle class="anom-dot" cx="'
              || fmt_px(lin(a.day_dt - c_epoch, v_xmin, v_xmax, c_tllm, c_tlw - c_tlrm))
              || '" cy="' || fmt_px(v_base_y) || '" r="3.4"><title>' || esc(v_tip) || '</title></circle>');
          END LOOP;
        ELSE
          FOR a IN (
            SELECT TO_CHAR(day_dt, 'YYYY-MM-DD') AS d_str, day_dt, busy_pct, median_pct
            FROM   capa_cpu_anom
            WHERE  con_dbid = ln.con_dbid
              AND  anomaly_flag IS NOT NULL AND day_dt > v_tl_min AND day_dt <= v_tl_max
          ) LOOP
            IF a.median_pct IS NULL THEN
              v_tip := a.d_str || ': ' || TO_CHAR(ROUND(a.busy_pct), 'FM990')
                       || '% busy, unusual for that weekday';
            ELSE
              v_tip := a.d_str || ': ' || TO_CHAR(ROUND(a.busy_pct), 'FM990')
                       || '% busy vs the usual ' || TO_CHAR(ROUND(a.median_pct), 'FM990')
                       || '% for that weekday';
            END IF;
            p('<circle class="anom-dot" cx="'
              || fmt_px(lin(a.day_dt - c_epoch, v_xmin, v_xmax, c_tllm, c_tlw - c_tlrm))
              || '" cy="' || fmt_px(v_base_y) || '" r="3.4"><title>' || esc(v_tip) || '</title></circle>');
          END LOOP;
        END IF;
      END LOOP;

      p('</svg>');
      p('</div>');  -- .timeline-card
      IF v_lane_total > v_lane_shown THEN
        p('<div class="note">Showing the ' || TO_CHAR(v_lane_shown, 'FM990')
          || ' most active series; ' || TO_CHAR(v_lane_total - v_lane_shown, 'FM999990')
          || ' more with unusual activity are not charted here.</div>');
      END IF;
    END IF;
  END IF;

  -- Best-guess tablespace cards (which specific tablespace, and when). CPU now
  -- lives in the hero duo above, so this grid is tablespace-only.
  v_card_count := 0;
  p('<div class="glance-grid">');

  -- Near-full-NOW cards first (M7.1): any tablespace at/over the near-full
  -- warning percent gets a card regardless of fit quality, so being unable
  -- to forecast it can never hide it.
  FOR r IN (
    SELECT tablespace_name,
           cur_used    / 1073741824 AS cur_gb,
           limit_bytes / 1073741824 AS lim_gb,
           pct_used, quality
    FROM   capf_tbspc_forecast
    WHERE  pct_used >= nf_warn
    ORDER  BY pct_used DESC
    FETCH FIRST top_n ROWS ONLY
  ) LOOP
    v_card_count := v_card_count + 1;
    v_accent := CASE WHEN r.pct_used >= nf_crit THEN 'g-crit' ELSE 'g-warn' END;
    p('<div class="gcard ' || v_accent || '">');
    p('<h4 class="g-head">' || esc(r.tablespace_name) || ' &mdash; '
      || TO_CHAR(r.pct_used, 'FM990.0') || '% full right now'
      || info_icon('how full it is today; this needs no forecast and is shown whatever the fit quality') || '</h4>');
    p('<div class="g-line">using ' || TO_CHAR(r.cur_gb, 'FM999999990.0')
      || ' of ' || TO_CHAR(r.lim_gb, 'FM999999990.0') || ' GB today</div>');
    IF r.quality <> 'OK' THEN
      p('<div class="g-line">growth cannot be forecast reliably (' || esc(r.quality) || ')</div>');
    END IF;
    p('</div>');
  END LOOP;

  -- One card per tablespace with a confident, computable days-to-full.
  FOR r IN (
    SELECT tablespace_name,
           cur_used    / 1073741824 AS cur_gb,
           limit_bytes / 1073741824 AS lim_gb,
           days_to_full,
           days_to_full_lo,
           r2
    FROM   capf_tbspc_forecast
    WHERE  quality = 'OK'
      AND  days_to_full IS NOT NULL
    ORDER  BY days_to_full
    FETCH FIRST top_n ROWS ONLY
  ) LOOP
    v_card_count := v_card_count + 1;
    v_accent := CASE WHEN r.days_to_full <= dtf_crit THEN 'g-crit'
                     WHEN r.days_to_full <= dtf_warn THEN 'g-warn'
                     ELSE 'g-ok' END;
    v_conf   := CASE WHEN r.r2 >= 0.9 THEN 'high confidence' ELSE 'good confidence' END;
    p('<div class="gcard ' || v_accent || '">');
    p('<h4 class="g-head">' || esc(r.tablespace_name) || ' &mdash; full in ' || time_phrase(r.days_to_full)
      || ' <span class="pill ' || CASE WHEN r.r2 >= 0.9 THEN 'pill-ok' ELSE 'pill-flat' END
      || '">' || v_conf || '</span>'
      || info_icon('based on how closely past growth follows a straight line') || '</h4>');
    p('<div class="g-date">around ' || TO_CHAR(SYSDATE + r.days_to_full, 'FMMonth YYYY') || '</div>');
    -- M9.1: worst-case (soonest plausible) fill date from the slope CI, shown
    -- only when it is meaningfully sooner than the central estimate.
    IF r.days_to_full_lo IS NOT NULL AND r.days_to_full_lo < r.days_to_full THEN
      p('<div class="g-line">worst case: in ' || time_phrase(r.days_to_full_lo)
        || ' (' || TO_CHAR(SYSDATE + r.days_to_full_lo, 'FMMonth YYYY') || ')</div>');
    END IF;
    IF r.lim_gb IS NOT NULL THEN
      p('<div class="g-line">using ' || TO_CHAR(r.cur_gb, 'FM999999990.0')
        || ' of ' || TO_CHAR(r.lim_gb, 'FM999999990.0') || ' GB today</div>');
    ELSE
      p('<div class="g-line">using ' || TO_CHAR(r.cur_gb, 'FM999999990.0') || ' GB today</div>');
    END IF;
    p('</div>');
  END LOOP;

  -- No cards at all: a single friendly empty-state card that explains why,
  -- keyed off whichever quality dominates the tablespace forecast.
  IF v_card_count = 0 THEN
    BEGIN
      SELECT quality INTO v_dom FROM (
        SELECT quality, COUNT(*) AS c
        FROM   capf_tbspc_forecast
        GROUP  BY quality
        ORDER  BY c DESC, quality
      ) WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_dom := NULL;
    END;
    v_msg := CASE v_dom
               WHEN 'INSUFFICIENT_HISTORY' THEN
                 'There is not enough history yet to make a reliable prediction. Once more days of '
                 || 'AWR data accumulate, best-guess forecasts will appear here.'
               WHEN 'FLAT' THEN
                 'Good news: nothing is on a path to filling up. No tablespace is growing enough to '
                 || 'run out of space at the current trend.'
               WHEN 'LOW_CONFIDENCE' THEN
                 'Growth is too up-and-down right now to give a dependable estimate. The detailed '
                 || 'tables below still show the raw numbers.'
               ELSE
                 'No forecast data is available yet.'
             END;
    p('<div class="gcard g-ok"><h4 class="g-head">'
      || CASE v_dom WHEN 'INSUFFICIENT_HISTORY' THEN 'Not enough history yet'
                    WHEN 'FLAT'                 THEN 'All quiet'
                    WHEN 'LOW_CONFIDENCE'       THEN 'No reliable estimate yet'
                    ELSE 'Nothing to show yet' END
      || '</h4><div class="g-line">' || v_msg || '</div></div>');
  END IF;
  p('</div>');  -- .glance-grid

  -- Roll-up line: what is NOT shown as a card, in friendly words.
  SELECT SUM(CASE WHEN quality = 'FLAT'                 THEN 1 ELSE 0 END),
         SUM(CASE WHEN quality = 'LOW_CONFIDENCE'       THEN 1 ELSE 0 END),
         SUM(CASE WHEN quality = 'INSUFFICIENT_HISTORY' THEN 1 ELSE 0 END)
    INTO v_n_flat, v_n_low, v_n_insuf
  FROM   capf_tbspc_forecast;
  v_roll := NULL;
  IF v_n_flat > 0 THEN
    v_roll := CASE WHEN v_n_flat = 1
                   THEN '1 tablespace isn''t growing at all (FLAT)'
                   ELSE TO_CHAR(v_n_flat, 'FM999990') || ' tablespaces aren''t growing at all (FLAT)' END;
  END IF;
  IF v_n_low > 0 THEN
    v_roll := v_roll || CASE WHEN v_roll IS NOT NULL THEN '; ' END
              || CASE WHEN v_n_low = 1
                      THEN '1 is growing too erratically for a reliable estimate (LOW_CONFIDENCE)'
                      ELSE TO_CHAR(v_n_low, 'FM999990')
                           || ' are growing too erratically for a reliable estimate (LOW_CONFIDENCE)' END;
  END IF;
  IF v_n_insuf > 0 THEN
    v_roll := v_roll || CASE WHEN v_roll IS NOT NULL THEN '; ' END
              || CASE WHEN v_n_insuf = 1
                      THEN '1 doesn''t have enough history yet (INSUFFICIENT_HISTORY)'
                      ELSE TO_CHAR(v_n_insuf, 'FM999990')
                           || ' don''t have enough history yet (INSUFFICIENT_HISTORY)' END;
  END IF;
  IF v_card_count > 0 AND v_roll IS NOT NULL THEN
    p('<div class="glance-rollup">Not shown as predictions: ' || v_roll || '.</div>');
  END IF;

  ----------------------------------------------------------------------
  -- Collapsible plain-English glossary (end of section 0). One line per term,
  -- worded for DBAs. Native details/summary -- no JS, prints collapsed.
  ----------------------------------------------------------------------
  p('<details class="glossary">');
  p('<summary>New to these terms? Plain-English glossary</summary>');
  p('<div class="gl-body"><dl>');
  p('<dt>Forecast / projection</dt><dd>Where a number is heading, based on its recent trend.</dd>');
  p('<dt>REGR (straight-line trend)</dt><dd>Fits a straight line through recent history and extends it forward.</dd>');
  p('<dt>ESM</dt><dd>Oracle''s machine-learning forecast; it also learns weekly patterns and is usually best for the next 30 days.</dd>');
  p('<dt>R2</dt><dd>How closely growth follows a straight line: 1.00 is perfectly steady, near 0 is erratic.</dd>');
  p('<dt>Quality: OK</dt><dd>Steady enough to forecast reliably.</dd>');
  p('<dt>Quality: LOW_CONFIDENCE</dt><dd>Growth is too erratic for a dependable estimate.</dd>');
  p('<dt>Quality: FLAT</dt><dd>Not growing at all.</dd>');
  p('<dt>Quality: INSUFFICIENT_HISTORY</dt><dd>Not enough days of AWR history yet.</dd>');
  p('<dt>Anomaly</dt><dd>A day that stands out sharply from what is normal for that series.</dd>');
  p('<dt>Robust z-score</dt><dd>How far outside its normal range a day was; 3 or more is clearly unusual.</dd>');
  p('<dt>MAD</dt><dd>Median absolute deviation -- a spike-resistant way of measuring "normal".</dd>');
  p('<dt>Days-to-full</dt><dd>Estimated days until a tablespace reaches its allocated limit.</dd>');
  p('<dt>Saturation</dt><dd>The busy percent at which the CPU is treated as maxed out.</dd>');
  p('</dl></div>');
  p('</details>');
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 1: days-to-full ranking
  ----------------------------------------------------------------------
  p('<section id="s1">');
  p('<h2>1. Tablespaces by days-to-full <span class="pill pill-crit">CRIT&le;' || dtf_crit
      || '</span> <span class="pill pill-warn">WARN&le;' || dtf_warn || '</span></h2>');
  p('<p class="desc">The tablespaces most likely to run out of space soonest, any fit quality '
      || '(trust the estimate per QUALITY; only OK is reliable); top ' || top_n
      || '. ACCEL&gt;1.5 = growth accelerating.</p>');

  any_rows := FALSE;
  FOR r IN (
    SELECT dbid,
           con_dbid,
           tablespace_name,
           cur_used    / 1024 / 1024 / 1024 AS cur_gb,
           limit_bytes / 1024 / 1024 / 1024 AS limit_gb,
           pct_used,
           slope_bpd   / 1024 / 1024        AS slope_mb,
           days_to_full,
           days_to_full_lo,
           days_to_full_hi,
           CASE WHEN days_to_full <= dtf_crit THEN 'CRIT'
                WHEN days_to_full <= dtf_warn THEN 'WARN'
                ELSE 'ok'  END              AS sev,
           quality,
           accel_ratio                      AS accel
    FROM   capf_tbspc_forecast
    WHERE  days_to_full IS NOT NULL
    ORDER  BY days_to_full
    FETCH FIRST top_n ROWS ONLY
  ) LOOP
    IF NOT any_rows THEN
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB' || info_icon('which database or container this row belongs to, relevant when one report covers a fleet')
        || '</th><th>TABLESPACE</th><th class="num">CUR_GB</th><th class="num">LIMIT_GB</th>'
        || '<th>FILL</th>'
        || '<th class="num">MB/DAY' || info_icon('the average megabytes this tablespace grows per day')
        || '</th><th class="num">DAYS_FULL' || info_icon('estimated days until it reaches its allocated limit at the current rate')
        || '</th><th class="num">RANGE' || info_icon('worst-to-best case days-to-full from the statistical uncertainty of the growth rate; never = it may not fill at the slow end')
        || '</th><th>SEV' || info_icon('how urgent this is: CRIT is within the critical window, WARN within the warning window')
        || '</th><th>QUALITY' || info_icon('reliability of the estimate -- only OK is a dependable forecast')
        || '</th><th class="num">ACCEL' || info_icon('above 1.5 means growth is speeding up') || '</th>'
        || '</tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td><td>' || esc(r.tablespace_name) || '</td>'
      || '<td class="num">' || nz(r.cur_gb) || '</td><td class="num">' || nz(r.limit_gb) || '</td>'
      || '<td>' || bar(r.pct_used,
                        CASE r.sev WHEN 'CRIT' THEN 'crit' WHEN 'WARN' THEN 'warn' ELSE '' END) || '</td>'
      || '<td class="num">' || nz(r.slope_mb, 'FM9999990.000') || '</td>'
      || '<td class="num">' || nz(r.days_to_full, 'FM99999990') || '</td>'
      || '<td class="num">'
      || CASE WHEN r.days_to_full_lo IS NULL THEN '&ndash;'
              ELSE TO_CHAR(r.days_to_full_lo, 'FM99999990') || '&ndash;'
                   || NVL(TO_CHAR(r.days_to_full_hi, 'FM99999990'), 'never') END || '</td>'
      || '<td>' || sev_pill(r.sev) || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td>'
      || '<td class="num">' || nz(r.accel, 'FM990.00') || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
  ELSE
    p('<div class="empty-note">No rows: no tablespace currently has a computable days_to_full.</div>');
  END IF;

  ----------------------------------------------------------------------
  -- Near-full NOW ranking (M7.1): by PCT_USED, independent of fit quality,
  -- so a 97%-full tablespace with an unreliable fit can never vanish from
  -- the report. Severity thresholds nf_warn/nf_crit from CAP_CONFIG.
  ----------------------------------------------------------------------
  p('<h3 style="font-size:13px;margin:16px 0 6px">Near-full now '
    || '<span class="pill pill-crit">CRIT&ge;' || TO_CHAR(nf_crit, 'FM990') || '%</span> '
    || '<span class="pill pill-warn">WARN&ge;' || TO_CHAR(nf_warn, 'FM990') || '%</span> '
    || info_icon('how full each tablespace is today, regardless of whether its growth can be forecast')
    || '</h3>');
  any_rows := FALSE;
  FOR r IN (
    SELECT dbid,
           con_dbid,
           tablespace_name,
           cur_used    / 1024 / 1024 / 1024 AS cur_gb,
           limit_bytes / 1024 / 1024 / 1024 AS limit_gb,
           pct_used,
           days_to_full,
           CASE WHEN pct_used >= nf_crit THEN 'CRIT'
                WHEN pct_used >= nf_warn THEN 'WARN'
                ELSE 'ok'  END              AS sev,
           quality
    FROM   capf_tbspc_forecast
    WHERE  pct_used IS NOT NULL
    ORDER  BY pct_used DESC
    FETCH FIRST top_n ROWS ONLY
  ) LOOP
    IF NOT any_rows THEN
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>TABLESPACE</th><th class="num">CUR_GB</th><th class="num">LIMIT_GB</th>'
        || '<th>FILL</th>'
        || '<th class="num">DAYS_FULL</th><th>SEV</th><th>QUALITY</th>'
        || '</tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td><td>' || esc(r.tablespace_name) || '</td>'
      || '<td class="num">' || nz(r.cur_gb) || '</td><td class="num">' || nz(r.limit_gb) || '</td>'
      || '<td>' || bar(r.pct_used,
                        CASE r.sev WHEN 'CRIT' THEN 'crit' WHEN 'WARN' THEN 'warn' ELSE '' END) || '</td>'
      || '<td class="num">' || nz(r.days_to_full, 'FM99999990') || '</td>'
      || '<td>' || sev_pill(r.sev) || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
  ELSE
    p('<div class="empty-note">No tablespaces with a known allocation limit to rank.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 2: tablespace forecast
  ----------------------------------------------------------------------
  p('<section id="s2">');
  p('<h2>2. Tablespace forecast (GB)</h2>');
  p('<p class="desc">Where each tablespace is headed in size over the next six months. '
      || 'current / +30 / +90 / +180, plus ESM +30 (Tier 2, 19c hard-capped at +30).</p>');

  ----------------------------------------------------------------------
  -- Chart grid: history + REGR projection (+180) + ESM+30 point/CI + limit
  -- line + anomaly dots, one card per tablespace, capped at top_n (ordered
  -- by days_to_full NULLS LAST, then name) so a fleet with hundreds of
  -- tablespaces doesn't render hundreds of charts. The legend above this
  -- grid is shared by every chart in the document (this is the first grid
  -- in document order).
  ----------------------------------------------------------------------
  chart_legend;

  SELECT COUNT(*) INTO v_total_ts FROM capf_tbspc_forecast;
  IF v_total_ts > top_n THEN
    p('<div class="note">Chart grid capped at top ' || top_n || ' of ' || v_total_ts
      || ' tablespaces (by days-to-full, NULLS LAST, then name); ' || (v_total_ts - top_n)
      || ' additional tablespace(s) are not charted here but still appear in the forecast '
      || 'table below.</div>');
  END IF;

  IF v_total_ts = 0 THEN
    p('<div class="empty-note">No tablespace forecast data to chart.</div>');
  ELSE
    p('<div class="chart-grid">');
    FOR f IN (
      SELECT dbid, con_dbid, tablespace_name, cur_used, limit_bytes, slope_bpd, quality
      FROM   capf_tbspc_forecast
      ORDER  BY days_to_full NULLS LAST, tablespace_name
      FETCH FIRST top_n ROWS ONLY
    ) LOOP
      xs.DELETE;
      ys.DELETE;
      v_cnt := 0;
      FOR h IN (SELECT day_dt, used_bytes / 1073741824 AS gb
                FROM   capd_tbspc_daily
                WHERE  dbid = f.dbid AND con_dbid = f.con_dbid AND tablespace_name = f.tablespace_name
                ORDER  BY day_dt) LOOP
        v_cnt := v_cnt + 1;
        xs(v_cnt) := h.day_dt - c_epoch;
        ys(v_cnt) := h.gb;
      END LOOP;

      IF v_cnt = 0 THEN
        chart_open(esc(f.tablespace_name) || ' ' || quality_pill(f.quality), NULL);
        p('<div class="empty-note">No daily history collected yet for this tablespace.</div>');
        p('</div>');
      ELSE
        -- ESM +30 point (if a fresh model exists for this series) -- same
        -- join CAPF_COMPARE predicate as the ESM+30 column in the table below.
        v_esm_val := NULL; v_esm_lo := NULL; v_esm_hi := NULL;
        BEGIN
          SELECT c.value / 1073741824, c.lower_bound / 1073741824, c.upper_bound / 1073741824
            INTO   v_esm_val, v_esm_lo, v_esm_hi
          FROM   capf_compare c
          WHERE  c.engine = 'ESM' AND c.series_kind = 'TBSPC'
            AND  c.dbid = f.dbid AND c.con_dbid = f.con_dbid AND c.series_key = f.tablespace_name
            AND  c.horizon_days = 30;
        EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
        END;

        v_last_day_n := xs(v_cnt);
        v_xmin       := xs(1);
        v_xmax       := v_last_day_n;
        v_proj_y     := NULL;
        -- REGR projection only when quality=OK (matches the report's own
        -- quality gate); FLAT/LOW_CONFIDENCE/INSUFFICIENT_HISTORY tablespaces
        -- still get a history-only chart.
        IF f.quality = 'OK' AND f.slope_bpd IS NOT NULL THEN
          v_proj_y := ys(v_cnt) + (f.slope_bpd / 1073741824) * 180;
          v_xmax   := v_last_day_n + 180;
        END IF;
        IF v_esm_val IS NOT NULL THEN
          v_xmax := GREATEST(v_xmax, v_last_day_n + 30);
        END IF;

        -- Y-range: floor at 0, pad 8%, then decide whether the tablespace
        -- limit fits without blowing up the scale (limit line would sit
        -- more than 3x the current data range above the data/projection
        -- max) -- if not, omit the line and say so in the subtitle instead.
        v_ymin := 0;
        v_ymax := ys(1);
        FOR i IN 1 .. v_cnt LOOP
          IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF;
        END LOOP;
        IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
        IF v_esm_hi  IS NOT NULL AND v_esm_hi  > v_ymax THEN v_ymax := v_esm_hi; END IF;
        IF v_esm_lo  IS NOT NULL AND v_esm_lo  < v_ymin THEN v_ymin := v_esm_lo; END IF;
        IF (v_ymax - v_ymin) < 1 THEN v_ymax := v_ymin + 1; END IF; -- flat/zero-series guard

        v_limit_gb   := f.limit_bytes / 1073741824;
        v_range      := v_ymax - v_ymin;
        v_show_limit := (v_limit_gb IS NOT NULL) AND (v_limit_gb - v_ymax) <= 3 * v_range;
        IF v_show_limit THEN
          v_ymax := GREATEST(v_ymax, v_limit_gb * 1.04);
        END IF;
        v_ymax := v_ymax + (v_ymax - v_ymin) * 0.08;

        -- COALESCE, not nz(): nz's '&ndash;' placeholder would be re-escaped
        -- by chart_open's esc() and render as literal "&amp;ndash;" text.
        v_subtitle := 'cur ' || COALESCE(TO_CHAR(f.cur_used / 1073741824, 'FM999999990.00'), 'n/a')
                      || ' GB | limit ' || COALESCE(TO_CHAR(v_limit_gb, 'FM999999990.00'), 'n/a') || ' GB';
        IF v_limit_gb IS NOT NULL AND NOT v_show_limit THEN
          v_subtitle := v_subtitle || ' (line hidden, out of chart scale)';
        END IF;
        chart_open(esc(f.tablespace_name) || ' ' || quality_pill(f.quality), v_subtitle);

        p('<svg viewBox="0 0 560 230" class="chart-svg" role="img" aria-label="'
          || esc(f.tablespace_name) || ' growth chart">');
        emit_y_axis(v_ymin, v_ymax, ' GB');
        emit_x_axis(v_xmin, v_xmax);
        chart_axes_frame;
        IF v_show_limit THEN
          p('<line class="limit-line" x1="' || fmt_px(c_ml) || '" y1="' || fmt_px(scale_y(v_limit_gb, v_ymin, v_ymax))
            || '" x2="' || fmt_px(c_cw - c_mr) || '" y2="' || fmt_px(scale_y(v_limit_gb, v_ymin, v_ymax)) || '"/>');
        END IF;
        emit_polyline(xs, ys, v_cnt, v_xmin, v_xmax, v_ymin, v_ymax, 'hist-line');
        IF v_proj_y IS NOT NULL THEN
          px1(1) := v_last_day_n;       py1(1) := ys(v_cnt);
          px1(2) := v_last_day_n + 180; py1(2) := v_proj_y;
          emit_polyline(px1, py1, 2, v_xmin, v_xmax, v_ymin, v_ymax, 'proj-line');
        END IF;
        IF v_esm_val IS NOT NULL THEN
          p('<line class="esm-line" x1="' || fmt_px(scale_x(v_last_day_n + 30, v_xmin, v_xmax))
            || '" y1="' || fmt_px(scale_y(v_esm_lo, v_ymin, v_ymax))
            || '" x2="' || fmt_px(scale_x(v_last_day_n + 30, v_xmin, v_xmax))
            || '" y2="' || fmt_px(scale_y(v_esm_hi, v_ymin, v_ymax)) || '"/>');
          p('<circle class="esm-dot" cx="' || fmt_px(scale_x(v_last_day_n + 30, v_xmin, v_xmax))
            || '" cy="' || fmt_px(scale_y(v_esm_val, v_ymin, v_ymax)) || '" r="2.6"/>');
        END IF;
        FOR a IN (SELECT an.day_dt, d.used_bytes / 1073741824 AS gb
                  FROM   capa_tbspc_anom an
                  JOIN   capd_tbspc_daily d
                    ON   d.dbid = an.dbid AND d.con_dbid = an.con_dbid
                   AND   d.tablespace_name = an.tablespace_name AND d.day_dt = an.day_dt
                  WHERE  an.dbid = f.dbid AND an.con_dbid = f.con_dbid
                    AND  an.tablespace_name = f.tablespace_name
                    AND  an.anomaly_flag IS NOT NULL) LOOP
          p('<circle class="anom-dot" cx="' || fmt_px(scale_x(a.day_dt - c_epoch, v_xmin, v_xmax))
            || '" cy="' || fmt_px(scale_y(a.gb, v_ymin, v_ymax)) || '" r="3"/>');
        END LOOP;
        p('</svg>');
        p('</div>');
      END IF;
    END LOOP;
    p('</div>');
  END IF;

  any_rows := FALSE;
  FOR r IN (
    SELECT f.dbid,
           f.con_dbid,
           f.tablespace_name,
           f.train_n                          AS n,
           f.cur_used       / 1073741824 AS cur_gb,
           f.proj_30_bytes  / 1073741824 AS p30,
           f.proj_90_bytes  / 1073741824 AS p90,
           f.proj_180_bytes / 1073741824 AS p180,
           f.proj_180_lo    / 1073741824 AS p180_lo,
           f.proj_180_hi    / 1073741824 AS p180_hi,
           f.r2,
           f.quality,
           (SELECT c.value / 1073741824 FROM capf_compare c
             WHERE c.engine='ESM' AND c.series_kind='TBSPC'
               AND c.dbid=f.dbid AND c.con_dbid=f.con_dbid AND c.series_key=f.tablespace_name
               AND c.horizon_days=30)          AS esm30
    FROM   capf_tbspc_forecast f
    ORDER  BY f.con_dbid, f.tablespace_name
  ) LOOP
    IF NOT any_rows THEN
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>TABLESPACE</th>'
        || '<th class="num">TRAIN_N' || info_icon('how many days of history the estimate is based on -- more is better')
        || '</th><th class="num">CUR_GB</th>'
        || '<th class="num">+30_GB</th><th class="num">+90_GB</th><th class="num">+180_GB</th>'
        || '<th class="num">180_LO</th><th class="num">180_HI'
        || info_icon('95% prediction band on the +180-day projection; the actual value should land between LO and HI 95 times out of 100 if growth stays like the recent past')
        || '</th><th class="num">R2' || info_icon('how closely growth follows a straight line: 1.00 = perfectly steady, near 0 = erratic')
        || '</th><th>QUALITY' || info_icon('our own reliability grade for this estimate -- hover the colored labels below')
        || '</th><th class="num">ESM+30' || info_icon('a second, machine-learning estimate of the size 30 days from now -- usually the most accurate short-term number when present')
        || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td><td>' || esc(r.tablespace_name) || '</td>'
      || '<td class="num">' || nz(r.n, 'FM9990') || '</td>'
      || '<td class="num">' || nz(r.cur_gb) || '</td>'
      || '<td class="num">' || nz(r.p30) || '</td>'
      || '<td class="num">' || nz(r.p90) || '</td>'
      || '<td class="num">' || nz(r.p180) || '</td>'
      || '<td class="num">' || nz(r.p180_lo) || '</td>'
      || '<td class="num">' || nz(r.p180_hi) || '</td>'
      || '<td class="num">' || nz(r.r2, 'FM90.000') || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td>'
      || '<td class="num">' || nz(r.esm30) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
  ELSE
    p('<div class="empty-note">No tablespace forecast rows found.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 3: tablespace growth anomalies
  ----------------------------------------------------------------------
  p('<section id="s3">');
  p('<h2>3. Tablespace growth anomalies <span style="font-weight:400;color:var(--muted);font-size:12px">(last '
      || anomaly_days || ' days)</span></h2>');
  p('<p class="desc">Days when a tablespace grew (or shrank) much faster than its own normal pace. '
      || 'FLAG when |rate - median_rate| exceeds max(k*MAD, 100MiB/day floor). '
      || 'GAP = days since previous sample.</p>');

  any_rows := FALSE;
  FOR r IN (
    SELECT dbid,
           con_dbid,
           tablespace_name,
           TO_CHAR(day_dt,'YYYY-MM-DD')     AS day_dt,
           day_gap                    AS gap,
           used_delta_bytes / 1048576 AS delta_mb,
           used_rate_bpd    / 1048576 AS rate_mb,
           median_rate_bpd  / 1048576 AS med_mb,
           threshold_bpd    / 1048576 AS thr_mb,
           robust_z                   AS z,
           anomaly_flag
    FROM   capa_tbspc_anom
    WHERE  anomaly_flag IS NOT NULL
      AND  day_dt > (SELECT MAX(day_dt) FROM capd_tbspc_daily) - anomaly_days
    ORDER  BY day_dt DESC, con_dbid, tablespace_name
  ) LOOP
    IF NOT any_rows THEN
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>TABLESPACE</th><th>DAY</th>'
        || '<th class="num">GAP' || info_icon('days since the previous sample -- a big gap can inflate a one-day change')
        || '</th><th class="num">DELTA_MB</th>'
        || '<th class="num">RATE_MB/D' || info_icon('how fast it grew that day, in megabytes per day')
        || '</th><th class="num">MED_MB/D' || info_icon('its usual daily growth rate over the recent baseline window')
        || '</th><th class="num">THR_MB/D' || info_icon('how far from usual a day must be before it is flagged')
        || '</th><th class="num">ROBUST_Z' || info_icon('how far outside its normal range this day was -- 3 or more is clearly unusual')
        || '</th><th>FLAG' || info_icon('the direction of the flagged change for this day') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td><td>' || esc(r.tablespace_name) || '</td><td>' || r.day_dt || '</td>'
      || '<td class="num">' || nz(r.gap, 'FM990') || '</td>'
      || '<td class="num">' || nz(r.delta_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.rate_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.med_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.thr_mb, 'FM9999990.0') || '</td>'
      || '<td class="num' || (CASE WHEN ABS(NVL(r.z,0)) >= 3 THEN ' z-hi' ELSE '' END) || '">'
         || nz(r.z, 'FM99990.0') || '</td>'
      || '<td class="sev-crit">' || esc(r.anomaly_flag) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
  ELSE
    p('<div class="empty-note">No tablespace growth anomalies flagged in the selected window.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 4: CPU trend
  ----------------------------------------------------------------------
  p('<section id="s4">');
  p('<h2>4. CPU trend (host busy% and DB CPU sec/day)</h2>');
  p('<p class="desc">How busy the CPU has been, and when it might run out of headroom. '
      || 'DAYS_SAT = projected days until host busy% reaches ' || cpu_sat
      || '% (BUSY_PCT only).</p>');

  ----------------------------------------------------------------------
  -- Chart grid: one busy% card (history + saturation threshold + REGR
  -- projection to +90 + anomaly dots) and one DB CPU sec/day card (history
  -- + REGR projection to +90; no fixed ceiling, so no threshold line, and
  -- CAPA_CPU_ANOM only covers busy%, so no anomaly dots there) per con_dbid.
  -- Note (fleet/warehouse edge case): like the existing section 4/5 tables,
  -- this groups by con_dbid only, matching CAPF_CPU_TREND/CAPD_*_DAILY's own
  -- grouping; a con_dbid shared by more than one dbid (uncommon) would blend
  -- those dbids' days into one history line and pick one dbid's trend row
  -- arbitrarily for the projection.
  ----------------------------------------------------------------------
  SELECT COUNT(*) INTO v_total_ts FROM dual
  WHERE  EXISTS (SELECT 1 FROM capd_cpu_daily) OR EXISTS (SELECT 1 FROM capd_dbtime_daily);
  IF v_total_ts = 0 THEN
    p('<div class="empty-note">No daily CPU history collected yet to chart.</div>');
  ELSE
    p('<div class="chart-grid">');
    FOR cd IN (SELECT con_dbid FROM (
                 SELECT DISTINCT con_dbid FROM capd_cpu_daily
                 UNION
                 SELECT DISTINCT con_dbid FROM capd_dbtime_daily
               ) ORDER BY con_dbid) LOOP

      -- ---- Busy% card ----
      xs.DELETE; ys.DELETE; v_cnt := 0;
      FOR h IN (SELECT day_dt, busy_pct FROM capd_cpu_daily
                WHERE con_dbid = cd.con_dbid ORDER BY day_dt) LOOP
        v_cnt := v_cnt + 1;
        xs(v_cnt) := h.day_dt - c_epoch;
        ys(v_cnt) := h.busy_pct;
      END LOOP;

      v_quality := NULL; v_slope := NULL;
      FOR t IN (SELECT slope_per_day, quality FROM capf_cpu_trend
                WHERE con_dbid = cd.con_dbid AND metric = 'BUSY_PCT'
                ORDER BY dbid FETCH FIRST 1 ROW ONLY) LOOP
        v_quality := t.quality;
        v_slope   := t.slope_per_day;
      END LOOP;

      chart_open('Host CPU busy% (' || esc(db_label(NULL, cd.con_dbid)) || ')',
                  'saturation threshold ' || TO_CHAR(cpu_sat, 'FM990') || '%');
      IF v_cnt = 0 THEN
        p('<div class="empty-note">No daily CPU history collected yet for this container.</div>');
      ELSE
        v_xmin := xs(1); v_xmax := xs(v_cnt); v_last_day_n := xs(v_cnt); v_proj_y := NULL;
        IF v_quality = 'OK' AND v_slope IS NOT NULL THEN
          v_proj_y := ys(v_cnt) + v_slope * 90;
          v_xmax   := v_last_day_n + 90;
        END IF;
        v_ymin := 0; v_ymax := ys(1);
        FOR i IN 1 .. v_cnt LOOP
          IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF;
        END LOOP;
        IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
        v_ymax := GREATEST(v_ymax, cpu_sat); -- keep the threshold line always in-range
        IF (v_ymax - v_ymin) < 1 THEN v_ymax := v_ymin + 1; END IF;
        v_ymax := v_ymax + (v_ymax - v_ymin) * 0.12;

        p('<svg viewBox="0 0 560 230" class="chart-svg" role="img" aria-label="CPU busy percent chart for '
          || esc(db_label(NULL, cd.con_dbid)) || '">');
        emit_y_axis(v_ymin, v_ymax, '%');
        emit_x_axis(v_xmin, v_xmax);
        chart_axes_frame;
        p('<line class="thresh-line" x1="' || fmt_px(c_ml) || '" y1="' || fmt_px(scale_y(cpu_sat, v_ymin, v_ymax))
          || '" x2="' || fmt_px(c_cw - c_mr) || '" y2="' || fmt_px(scale_y(cpu_sat, v_ymin, v_ymax)) || '"/>');
        p('<text class="thresh-label" x="' || fmt_px(c_cw - c_mr - 2) || '" y="'
          || fmt_px(scale_y(cpu_sat, v_ymin, v_ymax) - 3) || '" text-anchor="end">sat '
          || TO_CHAR(cpu_sat, 'FM990') || '%</text>');
        emit_polyline(xs, ys, v_cnt, v_xmin, v_xmax, v_ymin, v_ymax, 'hist-line');
        IF v_proj_y IS NOT NULL THEN
          px1(1) := v_last_day_n;      py1(1) := ys(v_cnt);
          px1(2) := v_last_day_n + 90; py1(2) := v_proj_y;
          emit_polyline(px1, py1, 2, v_xmin, v_xmax, v_ymin, v_ymax, 'proj-line');
        END IF;
        FOR a IN (SELECT day_dt, busy_pct FROM capa_cpu_anom
                  WHERE con_dbid = cd.con_dbid AND anomaly_flag IS NOT NULL) LOOP
          p('<circle class="anom-dot" cx="' || fmt_px(scale_x(a.day_dt - c_epoch, v_xmin, v_xmax))
            || '" cy="' || fmt_px(scale_y(a.busy_pct, v_ymin, v_ymax)) || '" r="3"/>');
        END LOOP;
        p('</svg>');
      END IF;
      p('</div>');

      -- ---- DB CPU sec/day card ----
      xs.DELETE; ys.DELETE; v_cnt := 0;
      FOR h IN (SELECT day_dt, db_cpu_sec FROM capd_dbtime_daily
                WHERE con_dbid = cd.con_dbid ORDER BY day_dt) LOOP
        v_cnt := v_cnt + 1;
        xs(v_cnt) := h.day_dt - c_epoch;
        ys(v_cnt) := h.db_cpu_sec;
      END LOOP;

      v_quality := NULL; v_slope := NULL;
      FOR t IN (SELECT slope_per_day, quality FROM capf_cpu_trend
                WHERE con_dbid = cd.con_dbid AND metric = 'DB_CPU_SEC'
                ORDER BY dbid FETCH FIRST 1 ROW ONLY) LOOP
        v_quality := t.quality;
        v_slope   := t.slope_per_day;
      END LOOP;

      chart_open('DB CPU sec/day (' || esc(db_label(NULL, cd.con_dbid)) || ')',
                  'REGR trend only -- no fixed saturation ceiling');
      IF v_cnt = 0 THEN
        p('<div class="empty-note">No daily DB CPU history collected yet for this container.</div>');
      ELSE
        v_xmin := xs(1); v_xmax := xs(v_cnt); v_last_day_n := xs(v_cnt); v_proj_y := NULL;
        IF v_quality = 'OK' AND v_slope IS NOT NULL THEN
          v_proj_y := ys(v_cnt) + v_slope * 90;
          v_xmax   := v_last_day_n + 90;
        END IF;
        v_ymin := 0; v_ymax := ys(1);
        FOR i IN 1 .. v_cnt LOOP
          IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF;
          IF ys(i) < v_ymin THEN v_ymin := ys(i); END IF;
        END LOOP;
        IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
        IF (v_ymax - v_ymin) < 1 THEN v_ymax := v_ymin + 1; END IF;
        v_ymax := v_ymax + (v_ymax - v_ymin) * 0.08;

        p('<svg viewBox="0 0 560 230" class="chart-svg" role="img" aria-label="DB CPU seconds per day chart for '
          || esc(db_label(NULL, cd.con_dbid)) || '">');
        emit_y_axis(v_ymin, v_ymax, ' s');
        emit_x_axis(v_xmin, v_xmax);
        chart_axes_frame;
        emit_polyline(xs, ys, v_cnt, v_xmin, v_xmax, v_ymin, v_ymax, 'hist-line');
        IF v_proj_y IS NOT NULL THEN
          px1(1) := v_last_day_n;      py1(1) := ys(v_cnt);
          px1(2) := v_last_day_n + 90; py1(2) := v_proj_y;
          emit_polyline(px1, py1, 2, v_xmin, v_xmax, v_ymin, v_ymax, 'proj-line');
        END IF;
        p('</svg>');
      END IF;
      p('</div>');
    END LOOP;
    p('</div>');
  END IF;

  any_rows := FALSE;
  FOR r IN (
    SELECT dbid,
           con_dbid,
           metric,
           train_n        AS n,
           cur_val,
           slope_per_day  AS slope_day,
           r2,
           days_to_sat    AS days_sat,
           days_to_sat_lo,
           days_to_sat_hi,
           quality
    FROM   capf_cpu_trend
    ORDER  BY con_dbid, metric
  ) LOOP
    IF NOT any_rows THEN
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>METRIC</th><th class="num">TRAIN_N</th><th>FILL</th><th class="num">CURRENT</th>'
        || '<th class="num">SLOPE/DAY' || info_icon('how much this metric moves per day on average')
        || '</th><th class="num">R2</th>'
        || '<th class="num">DAYS_SAT' || info_icon('estimated days until host CPU reaches the saturation threshold')
        || '</th><th class="num">RANGE' || info_icon('worst-to-best case days-to-saturation from the statistical uncertainty of the trend; never = it may not saturate at the slow end')
        || '</th><th>QUALITY</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td><td>' || esc(r.metric) || '</td>'
      || '<td class="num">' || nz(r.n, 'FM9990') || '</td>'
      || '<td>' || CASE WHEN r.metric = 'BUSY_PCT' THEN bar(r.cur_val,
                     CASE WHEN r.cur_val >= cpu_sat THEN 'crit'
                          WHEN r.cur_val >= cpu_sat * 0.75 THEN 'warn' ELSE '' END)
                   ELSE '&ndash;' END || '</td>'
      || '<td class="num">' || nz(r.cur_val, 'FM99999990.00') || '</td>'
      || '<td class="num">' || nz(r.slope_day, 'FM9999990.0000') || '</td>'
      || '<td class="num">' || nz(r.r2, 'FM90.000') || '</td>'
      || '<td class="num' || (CASE WHEN r.days_sat IS NOT NULL AND r.days_sat <= dtf_warn THEN ' sev-warn' END)
         || '">' || nz(r.days_sat, 'FM99999990') || '</td>'
      || '<td class="num">'
      || CASE WHEN r.days_to_sat_lo IS NULL THEN '&ndash;'
              ELSE TO_CHAR(r.days_to_sat_lo, 'FM99999990') || '&ndash;'
                   || NVL(TO_CHAR(r.days_to_sat_hi, 'FM99999990'), 'never') END || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
  ELSE
    p('<div class="empty-note">No CPU trend rows found.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 5: CPU anomalies
  ----------------------------------------------------------------------
  p('<section id="s5">');
  p('<h2>5. CPU busy% anomalies <span style="font-weight:400;color:var(--muted);font-size:12px">'
      || 'vs same-weekday baseline, last ' || anomaly_days || ' days</span></h2>');
  p('<p class="desc">Days when the CPU was unusually busy compared with the same weekday before. '
      || 'FLAG when |busy% - median%| exceeds THRESHOLD (k*MAD, floored).</p>');

  any_rows := FALSE;
  FOR r IN (
    SELECT dbid,
           con_dbid,
           TO_CHAR(day_dt,'YYYY-MM-DD') AS day_dt,
           busy_pct,
           median_pct,
           threshold_pct,
           robust_z AS z,
           anomaly_flag
    FROM   capa_cpu_anom
    WHERE  anomaly_flag IS NOT NULL
      AND  day_dt > (SELECT MAX(day_dt) FROM capd_cpu_daily) - anomaly_days
    ORDER  BY day_dt DESC, con_dbid
  ) LOOP
    IF NOT any_rows THEN
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>DAY</th><th class="num">BUSY%</th>'
        || '<th class="num">MEDIAN%' || info_icon('the usual busy percent for that same weekday')
        || '</th><th class="num">THRESH%' || info_icon('how far from usual a day must be before it is flagged')
        || '</th><th class="num">ROBUST_Z' || info_icon('how far outside its normal range this day was -- 3 or more is clearly unusual')
        || '</th><th>FLAG</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td><td>' || r.day_dt || '</td>'
      || '<td class="num">' || nz(r.busy_pct, 'FM9990.00') || '</td>'
      || '<td class="num">' || nz(r.median_pct, 'FM9990.00') || '</td>'
      || '<td class="num">' || nz(r.threshold_pct, 'FM9990.00') || '</td>'
      || '<td class="num' || (CASE WHEN ABS(NVL(r.z,0)) >= 3 THEN ' z-hi' ELSE '' END) || '">'
         || nz(r.z, 'FM99990.0') || '</td>'
      || '<td class="sev-crit">' || esc(r.anomaly_flag) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
  ELSE
    p('<div class="empty-note">No anomalies flagged in the selected window.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 6: ESM vs REGR compare (dispatch identical to report.sql /
  -- 06_esm_compare.sql / 06_esm_skip.sql)
  ----------------------------------------------------------------------
  p('<section id="s6">');
  p('<h2>6. Tier 2 (ESM) vs Tier 1 (REGR) '
      || info_icon('Tier 1 fits a straight line through recent history; Tier 2 is an Oracle ML model that also learns weekly patterns -- trust Tier 2 for the next 30 days when both exist, Tier 1 for further out')
      || '</h2>');

  IF NOT do_esm THEN
    p('<p class="desc">A second-opinion short-term forecast from a machine-learning model, shown when one has been trained. '
        || 'Skipped: either show_esm=N, or show_esm=AUTO with no ESM models trained. '
        || 'Run <code>EXEC cap_forecast_ml.train_all</code> then re-run the report (or set '
        || 'show_esm=&#39;Y&#39; to force the (empty) table).</p>');
  ELSE
    p('<p class="desc">A second opinion on the short-term forecast from a machine-learning model. '
        || esm_ok || ' OML ESM model(s) trained (OK). If 0: run '
        || '<code>EXEC cap_forecast_ml.train_all</code>. ESM reaches +30 only (19c hard horizon '
        || 'cap) and only for fresh models; +90/180/365 are REGR-only.</p>');

    p('<h3 style="font-size:13px;margin:16px 0 6px">6a. Tablespaces (GB)</h3>');
    any_rows := FALSE;
    FOR r IN (
      SELECT dbid, con_dbid, series_key, horizon_days AS h,
             MAX(CASE WHEN engine='REGR' THEN value END)       / 1073741824 AS regr,
             MAX(CASE WHEN engine='ESM'  THEN value END)       / 1073741824 AS esm,
             MAX(CASE WHEN engine='ESM'  THEN lower_bound END) / 1073741824 AS esm_lo,
             MAX(CASE WHEN engine='ESM'  THEN upper_bound END) / 1073741824 AS esm_hi
      FROM   capf_compare
      WHERE  series_kind = 'TBSPC'
      GROUP  BY dbid, con_dbid, series_key, horizon_days
      ORDER  BY con_dbid, series_key, horizon_days
    ) LOOP
      IF NOT any_rows THEN
        p('<table class="tbl"><thead><tr>'
          || '<th>DB/PDB</th><th>TABLESPACE</th><th class="num">HORIZON</th><th class="num">REGR_GB</th>'
          || '<th class="num">ESM_GB</th><th class="num">ESM_LO</th><th class="num">ESM_HI</th></tr></thead><tbody>');
        any_rows := TRUE;
      END IF;
      p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td><td>' || esc(r.series_key) || '</td>'
        || '<td class="num">' || nz(r.h, 'FM9990') || '</td>'
        || '<td class="num">' || nz(r.regr) || '</td>'
        || '<td class="num">' || nz(r.esm) || '</td>'
        || '<td class="num">' || nz(r.esm_lo) || '</td>'
        || '<td class="num">' || nz(r.esm_hi) || '</td></tr>');
    END LOOP;
    IF any_rows THEN
      p('</tbody></table>');
    ELSE
      p('<div class="empty-note">No tablespace ESM/REGR comparison rows found.</div>');
    END IF;

    p('<h3 style="font-size:13px;margin:16px 0 6px">6b. CPU (busy% / DB CPU sec)</h3>');
    any_rows := FALSE;
    FOR r IN (
      SELECT dbid, con_dbid, series_key, horizon_days AS h,
             MAX(CASE WHEN engine='REGR' THEN value END)       AS regr,
             MAX(CASE WHEN engine='ESM'  THEN value END)       AS esm,
             MAX(CASE WHEN engine='ESM'  THEN lower_bound END) AS esm_lo,
             MAX(CASE WHEN engine='ESM'  THEN upper_bound END) AS esm_hi
      FROM   capf_compare
      WHERE  series_kind = 'CPU'
      GROUP  BY dbid, con_dbid, series_key, horizon_days
      ORDER  BY con_dbid, series_key, horizon_days
    ) LOOP
      IF NOT any_rows THEN
        p('<table class="tbl"><thead><tr>'
          || '<th>DB/PDB</th><th>METRIC</th><th class="num">HORIZON</th><th class="num">REGR</th>'
          || '<th class="num">ESM</th><th class="num">ESM_LO</th><th class="num">ESM_HI</th></tr></thead><tbody>');
        any_rows := TRUE;
      END IF;
      p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td><td>' || esc(r.series_key) || '</td>'
        || '<td class="num">' || nz(r.h, 'FM9990') || '</td>'
        || '<td class="num">' || nz(r.regr, 'FM99999990.00') || '</td>'
        || '<td class="num">' || nz(r.esm, 'FM99999990.00') || '</td>'
        || '<td class="num">' || nz(r.esm_lo, 'FM99999990.00') || '</td>'
        || '<td class="num">' || nz(r.esm_hi, 'FM99999990.00') || '</td></tr>');
    END LOOP;
    IF any_rows THEN
      p('</tbody></table>');
    ELSE
      p('<div class="empty-note">No CPU ESM/REGR comparison rows found.</div>');
    END IF;

    ------------------------------------------------------------------
    -- 6c. Backtest (M9.4): which engine was right over the held-out
    -- window. Mirrors report/sections/06_esm_compare.sql exactly.
    ------------------------------------------------------------------
    p('<h3 style="font-size:13px;margin:16px 0 6px">6c. Backtest &mdash; which engine was right '
      || info_icon('each engine forecast the recent held-out window from data before it; MAPE is the average percent miss vs what actually happened, BIAS above zero means it over-forecast. ESM column fills after EXEC cap_forecast_ml.train_backtest')
      || '</h3>');
    any_rows := FALSE;
    FOR r IN (
      SELECT f.dbid, f.con_dbid, f.series_kind, f.series_key,
             TO_CHAR(MIN(f.cutoff_day), 'YYYY-MM-DD')             AS cutoff_day,
             MAX(CASE WHEN f.engine = 'REGR' THEN f.mape_pct END) AS regr_mape,
             MAX(CASE WHEN f.engine = 'REGR' THEN f.bias_pct END) AS regr_bias,
             MAX(CASE WHEN f.engine = 'ESM'  THEN f.mape_pct END) AS esm_mape,
             MAX(CASE WHEN f.engine = 'ESM'  THEN f.bias_pct END) AS esm_bias
      FROM   capf_backtest f
      GROUP  BY f.dbid, f.con_dbid, f.series_kind, f.series_key
      ORDER  BY f.con_dbid, f.series_kind, f.series_key
    ) LOOP
      IF NOT any_rows THEN
        p('<table class="tbl"><thead><tr>'
          || '<th>DB/PDB</th><th>KIND</th><th>SERIES</th><th>CUTOFF</th>'
          || '<th class="num">REGR_MAPE%</th><th class="num">REGR_BIAS%</th>'
          || '<th class="num">ESM_MAPE%</th><th class="num">ESM_BIAS%</th>'
          || '<th>BETTER</th></tr></thead><tbody>');
        any_rows := TRUE;
      END IF;
      p('<tr><td>' || esc(db_label(r.dbid, r.con_dbid)) || '</td>'
        || '<td>' || esc(r.series_kind) || '</td><td>' || esc(r.series_key) || '</td>'
        || '<td>' || r.cutoff_day || '</td>'
        || '<td class="num">' || nz(r.regr_mape, 'FM99990.00') || '</td>'
        || '<td class="num">' || nz(r.regr_bias, 'FMS99990.00') || '</td>'
        || '<td class="num">' || nz(r.esm_mape, 'FM99990.00') || '</td>'
        || '<td class="num">' || nz(r.esm_bias, 'FMS99990.00') || '</td>'
        || '<td>' || CASE WHEN r.regr_mape IS NULL OR r.esm_mape IS NULL THEN '&ndash;'
                          WHEN r.esm_mape < r.regr_mape THEN '<span class="pill pill-ok">ESM</span>'
                          ELSE '<span class="pill pill-ok">REGR</span>' END || '</td></tr>');
    END LOOP;
    IF any_rows THEN
      p('</tbody></table>');
    ELSE
      p('<div class="empty-note">No backtest rows yet (needs enough history before the holdout window; '
        || 'ESM rows appear after <code>EXEC cap_forecast_ml.train_backtest</code>).</div>');
    END IF;
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Footer + close document
  ----------------------------------------------------------------------
  p('<footer>End of report -- read-only run, no database objects created or modified. '
      || 'Written to reports/' || cap_file || '</footer>');
  p('</div>');
  p('</body></html>');
END;
/

SPOOL OFF

SET DEFINE '&'
SET TERMOUT ON
PROMPT
PROMPT Report written to: &cap_path
PROMPT
