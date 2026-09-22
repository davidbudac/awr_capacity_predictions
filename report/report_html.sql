--
-- report/report_html.sql -- read-only, self-contained HTML capacity report.
-- =====================================================================
-- Spools a single-file HTML dashboard from the CAPF_/CAPA_ views to
-- reports/cap_report_<db>_<ts>.html. READ-ONLY: only SELECTs (the CAPF_ESM
-- views call a pipelined function, which writes nothing). Creates/modifies no
-- database object. This is a SIBLING of report/report.sql (the plain-text
-- report): since M8.2 BOTH drivers read the same CAPR_* per-section views
-- (ddl/45_report_views.sql + ddl/55_report_views_ml.sql) and only FORMAT --
-- the analytics SQL is no longer duplicated here, so text and HTML cannot
-- drift. Only chart geometry (raw CAPD_* history points, the whole-database
-- cur_hero regression) is still computed in this file.
--
-- Run from the REPO ROOT so the @@report/defaults.sql include resolves
-- (SQL*Plus @@ is relative to the outermost caller's directory on 19c):
--   sqlplus user/pw@svc
--   SQL> @report/report_html.sql              -- defaults from report/defaults.sql
--   SQL> @report/report_html.sql 25 60 Y      -- top_n / anomaly_days / show_esm
-- Arguments are positional and optional (M7.6); each one omitted falls back to
-- report/defaults.sql. show_esm is AUTO | Y | N.
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
-- var. To change them for every run, edit report/defaults.sql (single source of
-- truth, shared with the text report); to change one run, pass them
-- positionally (M7.6):
--   @report/report_html.sql [top_n] [anomaly_days] [show_esm]
@@report/defaults.sql

-- M7.6: make &1..&3 safe to reference whether or not they were passed. A
-- COLUMN ... NEW_VALUE whose query returns NO rows defines the variable as
-- empty instead of leaving it undefined (an undefined &1 would PROMPT, and a
-- non-interactive caller's next heredoc line would be eaten as the answer);
-- an argument that WAS passed keeps its value -- SQL*Plus only reassigns
-- NEW_VALUE on a fetched row. TERMOUT is already OFF for this whole script.
COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3" FROM dual WHERE 1 = 0;

-- Effective knobs = positional argument, else the defaults.sql value. An
-- omitted argument is the empty string, and '' IS NULL in Oracle, so NVL
-- picks the default. Re-DEFINEs the same three names bound below.
COLUMN eff_top_n NEW_VALUE top_n        NOPRINT
COLUMN eff_anom  NEW_VALUE anomaly_days NOPRINT
COLUMN eff_esm   NEW_VALUE show_esm     NOPRINT
SELECT NVL('&1', '&top_n')                  AS eff_top_n,
       NVL('&2', '&anomaly_days')           AS eff_anom,
       NVL(UPPER('&3'), UPPER('&show_esm')) AS eff_esm
FROM   dual;

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
COLUMN min_gb         NEW_VALUE min_gb         NOPRINT

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
       (SELECT cfg_value FROM cap_config WHERE cfg_name='r2_gate')        AS r2_gate,
       (SELECT cfg_value FROM cap_config WHERE cfg_name='report_min_gb')  AS min_gb
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
VARIABLE b_min_gb         NUMBER
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
  :b_min_gb         := &min_gb;
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
  min_gb         NUMBER := :b_min_gb;          -- M7.4 section 2/6a size bound (GiB)

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
  v_ts_all     PLS_INTEGER;   -- M7.4: total tablespaces, for the section 2/6a bound headings
  v_ts_shown   PLS_INTEGER;   -- M7.4: how many of them sections 2/6a actually print
                              -- (v_total_ts is reused as a scratch counter later on)
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
  v_hlimit_gb   NUMBER;            -- total allocated limit (GiB), NULL if not meaningful
  v_rate_gb_mo  NUMBER;           -- signed slope in GiB/month
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

  -- "Forecast coverage" line (section 0): a NEUTRAL rollup of the tablespace
  -- QUALITY distribution, independent of the "Capacity" verdict above it, plus
  -- one plain-English clause per host-CPU (BUSY_PCT) series. v_n_flat/v_n_low/
  -- v_n_insuf are computed once (below) and reused by the later "Not shown as
  -- predictions" sentence, so the counts can never drift apart.
  v_cov_total  PLS_INTEGER;
  v_cov_ok     PLS_INTEGER;
  v_cpu_txt    VARCHAR2(2000);

  ----------------------------------------------------------------------
  -- Section 1's days-to-full table split: rows are captured once into this
  -- collection while rendering the primary table, then the collapsed
  -- diagnostics table (fill low/high, accel) walks the SAME collection -- one
  -- query, two renderings, so the two tables can never show a different row
  -- set or order.
  ----------------------------------------------------------------------
  TYPE dtf_diag_rec IS RECORD (
    db_pdb          VARCHAR2(300),
    tablespace_name VARCHAR2(128),
    dtf_lo          NUMBER,
    dtf_hi          NUMBER,
    accel           NUMBER
  );
  TYPE dtf_diag_tab IS TABLE OF dtf_diag_rec INDEX BY PLS_INTEGER;
  v_dtf_diag   dtf_diag_tab;
  v_dtf_diag_n PLS_INTEGER;

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
  -- Redesign scratch (R1): shared chart grammar inputs. chart_svg() reads
  -- these outer-block collections directly (xs/ys history, xs2/ys2 a faint
  -- secondary line, px1/py1 the 2-point projection, bx/blo/bhi the
  -- prediction-band knots, ax/ay anomaly markers) so every chart in the
  -- document is drawn by one procedure and cannot drift in style.
  ----------------------------------------------------------------------
  xs2 num_tab;  ys2 num_tab;
  bx  num_tab;  blo num_tab;  bhi num_tab;
  ax  num_tab;  ay  num_tab;
  v_cnt2      PLS_INTEGER := 0;
  v_nband     PLS_INTEGER := 0;
  v_nanom     PLS_INTEGER := 0;
  v_has_proj  BOOLEAN := FALSE;
  v_hist_days NUMBER;
  v_n_crit    PLS_INTEGER := 0;
  v_n_warn    PLS_INTEGER := 0;
  v_n_info    PLS_INTEGER := 0;
  v_n_cap     PLS_INTEGER := 0;
  v_n_beh     PLS_INTEGER := 0;
  v_first_crit VARCHAR2(300);
  v_p95_cur   NUMBER;
  v_p95_dts   NUMBER;
  v_p95_q     VARCHAR2(30);
  v_bt_rows   PLS_INTEGER := 0;
  v_kind_lbl  VARCHAR2(60);
  v_main      VARCHAR2(1000);
  v_sub       VARCHAR2(1000);
  v_big       VARCHAR2(120);
  v_small     VARCHAR2(120);
  v_stripe    VARCHAR2(10);
  v_cross_x   NUMBER;
  v_cross_lbl VARCHAR2(80);
  v_shift_from NUMBER;
  v_shift_to   NUMBER;
  v_shift_lbl  VARCHAR2(120);
  v_big_cls   VARCHAR2(10);
  v_big_lbl   VARCHAR2(120);
  v_dtf       NUMBER;
  v_pct       NUMBER;
  v_quiet     PLS_INTEGER := 0;
  v_chips     PLS_INTEGER := 0;
  v_last_day  DATE;
  v_tmp       VARCHAR2(32000);
  v_n         NUMBER;
  v_horizon   NUMBER;
  v_half      NUMBER;
  v_gap_pct   NUMBER;
  v_win_lo    DATE;
  v_win_hi    DATE;
  v_strip_n   PLS_INTEGER;

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
  -- used_limit_cell: the combined "Used / limit" table cell -- CUR_GIB /
  -- LIMIT_GIB as one text line, the existing bar+pct widget below it -- so
  -- three separate columns collapse into one. Reuses nz()/bar() verbatim, so
  -- a NULL cur/limit or pct still renders exactly as those functions already
  -- handle it.
  ----------------------------------------------------------------------
  FUNCTION used_limit_cell(cur_gb IN NUMBER, limit_gb IN NUMBER, pctval IN NUMBER,
                           cls IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
  BEGIN
    RETURN '<div class="used-limit"><div class="ul-text">' || nz(cur_gb) || ' / '
           || nz(limit_gb) || ' GiB</div>' || bar(pctval, cls) || '</div>';
  END used_limit_cell;

  ----------------------------------------------------------------------
  -- dtf_cell: a days-to-X style measure that came back NULL gets a short
  -- muted reason instead of a bare dash, derived only from the QUALITY
  -- column already on the same row -- never a new number. FLAT and a NULL
  -- result under OK/LOW_CONFIDENCE both mean "not heading toward the
  -- ceiling" (slope <= 0), so both read as "no crossing".
  ----------------------------------------------------------------------
  FUNCTION dtf_cell(d IN NUMBER, q IN VARCHAR2, fmt IN VARCHAR2 DEFAULT 'FM99999990',
                    cap_year IN BOOLEAN DEFAULT FALSE) RETURN VARCHAR2 IS
  BEGIN
    IF d IS NOT NULL AND cap_year AND d > 365 THEN RETURN '<span class="na">&gt; 1 year</span>'; END IF;
    IF d IS NOT NULL THEN RETURN TO_CHAR(d, fmt); END IF;
    IF q = 'INSUFFICIENT_HISTORY' THEN RETURN '<span class="na">insufficient history</span>'; END IF;
    IF q IN ('FLAT','OK','LOW_CONFIDENCE') THEN RETURN '<span class="na">no crossing</span>'; END IF;
    RETURN '<span class="na">n/a</span>';
  END dtf_cell;

  ----------------------------------------------------------------------
  -- dtf_row_id: a stable per-tablespace anchor for the section 1 days-to-full
  -- table row, so the "View evidence" links in the attention banner can jump
  -- straight to it. con_dbid-prefixed so two containers with the same
  -- tablespace name never collide.
  ----------------------------------------------------------------------
  FUNCTION dtf_row_id(p_con_dbid IN NUMBER, p_tbspc IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'dtf-' || TO_CHAR(p_con_dbid) || '_' || REGEXP_REPLACE(p_tbspc, '[^A-Za-z0-9_-]', '_');
  END dtf_row_id;

  ----------------------------------------------------------------------
  -- nf_row_id: sibling of dtf_row_id for the section 1 "Near-full now" table,
  -- which is deliberately quality-INDEPENDENT (M7.1) and so can carry a
  -- tablespace that never appears in the days-to-full table above it (e.g.
  -- FLAT or INSUFFICIENT_HISTORY quality). TBSPC_NEARFULL alerts must
  -- therefore anchor here, not at dtf_row_id. Same sanitising as dtf_row_id.
  ----------------------------------------------------------------------
  FUNCTION nf_row_id(p_con_dbid IN NUMBER, p_tbspc IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'nf-' || TO_CHAR(p_con_dbid) || '_' || REGEXP_REPLACE(p_tbspc, '[^A-Za-z0-9_-]', '_');
  END nf_row_id;

  ----------------------------------------------------------------------
  -- evidence_link: the trailing "View evidence" anchor on each
  -- attention-banner <li>. Per-tablespace kinds prefer the row anchor above
  -- (dtf_row_id / nf_row_id); the whole-database hero has its own per-con_dbid
  -- id (dbhero-<con_dbid>, set on the hero card below); everything else
  -- points at the section that holds the proof. p_kind values here are the
  -- ones this report's own attention banner raises -- 'TBSPC_FULL' and
  -- 'TBSPC_NEARFULL' match CAPR_ALERTS.kind literally; 'DB_FULL' and
  -- 'CPU_SAT' are this file's own labels for items it computes inline
  -- (cur_hero / CAPR_CPU_TREND) rather than reading from CAPR_ALERTS.
  ----------------------------------------------------------------------
  FUNCTION evidence_link(p_kind IN VARCHAR2, p_con_dbid IN NUMBER, p_series IN VARCHAR2) RETURN VARCHAR2 IS
    v_href VARCHAR2(200);
  BEGIN
    v_href := CASE p_kind
                WHEN 'TBSPC_FULL'     THEN '#' || dtf_row_id(p_con_dbid, p_series)
                WHEN 'TBSPC_NEARFULL' THEN '#' || nf_row_id(p_con_dbid, p_series)
                WHEN 'DB_FULL'        THEN '#dbhero-' || TO_CHAR(p_con_dbid)
                WHEN 'CPU_SAT'        THEN '#s4'
                WHEN 'DBCPU_SAT'      THEN '#s4'
                WHEN 'CPU_SHIFT'      THEN '#s5'
                WHEN 'CPU_ANOM'       THEN '#s5'
                WHEN 'TBSPC_ANOM'     THEN '#s3'
                WHEN 'SERIES_LIMIT'      THEN '#s7'
                WHEN 'SERIES_NEARLIMIT'  THEN '#s7'
                ELSE '#s0'
              END;
    RETURN ' <a class="evidence" href="' || v_href || '">View evidence &rarr;</a>';
  END evidence_link;

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
  -- fmt_size_gb: format a GiB quantity for humans, promoting to TiB once it
  -- reaches 1024 GiB. One decimal for GiB, two for TiB. NULL -> "unknown".
  -- Callers pass ABS() when they want a magnitude (e.g. a shrink rate).
  ----------------------------------------------------------------------
  FUNCTION fmt_size_gb(gb IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF gb IS NULL THEN RETURN 'unknown'; END IF;
    IF ABS(gb) >= 1024 THEN
      RETURN TO_CHAR(gb / 1024, 'FM999999990.00') || ' TiB';
    END IF;
    RETURN TO_CHAR(gb, 'FM999999990.0') || ' GiB';
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
  -- value labels (e.g. GiB or %). unit is appended to the label as literal
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
    -- (e.g. a 0-1.5 GiB tablespace) would label every line "0" or "1".
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
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="hist-line" x1="1" y1="5" x2="19" y2="5"/></svg> history</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="proj-line" x1="1" y1="5" x2="19" y2="5"/></svg> projection (REGR)</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><rect class="band" x="1" y="1" width="18" height="8"/></svg> 95% band</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="limit-line" x1="1" y1="5" x2="19" y2="5"/></svg> ceiling</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="thresh-line" x1="1" y1="5" x2="19" y2="5"/></svg> saturation</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><circle class="anom-dot" cx="10" cy="5" r="3.5"/></svg> unusual day</span>');
    p('<span class="lg-item"><svg width="20" height="12" class="lg-ico"><line class="esm-line" x1="10" y1="1" x2="10" y2="11"/><path class="esm-dot" d="M10 2 l4 4 -4 4 -4 -4 Z"/></svg> ESM +30 &plusmn; 95%</span>');
    p('<span class="lg-item"><svg width="20" height="10" class="lg-ico"><line class="today-line" x1="10" y1="1" x2="10" y2="9"/></svg> today</span>');
    p('</div>');
  END chart_legend;

  ----------------------------------------------------------------------
  -- R1 chart grammar helpers. One geometry (560 x p_h, plot box pl..pr /
  -- pt..pb), one tick rule, one axis style, one procedure (chart_svg) that
  -- draws every layer in a fixed order: shift window, grid, months, frame,
  -- area under history, prediction band, ceiling / saturation lines,
  -- secondary line, history, projection, today divider, anomaly rings,
  -- ESM point, crossing marker.
  ----------------------------------------------------------------------
  FUNCTION dfmt(d IN DATE) RETURN VARCHAR2 IS
  BEGIN
    IF d IS NULL THEN RETURN NULL; END IF;
    IF ABS(d - SYSDATE) > 300 THEN RETURN TO_CHAR(d, 'FMDD Mon YYYY'); END IF;
    RETURN TO_CHAR(d, 'FMDD Mon');
  END dfmt;

  -- growth rate from MiB/day: MiB below 1 GiB/day, GiB above
  FUNCTION fmt_rate_mb(mb IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF mb IS NULL THEN RETURN 'unknown'; END IF;
    IF ABS(mb) >= 1024 THEN RETURN TO_CHAR(mb / 1024, 'FM999990.0') || ' GiB/day'; END IF;
    RETURN TO_CHAR(ROUND(mb), 'FM999990') || ' MiB/day';
  END fmt_rate_mb;

  -- container label for chips and strips: the PDB part alone when the
  -- report spans containers, dimmed, so the series name stays readable
  FUNCTION con_prefix(p_db_pdb IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF v_con_count <= 1 THEN RETURN NULL; END IF;
    RETURN '<span class="dim">' || esc(CASE WHEN INSTR(p_db_pdb, '/') > 0 THEN SUBSTR(p_db_pdb, INSTR(p_db_pdb, '/') + 1) ELSE p_db_pdb END) || '/</span>';
  END con_prefix;

  -- days -> a short duration for the big figures: "17 d", "3 mo", "1.8 y"
  FUNCTION short_dur(d IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF d IS NULL THEN RETURN NULL; END IF;
    IF d < 1 THEN RETURN '&lt;1 d'; END IF;
    IF d < 120 THEN RETURN TO_CHAR(ROUND(d), 'FM999990') || ' d'; END IF;
    IF d < 365 THEN RETURN TO_CHAR(ROUND(d / 30), 'FM990') || ' mo'; END IF;
    RETURN RTRIM(RTRIM(TO_CHAR(ROUND(d / 365, 1), 'FM9990.0'), '0'), '.') || ' y';
  END short_dur;

  -- 1 / 2 / 5 x 10^k tick step for a range, aiming at about `target` ticks.
  FUNCTION nice_step(rng IN NUMBER, target IN PLS_INTEGER DEFAULT 4) RETURN NUMBER IS
    raw NUMBER; mag NUMBER; f NUMBER;
  BEGIN
    IF rng IS NULL OR rng <= 0 THEN RETURN 1; END IF;
    raw := rng / target;
    mag := POWER(10, FLOOR(LOG(10, raw)));
    f   := raw / mag;
    IF f < 1.5 THEN RETURN mag;
    ELSIF f < 3 THEN RETURN 2 * mag;
    ELSIF f < 7 THEN RETURN 5 * mag;
    ELSE RETURN 10 * mag; END IF;
  END nice_step;

  PROCEDURE emit_grid(ymin IN NUMBER, ymax IN NUMBER, unit IN VARCHAR2,
                      pl IN NUMBER, pr IN NUMBER, pt IN NUMBER, pb IN NUMBER) IS
    step NUMBER := nice_step(ymax - ymin);
    v0   NUMBER;
    val  NUMBER;
    ypx  NUMBER;
    fmt  VARCHAR2(20);
    i    PLS_INTEGER := 0;
  BEGIN
    IF ymax <= ymin THEN RETURN; END IF;
    fmt := CASE WHEN step < 0.1 THEN 'FM999999990.00'
                WHEN step < 1   THEN 'FM999999990.0'
                WHEN step - TRUNC(step) <> 0 THEN 'FM999999990.0'
                ELSE 'FM999999990' END;
    v0 := CEIL(ymin / step) * step;
    LOOP
      val := v0 + i * step;
      EXIT WHEN val > ymax + step * 0.001 OR i > 40;
      ypx := lin(val, ymin, ymax, pb, pt);
      p('<line class="grid-line" x1="' || fmt_px(pl) || '" y1="' || fmt_px(ypx)
        || '" x2="' || fmt_px(pr) || '" y2="' || fmt_px(ypx) || '"/>');
      p('<text class="axis-label" x="' || fmt_px(pl - 6) || '" y="' || fmt_px(ypx + 3.5)
        || '" text-anchor="end">' || TO_CHAR(val, fmt) || '</text>');
      i := i + 1;
    END LOOP;
    IF unit IS NOT NULL THEN
      p('<text class="axis-unit" x="' || fmt_px(pl + 4) || '" y="' || fmt_px(pt - 6) || '">' || unit || '</text>');
    END IF;
  END emit_grid;

  -- Month labels along the x axis (every 1 / 2 / 3 months by span); the
  -- first label and every January carry the year. Very short spans fall
  -- back to start / end dates.
  PROCEDURE emit_months(xmin IN NUMBER, xmax IN NUMBER,
                        pl IN NUMBER, pr IN NUMBER, pb IN NUMBER, py IN NUMBER) IS
    d      DATE;
    dmax   DATE := c_epoch + xmax;
    every  PLS_INTEGER;
    nmon   NUMBER;
    i      PLS_INTEGER := 0;
    shown  PLS_INTEGER := 0;
    xpx    NUMBER;
    lbl    VARCHAR2(20);
  BEGIN
    IF xmax <= xmin THEN RETURN; END IF;
    d    := ADD_MONTHS(TRUNC(c_epoch + xmin, 'MM'), 1);
    IF TRUNC(c_epoch + xmin, 'MM') = c_epoch + xmin THEN d := c_epoch + xmin; END IF;
    nmon := MONTHS_BETWEEN(TRUNC(dmax, 'MM'), TRUNC(d, 'MM'));
    IF nmon < 1 THEN
      p('<text class="axis-label" x="' || fmt_px(pl) || '" y="' || fmt_px(py)
        || '" text-anchor="start">' || dfmt(c_epoch + xmin) || '</text>');
      p('<text class="axis-label" x="' || fmt_px(pr) || '" y="' || fmt_px(py)
        || '" text-anchor="end">' || dfmt(dmax) || '</text>');
      RETURN;
    END IF;
    every := CASE WHEN nmon > 30 THEN 6 WHEN nmon > 14 THEN 3 WHEN nmon > 8 THEN 2 ELSE 1 END;
    WHILE d <= dmax LOOP
      IF MOD(i, every) = 0 THEN
        xpx := lin(d - c_epoch, xmin, xmax, pl, pr);
        lbl := TO_CHAR(d, 'Mon')
               || CASE WHEN shown = 0 OR TO_CHAR(d, 'MM') = '01'
                       THEN ' ''' || TO_CHAR(d, 'YY') END;
        p('<line class="axis-tick" x1="' || fmt_px(xpx) || '" y1="' || fmt_px(pb)
          || '" x2="' || fmt_px(xpx) || '" y2="' || fmt_px(pb + 4) || '"/>');
        p('<text class="axis-label" x="' || fmt_px(xpx) || '" y="' || fmt_px(py)
          || '" text-anchor="middle">' || lbl || '</text>');
        shown := shown + 1;
      END IF;
      i := i + 1;
      d := ADD_MONTHS(d, 1);
    END LOOP;
  END emit_months;

  -- The one chart procedure. Reads xs/ys (history, v_cnt), xs2/ys2
  -- (secondary faint line, v_cnt2), px1/py1 (projection, v_has_proj),
  -- bx/blo/bhi (band knots, v_nband) and ax/ay (anomaly rings, v_nanom).
  PROCEDURE chart_svg(p_aria   IN VARCHAR2,
                      p_xmin   IN NUMBER, p_xmax IN NUMBER,
                      p_ymin   IN NUMBER, p_ymax IN NUMBER,
                      p_unit   IN VARCHAR2,
                      p_today  IN NUMBER,
                      p_ceil   IN NUMBER, p_ceil_lbl IN VARCHAR2,
                      p_sat    IN NUMBER, p_sat_lbl  IN VARCHAR2,
                      p_esm_x  IN NUMBER, p_esm_val IN NUMBER,
                      p_esm_lo IN NUMBER, p_esm_hi  IN NUMBER,
                      p_sh_from IN NUMBER, p_sh_to IN NUMBER, p_sh_lbl IN VARCHAR2,
                      p_cross_x IN NUMBER, p_cross_y IN NUMBER, p_cross_lbl IN VARCHAR2,
                      p_h      IN NUMBER DEFAULT 230) IS
    pl  CONSTANT NUMBER := 48;
    pr  CONSTANT NUMBER := 548;
    pt  CONSTANT NUMBER := 22;
    pb  NUMBER := p_h - 26;
    buf VARCHAR2(4000);
    ypx NUMBER;
    xpx NUMBER;
    x0  NUMBER;
    x1  NUMBER;
    FUNCTION sx(v IN NUMBER) RETURN NUMBER IS BEGIN RETURN lin(v, p_xmin, p_xmax, pl, pr); END;
    FUNCTION sy(v IN NUMBER) RETURN NUMBER IS BEGIN RETURN lin(v, p_ymin, p_ymax, pb, pt); END;
  BEGIN
    p('<svg viewBox="0 0 560 ' || TO_CHAR(p_h, 'FM9990') || '" class="chart-svg" role="img" aria-label="'
      || p_aria || '">');
    -- shaded level-shift window (background layer)
    IF p_sh_from IS NOT NULL AND p_sh_to IS NOT NULL AND p_sh_to > p_sh_from THEN
      x0 := sx(GREATEST(p_sh_from, p_xmin)); x1 := sx(LEAST(p_sh_to, p_xmax));
      p('<rect class="shift" x="' || fmt_px(x0) || '" y="' || fmt_px(pt) || '" width="' || fmt_px(x1 - x0)
        || '" height="' || fmt_px(pb - pt) || '"/>');
      IF p_sh_lbl IS NOT NULL THEN
        IF x0 > (pl + pr) / 2 THEN
          p('<text class="shift-label" x="' || fmt_px(x0 - 4) || '" y="' || fmt_px(pt + 11) || '" text-anchor="end">' || p_sh_lbl || '</text>');
        ELSE
          p('<text class="shift-label" x="' || fmt_px(x1 + 4) || '" y="' || fmt_px(pt + 11) || '">' || p_sh_lbl || '</text>');
        END IF;
      END IF;
    END IF;
    emit_grid(p_ymin, p_ymax, p_unit, pl, pr, pt, pb);
    emit_months(p_xmin, p_xmax, pl, pr, pb, p_h - 7);
    p('<line class="axis-line" x1="' || fmt_px(pl) || '" y1="' || fmt_px(pb) || '" x2="' || fmt_px(pr) || '" y2="' || fmt_px(pb) || '"/>');
    p('<line class="axis-line" x1="' || fmt_px(pl) || '" y1="' || fmt_px(pt) || '" x2="' || fmt_px(pl) || '" y2="' || fmt_px(pb) || '"/>');
    -- area under history
    IF v_cnt >= 2 THEN
      p('<path class="area" d="M' || fmt_px(sx(xs(1))) || ' ' || fmt_px(pb));
      buf := NULL;
      FOR i IN 1 .. v_cnt LOOP
        buf := buf || ' L' || fmt_px(sx(xs(i))) || ' ' || fmt_px(sy(ys(i)));
        IF LENGTH(buf) > 2000 THEN p(buf); buf := NULL; END IF;
      END LOOP;
      p(buf || ' L' || fmt_px(sx(xs(v_cnt))) || ' ' || fmt_px(pb) || ' Z"/>');
    END IF;
    -- prediction band: from today's actual value out along the hi knots,
    -- back along the lo knots
    IF v_nband >= 1 AND v_cnt >= 1 THEN
      buf := 'M' || fmt_px(sx(xs(v_cnt))) || ' ' || fmt_px(sy(ys(v_cnt)));
      FOR i IN 1 .. v_nband LOOP
        buf := buf || ' L' || fmt_px(sx(bx(i))) || ' ' || fmt_px(sy(bhi(i)));
      END LOOP;
      FOR i IN REVERSE 1 .. v_nband LOOP
        buf := buf || ' L' || fmt_px(sx(bx(i))) || ' ' || fmt_px(sy(blo(i)));
      END LOOP;
      p('<path class="band" d="' || buf || ' Z"/>');
    END IF;
    -- ceiling / saturation lines with their value labels
    IF p_ceil IS NOT NULL THEN
      ypx := sy(p_ceil);
      p('<line class="limit-line" x1="' || fmt_px(pl) || '" y1="' || fmt_px(ypx) || '" x2="' || fmt_px(pr) || '" y2="' || fmt_px(ypx) || '"/>');
      IF p_ceil_lbl IS NOT NULL THEN
        p('<text class="limit-label" x="' || fmt_px(pl + 4) || '" y="' || fmt_px(ypx - 4) || '">' || p_ceil_lbl || '</text>');
      END IF;
    END IF;
    IF p_sat IS NOT NULL THEN
      ypx := sy(p_sat);
      p('<line class="thresh-line" x1="' || fmt_px(pl) || '" y1="' || fmt_px(ypx) || '" x2="' || fmt_px(pr) || '" y2="' || fmt_px(ypx) || '"/>');
      IF p_sat_lbl IS NOT NULL THEN
        p('<text class="thresh-label" x="' || fmt_px(pl + 4) || '" y="' || fmt_px(ypx - 4) || '">' || p_sat_lbl || '</text>');
      END IF;
    END IF;
    -- secondary (faint) line, then the main history line
    IF v_cnt2 >= 2 THEN
      emit_poly_box(xs2, ys2, v_cnt2, p_xmin, p_xmax, p_ymin, p_ymax, pl, pr, pt, pb, 'hist2-line');
    END IF;
    emit_poly_box(xs, ys, v_cnt, p_xmin, p_xmax, p_ymin, p_ymax, pl, pr, pt, pb, 'hist-line');
    IF v_has_proj THEN
      emit_poly_box(px1, py1, 2, p_xmin, p_xmax, p_ymin, p_ymax, pl, pr, pt, pb, 'proj-line');
    END IF;
    -- today divider
    IF p_today IS NOT NULL AND p_today < p_xmax THEN
      xpx := sx(p_today);
      p('<line class="today-line" x1="' || fmt_px(xpx) || '" y1="' || fmt_px(pt) || '" x2="' || fmt_px(xpx) || '" y2="' || fmt_px(pb) || '"/>');
      p('<text class="today-label" x="' || fmt_px(xpx + 4) || '" y="' || fmt_px(pb - 5) || '">TODAY</text>');
    END IF;
    -- anomaly rings
    FOR i IN 1 .. v_nanom LOOP
      p('<circle class="anom-dot" cx="' || fmt_px(sx(ax(i))) || '" cy="' || fmt_px(sy(ay(i))) || '" r="4"/>');
    END LOOP;
    -- ESM +30: whisker + diamond
    IF p_esm_val IS NOT NULL AND p_esm_x IS NOT NULL THEN
      xpx := sx(p_esm_x);
      IF p_esm_lo IS NOT NULL AND p_esm_hi IS NOT NULL THEN
        p('<line class="esm-line" x1="' || fmt_px(xpx) || '" y1="' || fmt_px(sy(GREATEST(p_esm_lo, p_ymin)))
          || '" x2="' || fmt_px(xpx) || '" y2="' || fmt_px(sy(LEAST(p_esm_hi, p_ymax))) || '"/>');
      END IF;
      ypx := sy(p_esm_val);
      p('<path class="esm-dot" d="M' || fmt_px(xpx) || ' ' || fmt_px(ypx - 5) || ' l5 5 -5 5 -5 -5 Z"/>');
    END IF;
    -- crossing marker (where the projection meets the ceiling / saturation)
    IF p_cross_x IS NOT NULL AND p_cross_y IS NOT NULL AND p_cross_x <= p_xmax AND p_cross_x >= p_xmin THEN
      xpx := sx(p_cross_x); ypx := sy(p_cross_y);
      p('<circle class="cross-dot" cx="' || fmt_px(xpx) || '" cy="' || fmt_px(ypx) || '" r="3.5"/>');
      IF p_cross_lbl IS NOT NULL THEN
        IF xpx > (pl + pr) * 0.6 THEN
          p('<text class="cross-label" x="' || fmt_px(xpx - 7) || '" y="' || fmt_px(ypx + 15) || '" text-anchor="end">' || p_cross_lbl || '</text>');
        ELSE
          p('<text class="cross-label" x="' || fmt_px(xpx + 7) || '" y="' || fmt_px(ypx + 15) || '">' || p_cross_lbl || '</text>');
        END IF;
      END IF;
    END IF;
    p('</svg>');
  END chart_svg;

  -- Card frame around a chart: title + pills, a muted subtitle, and the
  -- big figure at the right (days to full / to saturation / shift size).
  PROCEDURE card_open(p_title IN VARCHAR2, p_sub IN VARCHAR2,
                      p_big IN VARCHAR2, p_big_lbl IN VARCHAR2, p_big_cls IN VARCHAR2,
                      p_border IN VARCHAR2 DEFAULT NULL, p_id IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    p('<div class="chart-card' || CASE WHEN p_border IS NOT NULL THEN ' ' || p_border END || '"'
      || CASE WHEN p_id IS NOT NULL THEN ' id="' || p_id || '"' END || '>');
    p('<div class="ch"><div class="t">' || p_title
      || CASE WHEN p_sub IS NOT NULL THEN '<small>' || p_sub || '</small>' END || '</div>');
    IF p_big IS NOT NULL THEN
      p('<div class="big ' || NVL(p_big_cls, '') || '"><div class="v">' || p_big || '</div><div class="l">'
        || p_big_lbl || '</div></div>');
    END IF;
    p('</div>');
  END card_open;

  -- Sparkline for the quiet-series strip: history only, normalised.
  PROCEDURE spark_svg IS
    lo NUMBER; hi NUMBER; buf VARCHAR2(4000);
  BEGIN
    IF v_cnt = 0 THEN RETURN; END IF;
    lo := ys(1); hi := ys(1);
    FOR i IN 1 .. v_cnt LOOP
      IF ys(i) < lo THEN lo := ys(i); END IF;
      IF ys(i) > hi THEN hi := ys(i); END IF;
    END LOOP;
    IF hi - lo < 0.000001 THEN lo := lo - 1; hi := hi + 1; END IF;
    p('<svg viewBox="0 0 300 24" preserveAspectRatio="none" class="spark" aria-hidden="true">');
    p('<polyline class="hist-line" points="');
    buf := NULL;
    FOR i IN 1 .. v_cnt LOOP
      buf := buf || fmt_px(lin(xs(i), xs(1), xs(v_cnt), 2, 298)) || ',' || fmt_px(lin(ys(i), lo, hi, 21, 3)) || ' ';
      IF LENGTH(buf) > 2000 THEN p(buf); buf := NULL; END IF;
    END LOOP;
    IF buf IS NOT NULL THEN p(buf); END IF;
    p('"/></svg>');
  END spark_svg;

  -- Anomaly strip frame (sections 3 and 5): a baseline with weekly ticks
  -- across the alert window; the caller emits the day markers and closes.
  PROCEDURE strip_open(p_xmin IN NUMBER, p_xmax IN NUMBER) IS
    d DATE := c_epoch + p_xmax;
  BEGIN
    p('<svg viewBox="0 0 600 30" class="strip-svg" aria-hidden="true">');
    p('<line class="tl-baseline" x1="4" y1="15" x2="596" y2="15"/>');
    WHILE d > c_epoch + p_xmin LOOP
      p('<line class="tl-grid" x1="' || fmt_px(lin(d - c_epoch, p_xmin, p_xmax, 4, 596)) || '" y1="8" x2="'
        || fmt_px(lin(d - c_epoch, p_xmin, p_xmax, 4, 596)) || '" y2="22"/>');
      d := d - 7;
    END LOOP;
  END strip_open;

  -- Table-row severity tint class.
  FUNCTION row_cls(sev IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE sev WHEN 'CRIT' THEN ' class="r-crit"' WHEN 'WARN' THEN ' class="r-warn"' ELSE '' END;
  END row_cls;

  -- Attention-list row (section 0).
  PROCEDURE attn_row(p_sev IN VARCHAR2, p_kind IN VARCHAR2, p_main IN VARCHAR2,
                     p_sub IN VARCHAR2, p_big IN VARCHAR2, p_small IN VARCHAR2) IS
  BEGIN
    p('<div class="row ' || LOWER(p_sev) || '"><div class="stripe"></div><div class="kind">' || p_kind
      || '</div><div class="msg">' || p_main
      || CASE WHEN p_sub IS NOT NULL THEN '<span class="sub">' || p_sub || '</span>' END
      || '</div><div class="when">' || NVL(p_big, '') 
      || CASE WHEN p_small IS NOT NULL THEN '<small>' || p_small || '</small>' END
      || '</div></div>');
  END attn_row;

BEGIN
  do_esm := NOT (show_esm = 'N' OR (show_esm = 'AUTO' AND esm_ok = 0));

  ----------------------------------------------------------------------
  -- Document head + styles
  ----------------------------------------------------------------------
  p('<!doctype html>');
  p('<html lang="en"><head>');
  p('<meta charset="UTF-8">');
  p('<meta name="viewport" content="width=device-width,initial-scale=1">');
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
  p('.header-card h1{margin:0 0 4px;font-size:22px}');
  p('.header-card .sub{color:var(--muted);font-size:12.5px;margin-bottom:14px}');
  p('.kv-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px 24px}');
  p('.kv-grid .kv dt{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.04em}');
  p('.kv-grid .kv dd{margin:2px 0 0;font-size:13.5px;font-variant-numeric:tabular-nums}');
  p('.note{margin-top:14px;padding:10px 12px;border-radius:8px;background:var(--flat-bg);color:var(--muted); font-size:12.5px;border-left:3px solid var(--warn);}');
  p('section{scroll-margin-top:56px;margin:26px 0}');
  p('section h2{font-size:17px;margin:0 0 4px;display:flex;align-items:center;gap:8px}');
  p('section .desc{color:var(--muted);font-size:12.5px;margin:0 0 12px}');
  p('table{width:100%;border-collapse:collapse;font-size:13px;background:var(--panel)}');
  -- overflow:visible (not hidden) so an inline info-tooltip bubble can escape
  -- the table/cell box instead of being clipped; the rounded outer corners are
  -- restored on the corner cells below.
  p('table.tbl{border:1px solid var(--border);border-radius:8px;overflow:visible}');
  p('.tscroll{overflow-x:auto;-webkit-overflow-scrolling:touch;max-width:100%}');
  p('.tscroll>table{min-width:100%}');
  -- No text-transform:uppercase (column-name contract): headers may be
  -- sentence case now (e.g. section 1's primary table), and the raw
  -- ALL_CAPS labels elsewhere already carry their own case in the string
  -- literal, so dropping this is a no-op for them.
  p('thead th{text-align:left;background:var(--flat-bg);color:var(--muted);font-weight:600; font-size:12px;letter-spacing:.03em;padding:8px 10px;border-bottom:1px solid var(--border);overflow:visible}');
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
  p('.bar-pct{font-size:12px;color:var(--muted);width:38px;text-align:right;font-variant-numeric:tabular-nums}');
  p('.z-hi{color:var(--crit);font-weight:700}');
  -- Explicit-blank cells: a NULL measure prints a short reason instead of a
  -- bare dash, muted so it reads as "nothing to see" rather than a real value.
  p('.na{color:var(--muted);font-style:italic}');
  p('.empty-note{color:var(--muted);font-style:italic;padding:12px;background:var(--flat-bg);border-radius:8px;font-size:12.5px}');
  -- A linked-to table row (the glance-banner "View evidence" anchors) gets a
  -- visible highlight so the reader can find it after the jump.
  p('tr:target{outline:2px solid var(--warn)}');
  -- Combined "Used / limit" cell: the CUR/LIMIT text sits above the existing
  -- bar-cell widget, in one narrower column instead of three.
  p('.used-limit{display:flex;flex-direction:column;gap:3px;min-width:150px}');
  p('.used-limit .ul-text{font-size:12px;color:var(--text);font-variant-numeric:tabular-nums}');
  -- Diagnostics detail table (section 1): same collapsed-by-default look as
  -- .glossary.
  p('.diag{margin:10px 0 6px;border:1px solid var(--border);border-radius:10px;background:var(--panel);font-size:12.5px}');
  p('.diag>summary{cursor:pointer;padding:10px 14px;font-weight:600;color:var(--text);list-style:none}');
  p('.diag>summary::-webkit-details-marker{display:none}');
  p('.diag>summary::before{content:"+ ";color:var(--muted);font-weight:700}');
  p('.diag[open]>summary::before{content:"- "}');
  p('.diag .diag-body{padding:0 14px 12px}');
  p('.diag table.tbl{margin:0}');
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
  -- display:none (not opacity/visibility) so the hidden bubble takes no layout
  -- space -- opacity:0;visibility:hidden still occupies its box past the right
  -- edge, which can produce a horizontal scrollbar at narrow viewports.
  p('.info .tip{position:absolute;left:50%;top:calc(100% + 7px);transform:translateX(-50%);width:max-content;max-width:260px;background:var(--panel);color:var(--text);border:1px solid var(--border);border-radius:8px;box-shadow:0 6px 18px rgba(0,0,0,.20);padding:7px 10px;font:400 12px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;text-transform:none;letter-spacing:normal;text-align:left;white-space:normal;display:none;pointer-events:none;z-index:60}');
  p('.info:hover .tip,.info:focus .tip,.info:focus-visible .tip{display:block}');
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
  -- Report details & methodology: same collapsed-by-default look as
  -- .glossary, holding everything that isn't Database/Host/Generated.
  p('.report-details{margin:14px 0 0;border:1px solid var(--border);border-radius:10px;background:var(--panel);font-size:12.5px}');
  p('.report-details>summary{cursor:pointer;padding:12px 16px;font-weight:600;color:var(--text);list-style:none}');
  p('.report-details>summary::-webkit-details-marker{display:none}');
  p('.report-details>summary::before{content:"+ ";color:var(--muted);font-weight:700}');
  p('.report-details[open]>summary::before{content:"- "}');
  p('.report-details .rd-body{padding:4px 16px 14px}');
  ------------------------------------------------------------------------
  -- Chart CSS. All stroke/fill colors reference the same page-level CSS
  -- variables used elsewhere (--accent/--ok/--crit/--warn/--muted/--border),
  -- so inline SVG inherits light/dark theming with no extra variables.
  ------------------------------------------------------------------------
  p('.chart-legend{display:flex;flex-wrap:wrap;gap:16px;font-size:11.5px;color:var(--muted);margin:10px 0 6px;align-items:center}');
  p('.chart-legend .lg-item{display:inline-flex;align-items:center;gap:5px}');
  p('.chart-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(420px,100%),1fr));gap:16px;margin:6px 0 20px}');
  p('.chart-card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:12px 14px 8px}');
  p('.chart-card h4{margin:0 0 2px;font-size:13px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}');
  p('.chart-sub{color:var(--muted);font-size:12px;margin:0 0 6px}');
  p('.chart-svg{width:100%;height:auto;display:block}');
  p('.axis-line{stroke:var(--border);stroke-width:1}');
  p('.grid-line{stroke:var(--border);stroke-width:1;stroke-dasharray:2 3;opacity:.6}');
  p('.axis-label{fill:var(--muted);font-size:11px}');
  p('.thresh-label{fill:var(--warn);font-size:11px}');
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
  -- The "Capacity" status line and the "Forecast coverage" line are visually
  -- independent -- a green all-clear must never be read as a statement about
  -- forecast reliability. .glance-cov is deliberately neutral (muted border,
  -- no ok/warn/crit tint).
  p('.glance-banner{margin:10px 0 8px}');
  p('.glance-line-label{font-size:11px;font-weight:700;letter-spacing:.04em;color:var(--muted);margin:12px 0 4px}');
  p('.glance-banner .glance-line-label:first-child{margin-top:0}');
  p('.glance-cov{background:var(--flat-bg);color:var(--muted);border:1px solid var(--border);border-radius:10px;padding:12px 16px;font-size:13px}');
  -- "View evidence" jump link appended to each attention-banner item.
  p('.evidence{margin-left:6px;font-size:12px;font-weight:600;color:var(--accent);text-decoration:none;white-space:nowrap}');
  p('.evidence:hover,.evidence:focus{text-decoration:underline}');
  p('.timeline-card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px 16px 10px;margin:6px 0 8px}');
  p('.timeline-svg{width:100%;height:auto;display:block}');
  p('.tl-baseline{stroke:var(--border);stroke-width:1}');
  p('.tl-grid{stroke:var(--border);stroke-width:1;stroke-dasharray:2 3;opacity:.5}');
  p('.tl-lane-label{fill:var(--muted);font-size:11px}');
  p('.tl-axis-label{fill:var(--muted);font-size:11px}');
  -- Hero duo: the whole-database hero and the host-CPU hero side by side on
  -- desktop, stacking when narrow. Each is a .gcard g-hero (reuses .gcard +
  -- .g-* accents and pills) holding a headline and a 560x250 chart.
  p('.hero-duo{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(430px,100%),1fr));gap:14px;margin:10px 0 8px}');
  p('.g-hero{gap:6px}');
  p('.g-hero .g-head{font-size:16px}');
  p('.g-hero .hero-svg{width:100%;height:auto;display:block;margin-top:8px}');
  ------------------------------------------------------------------------
  -- R1 redesign: extra tokens (band / area fills, a second panel tone, a
  -- fainter text tone) declared for every theme state, then the components
  -- the redesigned header, attention list, chart cards, quiet strip,
  -- anomaly strips and tables use. Later rules win over the base ones above.
  ------------------------------------------------------------------------
  p(':root{--panel2:#f8f9fb; --faint:#8a94a3; --band:rgba(43,95,173,.13); --area:rgba(43,95,173,.08); --accent-soft:rgba(43,95,173,.12); --accent-text:#2b5fad; --shift-bg:rgba(183,121,31,.16)}');
  p('@media (prefers-color-scheme: dark){ :root:not([data-theme="light"]){--panel2:#1f242c; --faint:#6f7987; --band:rgba(122,162,232,.16); --area:rgba(122,162,232,.10); --accent-soft:rgba(122,162,232,.16); --accent-text:#9dbcf2; --shift-bg:rgba(224,176,76,.18)}}');
  p(':root[data-theme="dark"]{--panel2:#1f242c; --faint:#6f7987; --band:rgba(122,162,232,.16); --area:rgba(122,162,232,.10); --accent-soft:rgba(122,162,232,.16); --accent-text:#9dbcf2; --shift-bg:rgba(224,176,76,.18)}');
  p(':root[data-theme="light"]{--panel2:#f8f9fb; --faint:#8a94a3; --band:rgba(43,95,173,.13); --area:rgba(43,95,173,.08); --accent-soft:rgba(43,95,173,.12); --accent-text:#2b5fad; --shift-bg:rgba(183,121,31,.16)}');
  -- header with the verdict strip
  p('.rep-head{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:16px 18px;margin:20px 0;display:grid;grid-template-columns:1fr auto;gap:12px 20px;align-items:start}');
  p('.rep-head h1{margin:0;font-size:20px}');
  p('.rep-head .id{color:var(--muted);font-size:12.5px;margin-top:2px}');
  p('.rep-head .id b{color:var(--text);font-weight:600}');
  p('.tools{display:flex;gap:6px;flex-wrap:wrap}');
  p('.tbtn{font:inherit;font-size:12px;padding:5px 10px;border:1px solid var(--border);border-radius:7px;color:var(--muted);background:var(--panel);cursor:pointer}');
  p('.tbtn:hover{color:var(--text);border-color:var(--accent)}');
  p('.kpis{grid-column:1/-1;display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-top:2px}');
  p('.kpi{border:1px solid var(--border);border-radius:9px;padding:9px 12px;background:var(--panel2)}');
  p('.kpi .l{font-size:10.5px;letter-spacing:.06em;text-transform:uppercase;color:var(--faint)}');
  p('.kpi .v{font-size:22px;font-weight:700;line-height:1.15;font-variant-numeric:tabular-nums;margin-top:2px}');
  p('.kpi .v small{font-size:13px;color:var(--muted);font-weight:400}');
  p('.kpi .s{font-size:11.5px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}');
  p('.kpi.crit .v{color:var(--crit)}.kpi.warn .v{color:var(--warn)}.kpi.ok .v{color:var(--ok)}');
  p('.rep-head details.fold{grid-column:1/-1;margin:0}');
  p('details.fold{border:1px solid var(--border);border-radius:10px;background:var(--panel);font-size:12.5px;margin:10px 0 6px}');
  p('details.fold>summary{cursor:pointer;padding:10px 14px;font-weight:600;color:var(--text);list-style:none}');
  p('details.fold>summary::-webkit-details-marker{display:none}');
  p('details.fold>summary::before{content:"+ ";color:var(--muted);font-weight:700}');
  p('details.fold[open]>summary::before{content:"- "}');
  p('details.fold .fold-body{padding:0 14px 12px}');
  p('details.fold .fold-body table.tbl{margin:0}');
  -- attention list (section 0)
  p('.attn{background:var(--panel);border:1px solid var(--border);border-radius:12px;overflow:hidden;margin:10px 0 8px}');
  p('.attn .row{display:grid;grid-template-columns:5px 96px 1fr auto;gap:0 12px;align-items:center;padding:10px 14px 10px 0;border-bottom:1px solid var(--border)}');
  p('.attn .row:last-child{border-bottom:none}');
  p('.attn .stripe{align-self:stretch;background:var(--border)}');
  p('.attn .crit .stripe{background:var(--crit)}.attn .warn .stripe{background:var(--warn)}');
  p('.attn .kind{font-size:10.5px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:var(--muted)}');
  p('.attn .msg{font-size:13.5px;min-width:0}');
  p('.attn .msg b{font-weight:600}');
  p('.attn .msg .sub{display:block;color:var(--muted);font-size:12px}');
  p('.attn .when{font-variant-numeric:tabular-nums;text-align:right;font-weight:700;font-size:15px;white-space:nowrap}');
  p('.attn .when small{display:block;font-weight:400;font-size:11px;color:var(--muted)}');
  p('.attn .crit .when{color:var(--crit)}.attn .warn .when{color:var(--warn)}');
  p('.healthy{margin:10px 0 6px;font-size:12.5px;color:var(--muted);line-height:1.8}');
  p('.healthy b{color:var(--text);font-weight:600;margin-right:4px}');
  p('.chip{display:inline-block;background:var(--flat-bg);border-radius:6px;padding:1px 7px;margin:0 3px 3px 0;font-variant-numeric:tabular-nums;color:var(--text)}');
  p('.chip.q{color:var(--muted)}');
  p('@media(max-width:640px){.attn .row{grid-template-columns:5px 1fr auto}.attn .kind{display:none}.rep-head{grid-template-columns:1fr}}');
  -- chart cards: header row with the big figure, severity border
  p('.chart-card.crit{border-color:var(--crit)}.chart-card.warn{border-color:var(--warn)}');
  p('.chart-card .ch{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;margin-bottom:4px}');
  p('.chart-card .ch .t{font-weight:700;font-size:14px;min-width:0;display:flex;flex-wrap:wrap;align-items:center;gap:6px}');
  p('.chart-card .ch .t small{flex-basis:100%;font-weight:400;color:var(--muted);font-size:12px}');
  p('.big{text-align:right;font-variant-numeric:tabular-nums;flex:0 0 auto}');
  p('.big .v{font-size:24px;font-weight:700;line-height:1}');
  p('.big .l{font-size:11px;color:var(--muted);margin-top:2px}');
  p('.big.crit .v{color:var(--crit)}.big.warn .v{color:var(--warn)}.big.ok .v{color:var(--ok)}.big.muted .v{color:var(--muted)}');
  p('.hero-duo .chart-card{padding:14px 16px 8px}');
  -- chart layers
  p('.axis-unit{fill:var(--muted);font-size:10.5px;letter-spacing:.04em}');
  p('.axis-tick{stroke:var(--border);stroke-width:1}');
  p('.area{fill:var(--area)}');
  p('.band{fill:var(--band)}');
  p('.hist2-line{fill:none;stroke:var(--accent);stroke-width:1.2;opacity:.35;stroke-linejoin:round}');
  p('.hist2-line-pt{fill:var(--accent);opacity:.35}');
  p('.today-line{stroke:var(--faint);stroke-width:1;stroke-dasharray:1 3}');
  p('.today-label{fill:var(--faint);font-size:9.5px;letter-spacing:.08em}');
  p('.limit-label{fill:var(--crit);font-size:11px;font-weight:600}');
  p('.thresh-label{fill:var(--warn);font-size:11px;font-weight:600}');
  p('.anom-dot{fill:var(--panel);stroke:var(--crit);stroke-width:2}');
  p('.esm-line{stroke:var(--ok);stroke-width:1.5}');
  p('.esm-dot{fill:var(--ok)}');
  p('.cross-dot{fill:var(--crit)}');
  p('.cross-label{fill:var(--crit);font-size:11px;font-weight:700}');
  p('.shift{fill:var(--shift-bg)}');
  p('.shift-label{fill:var(--warn);font-size:11px;font-weight:600}');
  -- quiet-series strip and anomaly strips
  p('.quiet{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:10px 14px;margin:0 0 20px}');
  p('.quiet .qh{font-size:12px;color:var(--muted);margin-bottom:6px}');
  p('.quiet .qrow{display:grid;grid-template-columns:minmax(150px,1.2fr) 2fr 110px 60px 90px;gap:12px;align-items:center;padding:5px 0;border-top:1px solid var(--border);font-size:12.5px}');
  p('.quiet .qrow:first-of-type{border-top:none}');
  p('.quiet .qrow .q{color:var(--muted);text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}');
  p('.spark{width:100%;height:24px;display:block}');
  p('.strips{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:8px 14px 10px;margin:8px 0 10px}');
  p('.strip{display:grid;grid-template-columns:minmax(150px,180px) 1fr;gap:10px;align-items:center;padding:6px 0;border-top:1px solid var(--border);font-size:12.5px}');
  p('.strip:first-child{border-top:none}');
  p('.strip .sl b{font-weight:600}');
  p('.strip .sl span{display:block;color:var(--faint);font-size:11px}');
  p('.strip-svg{width:100%;height:30px;display:block}');
  p('.strip-axis{display:grid;grid-template-columns:minmax(150px,180px) 1fr;gap:10px;font-size:11px;color:var(--muted);padding-top:2px}');
  p('.strip-axis div{display:flex;justify-content:space-between}');
  p('.sd-hi{fill:var(--crit)}.sd-lo{fill:var(--accent)}');
  p('@media(max-width:640px){.quiet .qrow{grid-template-columns:1fr 90px 50px}.quiet .qrow svg,.quiet .qrow .qd{display:none}.strip,.strip-axis{grid-template-columns:1fr}.strip .sl span{display:inline;margin-left:6px}}');
  -- tables: zebra rows, severity tint, winner badge
  p('tbody tr:nth-child(even) td{background:var(--panel2)}');
  p('tbody tr:hover td{background:var(--flat-bg)}');
  p('tbody tr.r-crit td:first-child{box-shadow:inset 3px 0 0 var(--crit)}');
  p('tbody tr.r-warn td:first-child{box-shadow:inset 3px 0 0 var(--warn)}');
  p('tbody td{padding:6px 10px}');
  p('.win{font-size:10.5px;font-weight:700;padding:1px 6px;border-radius:5px;background:var(--ok-bg);color:var(--ok)}');
  p('.win.r{background:var(--accent-soft);color:var(--accent-text)}');
  p('.dim{color:var(--faint)}');
  p('.gap-hi{color:var(--warn);font-weight:700}');
  p('.glossary dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:10px 0 0}');
  p('@media print{.tools{display:none}}');
  p('</style>');
  p('</head><body>');

  ----------------------------------------------------------------------
  -- Top nav
  ----------------------------------------------------------------------
  p('<nav class="topnav">');
  p('<span class="brand">AWR Capacity Report</span>');
  p('<a href="#s0">At a glance</a>');
  p('<a href="#s1">1 Days to full</a>');
  p('<a href="#s2">2 Forecast</a>');
  p('<a href="#s3">3 Unusual days</a>');
  p('<a href="#s4">4 CPU</a>');
  p('<a href="#s5">5 Unusual CPU days</a>');
  p('<a href="#s6">6 ESM vs REGR</a>');
  p('<a href="#s7">7 Fixed ceilings</a>');
  p('</nav>');
  p('<div class="wrap">');

  ----------------------------------------------------------------------
  -- Header with the verdict strip (R1). Counts come straight from
  -- CAPR_ALERTS, the same view the text report''s section 0 prints, so the
  -- five numbers cannot disagree with the attention list below them.
  ----------------------------------------------------------------------
  SELECT COUNT(DISTINCT con_dbid) INTO v_con_count FROM capd_tbspc_daily;
  SELECT NVL(MAX(day_dt) - MIN(day_dt) + 1, 0), MAX(day_dt) INTO v_hist_days, v_last_day FROM capd_tbspc_daily;
  SELECT SUM(CASE WHEN severity = 'CRIT' THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity = 'WARN' THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity = 'INFO' THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity IN ('CRIT','WARN') AND kind IN ('TBSPC_FULL','TBSPC_NEARFULL','CPU_SAT','SERIES_LIMIT','SERIES_NEARLIMIT') THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity IN ('CRIT','WARN') AND kind IN ('TBSPC_ANOM','CPU_ANOM','CPU_SHIFT') THEN 1 ELSE 0 END)
    INTO v_n_crit, v_n_warn, v_n_info, v_n_cap, v_n_beh
  FROM   capr_alerts;
  v_n_crit := NVL(v_n_crit, 0); v_n_warn := NVL(v_n_warn, 0); v_n_info := NVL(v_n_info, 0);
  v_n_cap := NVL(v_n_cap, 0); v_n_beh := NVL(v_n_beh, 0);
  v_first_crit := NULL;
  FOR a IN (SELECT series_key, kind, value, unit FROM capr_alerts WHERE severity = 'CRIT'
            ORDER BY sev_rank, value FETCH FIRST 1 ROW ONLY) LOOP
    v_first_crit := esc(a.series_key)
                    || CASE WHEN a.unit = 'DAYS' THEN ', ' || TO_CHAR(a.value, 'FM999990') || ' days'
                            WHEN a.unit = 'PCT'  THEN ', ' || TO_CHAR(a.value, 'FM990.0') || '%' END;
  END LOOP;
  -- forecast quality rollup (reused by the healthy line further down)
  SELECT COUNT(*),
         SUM(CASE WHEN quality = 'OK'                   THEN 1 ELSE 0 END),
         SUM(CASE WHEN quality = 'FLAT'                 THEN 1 ELSE 0 END),
         SUM(CASE WHEN quality = 'LOW_CONFIDENCE'       THEN 1 ELSE 0 END),
         SUM(CASE WHEN quality = 'INSUFFICIENT_HISTORY' THEN 1 ELSE 0 END)
    INTO v_cov_total, v_cov_ok, v_n_flat, v_n_low, v_n_insuf
  FROM   capr_tbspc_days_to_full;
  -- host CPU busy-hour p95 (first container that has one)
  v_p95_cur := NULL; v_p95_dts := NULL; v_p95_q := NULL;
  FOR c IN (SELECT cur_val, days_to_sat, quality FROM capr_cpu_trend
            WHERE metric = 'BUSY_P95' ORDER BY con_dbid FETCH FIRST 1 ROW ONLY) LOOP
    v_p95_cur := c.cur_val; v_p95_dts := c.days_to_sat; v_p95_q := c.quality;
  END LOOP;
  SELECT COUNT(*) INTO v_bt_rows FROM capr_backtest WHERE esm_mape IS NOT NULL;

  p('<div class="rep-head">');
  p('<div><h1>AWR Capacity Report</h1><div class="id"><b>' || esc(cap_db) || '</b> &middot; ' || esc(cap_host)
    || ' &middot; generated ' || esc(cap_gen) || ' &middot; ' || TO_CHAR(v_hist_days, 'FM999990')
    || ' days of AWR history &middot; schema ' || esc(cap_user) || '</div></div>');
  p('<div class="tools"><button class="tbtn" id="themeBtn" type="button" title="Switch light / dark">&#9681; Theme</button>'
    || '<button class="tbtn" type="button" onclick="window.print()">&#9113; Print</button></div>');
  p('<div class="kpis">');
  p('<div class="kpi' || CASE WHEN v_n_crit > 0 THEN ' crit' END || '"><div class="l">Critical</div><div class="v">'
    || TO_CHAR(v_n_crit, 'FM999990') || '</div><div class="s">' || NVL(v_first_crit, 'nothing critical') || '</div></div>');
  p('<div class="kpi' || CASE WHEN v_n_warn > 0 THEN ' warn' END || '"><div class="l">Warnings</div><div class="v">'
    || TO_CHAR(v_n_warn, 'FM999990') || '</div><div class="s">' || TO_CHAR(v_n_cap, 'FM999990') || ' capacity &middot; '
    || TO_CHAR(v_n_beh, 'FM999990') || ' behaviour</div></div>');
  p('<div class="kpi' || CASE WHEN NVL(v_cov_total, 0) > 0 AND v_cov_ok = v_cov_total THEN ' ok' END
    || '"><div class="l">Forecast quality</div><div class="v">' || TO_CHAR(NVL(v_cov_ok, 0), 'FM999990')
    || '<small> / ' || TO_CHAR(NVL(v_cov_total, 0), 'FM999990') || '</small></div><div class="s">tablespaces rated OK</div></div>');
  IF v_p95_cur IS NOT NULL THEN
    p('<div class="kpi' || CASE WHEN v_p95_dts IS NOT NULL AND v_p95_dts <= dtf_crit THEN ' crit'
                                WHEN v_p95_dts IS NOT NULL AND v_p95_dts <= dtf_warn THEN ' warn' END
      || '"><div class="l">Host CPU p95</div><div class="v">' || TO_CHAR(ROUND(v_p95_cur), 'FM990') || '<small>%</small></div><div class="s">'
      || CASE WHEN v_p95_q = 'OK' AND v_p95_dts IS NOT NULL THEN TO_CHAR(cpu_sat, 'FM990') || '% in ~' || TO_CHAR(v_p95_dts, 'FM999990') || ' days'
              WHEN v_p95_q = 'OK' THEN 'no saturation in sight'
              WHEN v_p95_q = 'LOW_CONFIDENCE' THEN 'trend too erratic to project'
              WHEN v_p95_q = 'INSUFFICIENT_HISTORY' THEN 'not enough history yet'
              ELSE 'not trending' END || '</div></div>');
  ELSE
    p('<div class="kpi"><div class="l">Host CPU p95</div><div class="v">&ndash;</div><div class="s">no CPU history yet</div></div>');
  END IF;
  p('<div class="kpi"><div class="l">Tier 2 models</div><div class="v">' || TO_CHAR(esm_ok, 'FM999990') || '</div><div class="s">'
    || CASE WHEN esm_ok = 0 THEN 'none trained'
            WHEN v_bt_rows > 0 THEN 'ESM trained &middot; backtest on'
            ELSE 'ESM trained &middot; no backtest yet' END || '</div></div>');
  p('</div>');  -- .kpis
  -- one fold for everything about reading the report
  p('<details class="fold"><summary>How to read this report</summary><div class="fold-body">');
  p('<dl class="kv-grid" style="margin:8px 0 0">');
  p('<div class="kv"><dt>Thresholds</dt><dd>days-to-full WARN&lt;=' || dtf_warn
      || ' CRIT&lt;=' || dtf_crit || '; near-full WARN&gt;=' || TO_CHAR(nf_warn, 'FM990') || '% CRIT&gt;=' || TO_CHAR(nf_crit, 'FM990')
      || '%; CPU saturation ' || cpu_sat || '%</dd></div>');
  p('<div class="kv"><dt>Training window</dt><dd>last ' || TO_CHAR(train_days, 'FM999990') || ' days; at least '
      || TO_CHAR(min_train_days, 'FM999990') || ' days before a forecast is trusted; R2 gate ' || TO_CHAR(r2_gate, 'FM0.00') || '</dd></div>');
  p('<div class="kv"><dt>Tier 2 models</dt><dd>' || esm_ok || ' OML ESM model(s) trained (OK)</dd></div>');
  p('</dl>');
  p('<div class="note">Forecasts degrade loudly on short AWR retention: watch Train days and Quality. '
      || 'INSUFFICIENT_HISTORY means fewer than the configured minimum training days; raise '
      || 'DBMS_WORKLOAD_REPOSITORY retention for real trends. Everything in this report is read-only.</div>');
  p('<div class="glossary" style="border:0;margin:0"><dl>');
  p('<dt>Forecast / projection</dt><dd>Where a number is heading, based on its recent trend.</dd>');
  p('<dt>REGR (straight-line trend)</dt><dd>Fits a straight line through recent history and extends it forward.</dd>');
  p('<dt>ESM</dt><dd>Oracle''s machine-learning forecast; it also learns weekly patterns and is usually best for the next 30 days.</dd>');
  p('<dt>95% band</dt><dd>The shaded wedge on a chart: the actual value should land inside it 95 times out of 100 if growth stays like the recent past.</dd>');
  p('<dt>R2</dt><dd>How closely growth follows a straight line: 1.00 is perfectly steady, near 0 is erratic.</dd>');
  p('<dt>Quality: OK</dt><dd>Steady enough to forecast reliably.</dd>');
  p('<dt>Quality: LOW_CONFIDENCE</dt><dd>Growth is too erratic for a dependable estimate.</dd>');
  p('<dt>Quality: FLAT</dt><dd>Not growing at all.</dd>');
  p('<dt>Quality: INSUFFICIENT_HISTORY</dt><dd>Not enough days of AWR history yet.</dd>');
  p('<dt>Anomaly</dt><dd>A day that stands out sharply from what is normal for that series.</dd>');
  p('<dt>Level shift</dt><dd>A sustained step in the level a series runs at, as opposed to a one-day outlier.</dd>');
  p('<dt>Robust z-score</dt><dd>How far outside its normal range a day was; 3 or more is clearly unusual.</dd>');
  p('<dt>MAD</dt><dd>Median absolute deviation -- a spike-resistant way of measuring "normal".</dd>');
  p('<dt>Days-to-full</dt><dd>Estimated days until a tablespace reaches its allocated limit.</dd>');
  p('<dt>Saturation</dt><dd>The busy percent at which the CPU is treated as maxed out.</dd>');
  p('</dl></div>');
  p('</div></details>');
  p('</div>');  -- .rep-head
  ----------------------------------------------------------------------
  -- Section 0: "At a glance" -- plain-English best-guess prediction cards
  -- and an anomaly timeline, for readers who do not want the statistics.
  -- Everything below is SELECT-only over the same CAPF_/CAPA_/CAPD_ views
  -- the detailed sections use; nothing new is computed.
  ----------------------------------------------------------------------
  p('<section id="s0">');
  p('<h2>At a glance</h2>');
  p('<p class="desc">What needs attention, ranked, then everything that is fine in one line. '
      || 'Every row comes from CAPR_ALERTS, the same view a monitoring system would poll.</p>');

  ----------------------------------------------------------------------
  -- Attention list: one row per CRIT / WARN alert, with the kind, a plain
  -- sentence, one line of supporting numbers and the number that matters
  -- at the right. The lookups only fetch columns the detail sections print.
  ----------------------------------------------------------------------
  IF v_n_crit + v_n_warn = 0 THEN
    p('<div class="glance-ok">All clear: nothing is near-full, no tablespace, series or CPU is forecast to hit its limit within '
      || TO_CHAR(dtf_warn, 'FM999990') || ' days, and no sustained shift or spike is open.'
      || CASE WHEN v_n_info > 0 THEN ' ' || TO_CHAR(v_n_info, 'FM999990') || ' informational item(s) below.' END || '</div>');
  ELSE
    p('<div class="attn">');
    FOR a IN (
      SELECT severity, kind, dbid, con_dbid, db_pdb, series_key, day_dt, value, threshold, unit, message,
             CASE kind WHEN 'TBSPC_FULL' THEN 1 WHEN 'CPU_SAT' THEN 2 WHEN 'SERIES_LIMIT' THEN 3
                       WHEN 'CPU_SHIFT' THEN 4 WHEN 'TBSPC_NEARFULL' THEN 5 WHEN 'SERIES_NEARLIMIT' THEN 6
                       WHEN 'TBSPC_ANOM' THEN 7 WHEN 'CPU_ANOM' THEN 8 ELSE 9 END AS kord
      FROM   capr_alerts
      WHERE  severity IN ('CRIT','WARN')
      ORDER  BY sev_rank, kord, value
    ) LOOP
      v_main := NULL; v_sub := NULL; v_big := NULL; v_small := NULL; v_kind_lbl := NULL;
      v_tmp := CASE WHEN v_con_count > 1 THEN esc(a.db_pdb) || ' &middot; ' END;

      IF a.kind = 'TBSPC_FULL' THEN
        v_kind_lbl := 'Days to full';
        FOR t IN (SELECT slope_mb, cur_gb, limit_gb, dtf_worst, accel, pct_used, days_to_full
                  FROM capr_tbspc_days_to_full WHERE con_dbid = a.con_dbid AND tablespace_name = a.series_key
                  FETCH FIRST 1 ROW ONLY) LOOP
          v_main := '<b>' || esc(a.series_key) || '</b> fills at ' || fmt_rate_mb(t.slope_mb)
                    || CASE WHEN t.accel >= 1.5 THEN ', growth &times;' || TO_CHAR(t.accel, 'FM990.0') || ' vs its longer-term pace' END;
          v_sub  := v_tmp || fmt_size_gb(t.cur_gb) || ' of ' || fmt_size_gb(t.limit_gb) || ' (' || TO_CHAR(t.pct_used, 'FM990.0') || '%)'
                    || CASE WHEN t.dtf_worst IS NOT NULL AND t.dtf_worst < t.days_to_full
                            THEN ' &middot; worst case ' || TO_CHAR(t.dtf_worst, 'FM999990') || ' days' END;
          v_big  := TO_CHAR(a.value, 'FM999990') || ' days';
          v_small := '&asymp; ' || dfmt(NVL(v_last_day, SYSDATE) + a.value);
        END LOOP;
      ELSIF a.kind = 'TBSPC_NEARFULL' THEN
        v_kind_lbl := 'Near full';
        FOR t IN (SELECT slope_mb, cur_gb, limit_gb, days_to_full, quality
                  FROM capr_tbspc_days_to_full WHERE con_dbid = a.con_dbid AND tablespace_name = a.series_key
                  FETCH FIRST 1 ROW ONLY) LOOP
          v_main := '<b>' || esc(a.series_key) || '</b> is ' || TO_CHAR(a.value, 'FM990.0') || '% full now'
                    || CASE WHEN t.quality = 'FLAT' THEN ', not growing'
                            WHEN t.days_to_full IS NOT NULL AND t.days_to_full > 365 THEN ', growing slowly'
                            WHEN t.days_to_full IS NOT NULL THEN ', still growing'
                            WHEN t.quality = 'OK' THEN ', not growing'
                            ELSE ', growth too erratic to forecast' END;
          v_sub  := v_tmp || fmt_size_gb(t.cur_gb) || ' of ' || fmt_size_gb(t.limit_gb)
                    || CASE WHEN t.days_to_full IS NOT NULL THEN ' &middot; at ' || fmt_rate_mb(t.slope_mb)
                            || ' full in ' || time_phrase(t.days_to_full) END;
          v_big  := TO_CHAR(a.value, 'FM990.0') || '%';
          v_small := 'now';
        END LOOP;
      ELSIF a.kind = 'CPU_SAT' THEN
        v_kind_lbl := 'CPU saturation';
        FOR t IN (SELECT cur_val, slope_per_day, sat_worst, sat_best FROM capr_cpu_trend
                  WHERE con_dbid = a.con_dbid AND metric = a.series_key FETCH FIRST 1 ROW ONLY) LOOP
          v_main := '<b>Host CPU</b> ' || CASE a.series_key WHEN 'BUSY_P95' THEN 'busy-hour p95' WHEN 'BUSY_PEAK' THEN 'peak-window busy%'
                                                             ELSE 'daily average busy%' END
                    || ' is trending toward the ' || TO_CHAR(cpu_sat, 'FM990') || '% line';
          v_sub  := v_tmp || 'now ' || TO_CHAR(t.cur_val, 'FM990.0') || '% &middot; slope +' || TO_CHAR(t.slope_per_day, 'FM990.00') || ' pts/day'
                    || CASE WHEN t.sat_worst IS NOT NULL THEN ' &middot; ' || TO_CHAR(t.sat_worst, 'FM999990') || '&ndash;'
                            || NVL(TO_CHAR(t.sat_best, 'FM999990'), 'never') || ' day range' END;
        END LOOP;
        v_big := TO_CHAR(a.value, 'FM999990') || ' days';
        v_small := '&asymp; ' || dfmt(NVL(v_last_day, SYSDATE) + a.value);
      ELSIF a.kind = 'CPU_SHIFT' THEN
        v_kind_lbl := 'Level shift';
        FOR t IN (SELECT recent_days, base_days, recent_med, base_med, n_above, n_below, n_recent, shift_flag, last_day
                  FROM capr_cpu_shifts WHERE con_dbid = a.con_dbid AND metric = a.series_key FETCH FIRST 1 ROW ONLY) LOOP
          v_main := '<b>' || esc(a.db_pdb) || '</b> ' || CASE a.series_key WHEN 'DB_CPU_PCT' THEN 'DB CPU' ELSE esc(a.series_key) END
                    || CASE WHEN t.shift_flag = 'UP' THEN ' stepped up and stayed up' ELSE ' stepped down and stayed down' END;
          v_sub  := 'last ' || TO_CHAR(t.recent_days, 'FM990') || ' days median ' || TO_CHAR(t.recent_med, 'FM990.0')
                    || '% vs ' || TO_CHAR(t.base_med, 'FM990.0') || '% over the ' || TO_CHAR(t.base_days, 'FM990') || ' days before &middot; '
                    || TO_CHAR(GREATEST(t.n_above, t.n_below), 'FM990') || ' of ' || TO_CHAR(t.n_recent, 'FM990') || ' days past the baseline';
          v_small := 'since ' || dfmt(t.last_day - t.recent_days + 1);
        END LOOP;
        v_big := CASE WHEN a.value >= 0 THEN '+' ELSE '' END || TO_CHAR(a.value, 'FM9990.0') || ' pts';
      ELSIF a.kind IN ('SERIES_LIMIT', 'SERIES_NEARLIMIT') THEN
        v_kind_lbl := CASE a.series_key WHEN 'SESSIONS' THEN 'Sessions' WHEN 'PROCESSES' THEN 'Processes'
                                        WHEN 'DB_SIZE_GB' THEN 'Database size' ELSE esc(a.series_key) END;
        FOR t IN (SELECT cur_val, cur_limit, unit, pct_of_limit, slope_per_day, sat_value, days_to_limit
                  FROM capr_series WHERE con_dbid = a.con_dbid AND series = a.series_key FETCH FIRST 1 ROW ONLY) LOOP
          IF a.kind = 'SERIES_LIMIT' THEN
            v_main := '<b>' || esc(a.series_key) || '</b> heading for ' || TO_CHAR(ROUND(100 * t.sat_value / NULLIF(t.cur_limit, 0)), 'FM990')
                      || '% of its limit';
            v_big  := TO_CHAR(a.value, 'FM999990') || ' days';
            v_small := '&asymp; ' || dfmt(NVL(v_last_day, SYSDATE) + a.value);
          ELSE
            v_main := '<b>' || esc(a.series_key) || '</b> is at ' || TO_CHAR(a.value, 'FM990.0') || '% of its limit now';
            v_big  := TO_CHAR(a.value, 'FM990.0') || '%';
            v_small := 'now';
          END IF;
          v_sub := v_tmp || RTRIM(TO_CHAR(t.cur_val, 'FM99999999990.99'), '.') || ' of ' || RTRIM(TO_CHAR(t.cur_limit, 'FM99999999990.99'), '.')
                   || ' ' || LOWER(esc(t.unit))
                   || CASE WHEN t.slope_per_day IS NOT NULL AND t.slope_per_day <> 0
                           THEN ' &middot; ' || CASE WHEN t.slope_per_day > 0 THEN '+' END || TO_CHAR(t.slope_per_day, 'FM99990.00') || ' per day' END;
        END LOOP;
      ELSIF a.kind = 'TBSPC_ANOM' THEN
        v_kind_lbl := 'Anomaly';
        FOR t IN (SELECT delta_mb, med_mb, z, anomaly_flag, day_str FROM capr_tbspc_anomalies
                  WHERE con_dbid = a.con_dbid AND tablespace_name = a.series_key AND day_dt = a.day_dt FETCH FIRST 1 ROW ONLY) LOOP
          v_main := '<b>' || esc(a.series_key) || '</b> ' || CASE WHEN t.delta_mb >= 0 THEN 'grew ' ELSE 'shrank ' END
                    || fmt_size_gb(ABS(t.delta_mb) / 1024) || ' in one day'
                    || CASE WHEN t.med_mb IS NOT NULL THEN ' (normal: ' || fmt_size_gb(t.med_mb / 1024) || ')' END;
          v_sub  := v_tmp || dfmt(a.day_dt) || ' &middot; robust z ' || TO_CHAR(t.z, 'FM99990.0')
                    || ' &middot; one day; the forecast is not driven by it';
          v_big  := CASE WHEN t.delta_mb >= 0 THEN '+' ELSE '&minus;' END || fmt_size_gb(ABS(t.delta_mb) / 1024);
        END LOOP;
        v_small := dfmt(a.day_dt);
      ELSIF a.kind = 'CPU_ANOM' THEN
        v_kind_lbl := 'Anomaly';
        FOR t IN (SELECT busy_pct, median_pct, z FROM capr_cpu_anomalies
                  WHERE con_dbid = a.con_dbid AND day_dt = a.day_dt FETCH FIRST 1 ROW ONLY) LOOP
          v_main := '<b>Host CPU</b> ran ' || TO_CHAR(t.busy_pct, 'FM990.0') || '% busy vs the usual '
                    || TO_CHAR(t.median_pct, 'FM990.0') || '% for a ' || TO_CHAR(a.day_dt, 'FMDay');
          v_sub  := v_tmp || dfmt(a.day_dt) || ' &middot; robust z ' || TO_CHAR(t.z, 'FM99990.0') || ' &middot; single day';
          v_big  := CASE WHEN t.busy_pct >= t.median_pct THEN '+' ELSE '&minus;' END
                    || TO_CHAR(ABS(t.busy_pct - t.median_pct), 'FM990') || ' pts';
        END LOOP;
        v_small := dfmt(a.day_dt);
      END IF;

      IF v_main IS NULL THEN
        v_kind_lbl := NVL(v_kind_lbl, esc(REPLACE(a.kind, '_', ' ')));
        v_main := esc(a.message);
        v_big  := CASE a.unit WHEN 'DAYS' THEN TO_CHAR(a.value, 'FM999990') || ' days'
                              WHEN 'PCT'  THEN TO_CHAR(a.value, 'FM990.0') || '%'
                              WHEN 'BYTES' THEN fmt_size_gb(a.value / 1073741824) END;
      END IF;
      v_sub := v_sub || evidence_link(a.kind, a.con_dbid, a.series_key);
      attn_row(a.severity, v_kind_lbl, v_main, v_sub, v_big, v_small);
    END LOOP;
    p('</div>');  -- .attn
  END IF;

  -- informational alerts (shrinks, low-side days) stay out of the list
  IF v_n_info > 0 THEN
    p('<details class="fold"><summary>' || TO_CHAR(v_n_info, 'FM999990') || ' informational item'
      || CASE WHEN v_n_info = 1 THEN '' ELSE 's' END || ' (shrinks and low-side days)</summary><div class="fold-body"><ul class="attn-list" style="margin:0">');
    FOR a IN (SELECT message, kind, con_dbid, series_key FROM capr_alerts WHERE severity = 'INFO' ORDER BY kind, value) LOOP
      p('<li>' || esc(a.message) || evidence_link(a.kind, a.con_dbid, a.series_key) || '</li>');
    END LOOP;
    p('</ul></div></details>');
  END IF;

  ----------------------------------------------------------------------
  -- Healthy line: every capacity series NOT in the attention list, with a
  -- short verdict each, so "fine" is stated rather than implied.
  ----------------------------------------------------------------------
  v_chips := 0; v_tmp := NULL;
  FOR r IN (
    SELECT t.tablespace_name, t.db_pdb, t.days_to_full, t.quality, t.pct_used
    FROM   capr_tbspc_days_to_full t
    WHERE  NOT EXISTS (SELECT 1 FROM capr_alerts a
                       WHERE a.con_dbid = t.con_dbid AND a.series_key = t.tablespace_name
                         AND a.kind IN ('TBSPC_FULL','TBSPC_NEARFULL') AND a.severity IN ('CRIT','WARN'))
    ORDER  BY CASE WHEN t.quality = 'OK' AND t.days_to_full IS NOT NULL THEN 0 ELSE 1 END, t.days_to_full, t.tablespace_name
  ) LOOP
    v_chips := v_chips + 1;
    IF v_chips <= 30 THEN
      v_tmp := v_tmp || '<span class="chip' || CASE WHEN r.quality <> 'OK' THEN ' q' END || '">'
               || con_prefix(r.db_pdb) || esc(r.tablespace_name) || ' &middot; '
               || CASE WHEN r.quality = 'OK' AND r.days_to_full IS NOT NULL THEN short_dur(r.days_to_full)
                       WHEN r.quality = 'OK' THEN 'not filling'
                       WHEN r.quality = 'FLAT' THEN 'flat'
                       WHEN r.quality = 'LOW_CONFIDENCE' THEN 'erratic'
                       WHEN r.quality = 'INSUFFICIENT_HISTORY' THEN 'new'
                       ELSE LOWER(esc(r.quality)) END || '</span>';
    END IF;
  END LOOP;
  IF v_chips > 30 THEN
    v_tmp := v_tmp || '<span class="chip q">and ' || TO_CHAR(v_chips - 30, 'FM999990') || ' more</span>';
  END IF;
  FOR r IN (
    SELECT s.series, s.db_pdb, s.pct_of_limit, s.days_to_limit, s.quality, s.cur_val, s.unit
    FROM   capr_series s
    WHERE  NOT EXISTS (SELECT 1 FROM capr_alerts a
                       WHERE a.con_dbid = s.con_dbid AND a.series_key = s.series
                         AND a.kind IN ('SERIES_LIMIT','SERIES_NEARLIMIT') AND a.severity IN ('CRIT','WARN'))
    ORDER  BY s.rank_series
  ) LOOP
    v_tmp := v_tmp || '<span class="chip' || CASE WHEN r.quality <> 'OK' THEN ' q' END || '">'
             || con_prefix(r.db_pdb)
             || CASE r.series WHEN 'DB_SIZE_GB' THEN 'DB size' WHEN 'REDO_GB_DAY' THEN 'Redo' ELSE INITCAP(esc(r.series)) END
             || CASE WHEN r.pct_of_limit IS NOT NULL THEN ' &middot; ' || TO_CHAR(r.pct_of_limit, 'FM990') || '%'
                     WHEN r.series = 'REDO_GB_DAY' THEN ' &middot; ' || TO_CHAR(r.cur_val, 'FM999990.0') || ' GiB/day' END
             || CASE WHEN r.quality = 'OK' AND r.days_to_limit IS NOT NULL THEN ' &middot; ' || short_dur(r.days_to_limit)
                     WHEN r.quality = 'FLAT' THEN ' &middot; flat'
                     WHEN r.quality = 'OK' THEN ''
                     WHEN r.quality = 'LOW_CONFIDENCE' THEN ' &middot; erratic'
                     ELSE ' &middot; new' END || '</span>';
  END LOOP;
  FOR r IN (
    SELECT c.db_pdb, c.cur_val, c.days_to_sat, c.quality
    FROM   capr_cpu_trend c
    WHERE  c.metric = 'BUSY_P95'
      AND  NOT EXISTS (SELECT 1 FROM capr_alerts a WHERE a.con_dbid = c.con_dbid AND a.kind = 'CPU_SAT')
    ORDER  BY c.con_dbid
  ) LOOP
    v_tmp := v_tmp || '<span class="chip' || CASE WHEN r.quality <> 'OK' THEN ' q' END || '">Host CPU'
             || CASE WHEN v_con_count > 1 THEN ' (' || esc(r.db_pdb) || ')' END
             || ' &middot; p95 ' || TO_CHAR(ROUND(r.cur_val), 'FM990') || '%'
             || CASE WHEN r.quality = 'OK' AND r.days_to_sat IS NOT NULL THEN ' &middot; ' || short_dur(r.days_to_sat)
                     WHEN r.quality = 'OK' THEN ' &middot; no saturation in sight'
                     WHEN r.quality = 'LOW_CONFIDENCE' THEN ' &middot; erratic'
                     WHEN r.quality = 'FLAT' THEN ' &middot; flat'
                     ELSE ' &middot; new' END || '</span>';
  END LOOP;
  IF v_tmp IS NOT NULL THEN
    p('<div class="healthy"><b>' || CASE WHEN v_n_crit + v_n_warn = 0 THEN 'Everything:' ELSE 'Healthy, nothing to do:' END || '</b>');
    WHILE v_tmp IS NOT NULL LOOP
      p(SUBSTR(v_tmp, 1, INSTR(v_tmp || '</span>', '</span>') + 6));
      v_tmp := SUBSTR(v_tmp, INSTR(v_tmp || '</span>', '</span>') + 7);
    END LOOP;
    p('</div>');
  END IF;

  ----------------------------------------------------------------------
  -- Hero duo: whole-database total size and host CPU busy-hour p95, drawn
  -- with the shared chart grammar. cur_hero mirrors CAPF_TBSPC_FORECAST
  -- (same epoch, window, REGR aggregates and quality ladder).
  ----------------------------------------------------------------------
  p('<div class="hero-duo">');
  FOR hf IN cur_hero LOOP
    v_hlabel := 'Whole database' || CASE WHEN v_con_count > 1 THEN ' (' || db_label(hf.dbid, hf.con_dbid) || ')' END;
    IF hf.n < min_train_days THEN v_hquality := 'INSUFFICIENT_HISTORY';
    ELSIF hf.slope = 0 OR hf.r2 IS NULL THEN v_hquality := 'FLAT';
    ELSIF hf.r2 < r2_gate THEN v_hquality := 'LOW_CONFIDENCE';
    ELSE v_hquality := 'OK'; END IF;
    v_hero_gb    := hf.cur_used / 1073741824;
    v_rate_gb_mo := hf.slope * 30 / 1073741824;
    v_hlimit_gb  := CASE WHEN hf.limit_all = 1 THEN hf.cur_limit / 1073741824 END;
    v_days_to_lim := NULL;
    IF v_hquality = 'OK' AND hf.slope > 0 AND v_hlimit_gb IS NOT NULL AND hf.cur_limit > hf.cur_used THEN
      v_days_to_lim := FLOOR((hf.cur_limit - hf.cur_used) / hf.slope);
    END IF;
    v_big := NULL; v_big_lbl := NULL; v_big_cls := NULL; v_accent := NULL;
    IF v_days_to_lim IS NOT NULL THEN
      v_big := short_dur(v_days_to_lim);
      v_big_lbl := 'to the allocated limit &middot; &asymp; ' || dfmt(hf.last_day + v_days_to_lim);
      v_big_cls := CASE WHEN v_days_to_lim <= dtf_crit THEN 'crit' WHEN v_days_to_lim <= dtf_warn THEN 'warn' ELSE 'ok' END;
      v_accent  := CASE WHEN v_days_to_lim <= dtf_crit THEN 'crit' WHEN v_days_to_lim <= dtf_warn THEN 'warn' END;
    END IF;
    v_subtitle := 'using ' || fmt_size_gb(v_hero_gb)
                  || CASE WHEN v_hlimit_gb IS NOT NULL THEN ' of ' || fmt_size_gb(v_hlimit_gb) || ' allocated' END
                  || CASE WHEN v_hquality = 'OK' AND hf.slope > 0 THEN ' &middot; growing ' || fmt_size_gb(v_rate_gb_mo) || ' per month'
                          WHEN v_hquality = 'OK' AND hf.slope < 0 THEN ' &middot; shrinking ' || fmt_size_gb(ABS(v_rate_gb_mo)) || ' per month'
                          WHEN v_hquality = 'FLAT' THEN ' &middot; not growing'
                          WHEN v_hquality = 'INSUFFICIENT_HISTORY' THEN ' &middot; not enough history for a whole-database estimate yet'
                          ELSE ' &middot; size changes too unevenly for a reliable estimate' END;
    card_open(esc(v_hlabel) || ' ' || quality_pill(v_hquality), v_subtitle, v_big, v_big_lbl, v_big_cls, v_accent,
              'dbhero-' || TO_CHAR(hf.con_dbid));

    xs.DELETE; ys.DELETE; v_cnt := 0; v_cnt2 := 0; v_nband := 0; v_nanom := 0; v_has_proj := FALSE;
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
        v_horizon := CASE WHEN v_days_to_lim IS NOT NULL AND v_days_to_lim > 180 AND v_days_to_lim <= 365 THEN 365 ELSE 180 END;
        v_proj_y := ys(v_cnt) + (hf.slope / 1073741824) * v_horizon;
        v_xmax   := v_last_day_n + v_horizon;
        px1(1) := v_last_day_n; py1(1) := ys(v_cnt);
        px1(2) := v_xmax;       py1(2) := v_proj_y;
        v_has_proj := TRUE;
      END IF;
      v_ymin := 0; v_ymax := ys(1);
      FOR i IN 1 .. v_cnt LOOP
        IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF;
      END LOOP;
      IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
      v_limit_gb   := v_hlimit_gb;
      v_range      := v_ymax - v_ymin;
      v_show_limit := (v_limit_gb IS NOT NULL) AND (v_limit_gb - v_ymax) <= 3 * v_range;
      IF v_show_limit THEN v_ymax := GREATEST(v_ymax, v_limit_gb * 1.04); END IF;
      IF (v_ymax - v_ymin) < 0.001 THEN v_ymax := v_ymin + 1; END IF;
      v_ymax := v_ymax + (v_ymax - v_ymin) * 0.10;
      v_cross_x := NULL; v_cross_lbl := NULL;
      IF v_show_limit AND v_days_to_lim IS NOT NULL THEN
        v_cross_x := v_last_day_n + v_days_to_lim;
        v_cross_lbl := 'limit &asymp; ' || dfmt(hf.last_day + v_days_to_lim);
      END IF;
      chart_svg('Whole database total size: history, projection and allocated limit',
                v_xmin, v_xmax, v_ymin, v_ymax, 'GiB', v_last_day_n,
                CASE WHEN v_show_limit THEN v_limit_gb END,
                CASE WHEN v_show_limit THEN 'allocated ' || fmt_size_gb(v_limit_gb) END,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                v_cross_x, CASE WHEN v_show_limit THEN v_limit_gb END, v_cross_lbl, 250);
      IF v_limit_gb IS NOT NULL AND NOT v_show_limit THEN
        p('<div class="chart-sub">allocated-limit line hidden: ' || fmt_size_gb(v_limit_gb) || ' is off the chart scale</div>');
      END IF;
    END IF;
    p('</div>');  -- .chart-card
  END LOOP;

  -- Host CPU hero: busy-hour p95 (what saturates) with the daily average as
  -- a faint second line; projection, band and crossing from CAPF_CPU_TREND.
  FOR ch IN (
    SELECT t.db_pdb, t.con_dbid, t.dbid, t.cur_val, t.days_to_sat, t.sat_worst, t.sat_best, t.r2, t.quality, t.slope_per_day,
           f.proj_30_lo, f.proj_30_hi, f.proj_90_lo, f.proj_90_hi, f.proj_30, f.proj_90
    FROM   capr_cpu_trend t
    LEFT   JOIN capf_cpu_trend f ON f.dbid = t.dbid AND f.con_dbid = t.con_dbid AND f.metric = t.metric
    WHERE  t.metric = 'BUSY_P95'
    ORDER  BY t.con_dbid
  ) LOOP
    v_hlabel := 'Host CPU busy-hour p95' || CASE WHEN v_con_count > 1 THEN ' (' || ch.db_pdb || ')' END;
    v_big := NULL; v_big_lbl := NULL; v_big_cls := NULL; v_accent := NULL;
    IF ch.quality = 'OK' AND ch.days_to_sat IS NOT NULL THEN
      v_big := short_dur(ch.days_to_sat);
      v_big_lbl := 'to ' || TO_CHAR(cpu_sat, 'FM990') || '% &middot; '
                   || CASE WHEN ch.sat_worst IS NOT NULL THEN TO_CHAR(ch.sat_worst, 'FM999990') || '&ndash;' || NVL(TO_CHAR(ch.sat_best, 'FM999990'), 'never')
                           ELSE '&asymp; ' || dfmt(SYSDATE + ch.days_to_sat) END;
      v_big_cls := CASE WHEN ch.days_to_sat <= dtf_crit THEN 'crit' WHEN ch.days_to_sat <= dtf_warn THEN 'warn' ELSE 'ok' END;
      v_accent  := CASE WHEN ch.days_to_sat <= dtf_crit THEN 'crit' WHEN ch.days_to_sat <= dtf_warn THEN 'warn' END;
    END IF;
    v_subtitle := 'now ' || TO_CHAR(ch.cur_val, 'FM990.0') || '% in the busiest hour &middot; '
                  || CASE WHEN ch.quality = 'OK' THEN 'trend fit OK, R2 ' || TO_CHAR(ch.r2, 'FM0.00')
                          WHEN ch.quality = 'LOW_CONFIDENCE' THEN 'too erratic to project reliably'
                          WHEN ch.quality = 'INSUFFICIENT_HISTORY' THEN 'not enough history yet'
                          ELSE 'not trending' END
                  || ' &middot; faint line = daily average';
    card_open(esc(v_hlabel) || ' ' || quality_pill(ch.quality), v_subtitle, v_big, v_big_lbl, v_big_cls, v_accent, NULL);

    xs.DELETE; ys.DELETE; xs2.DELETE; ys2.DELETE; v_cnt := 0; v_cnt2 := 0; v_nband := 0; v_nanom := 0; v_has_proj := FALSE;
    FOR d IN (SELECT day_dt, busy_pct, busy_p95 FROM capd_cpu_daily WHERE con_dbid = ch.con_dbid ORDER BY day_dt) LOOP
      v_cnt := v_cnt + 1;
      xs(v_cnt) := d.day_dt - c_epoch; ys(v_cnt) := NVL(d.busy_p95, d.busy_pct);
      v_cnt2 := v_cnt2 + 1;
      xs2(v_cnt2) := d.day_dt - c_epoch; ys2(v_cnt2) := d.busy_pct;
    END LOOP;
    IF v_cnt = 0 THEN
      p('<div class="empty-note">No daily CPU history collected yet to chart.</div>');
    ELSE
      v_last_day_n := xs(v_cnt); v_xmin := xs(1); v_xmax := v_last_day_n; v_proj_y := NULL;
      IF ch.quality = 'OK' AND ch.slope_per_day IS NOT NULL THEN
        v_proj_y := ys(v_cnt) + ch.slope_per_day * 90;
        v_xmax   := v_last_day_n + 90;
        px1(1) := v_last_day_n; py1(1) := ys(v_cnt);
        px1(2) := v_xmax;       py1(2) := v_proj_y;
        v_has_proj := TRUE;
        IF ch.proj_30_lo IS NOT NULL AND ch.proj_90_lo IS NOT NULL THEN
          v_half := (ch.proj_30_hi - ch.proj_30_lo) / 2;
          v_nband := 2;
          bx(1) := v_last_day_n + 30; blo(1) := ys(v_cnt) + ch.slope_per_day * 30 - v_half; bhi(1) := ys(v_cnt) + ch.slope_per_day * 30 + v_half;
          v_half := (ch.proj_90_hi - ch.proj_90_lo) / 2;
          bx(2) := v_last_day_n + 90; blo(2) := v_proj_y - v_half; bhi(2) := v_proj_y + v_half;
        END IF;
      END IF;
      v_ymin := 0; v_ymax := 100;
      FOR i IN 1 .. v_cnt LOOP IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF; END LOOP;
      IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
      IF v_nband = 2 AND bhi(2) > v_ymax THEN v_ymax := bhi(2); END IF;
      v_ymax := v_ymax * 1.06;
      FOR a IN (SELECT day_dt, busy_pct FROM capa_cpu_anom WHERE con_dbid = ch.con_dbid AND anomaly_flag IS NOT NULL) LOOP
        v_nanom := v_nanom + 1; ax(v_nanom) := a.day_dt - c_epoch; ay(v_nanom) := a.busy_pct;
      END LOOP;
      v_cross_x := NULL; v_cross_lbl := NULL;
      IF ch.quality = 'OK' AND ch.days_to_sat IS NOT NULL AND ch.days_to_sat <= 90 THEN
        v_cross_x := v_last_day_n + ch.days_to_sat;
        v_cross_lbl := TO_CHAR(cpu_sat, 'FM990') || '% &asymp; ' || dfmt(SYSDATE + ch.days_to_sat);
      END IF;
      chart_svg('Host CPU busy-hour p95 with the daily average, projection and saturation line',
                v_xmin, v_xmax, v_ymin, v_ymax, '%', v_last_day_n,
                NULL, NULL, cpu_sat, 'saturation ' || TO_CHAR(cpu_sat, 'FM990') || '%',
                NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                v_cross_x, cpu_sat, v_cross_lbl, 250);
    END IF;
    p('</div>');  -- .chart-card
  END LOOP;
  p('</div>');  -- .hero-duo
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 1: days-to-full ranking
  ----------------------------------------------------------------------
  p('<section id="s1">');
  p('<h2>1. Days to full <span class="pill pill-crit">CRIT&le;' || dtf_crit
      || '</span> <span class="pill pill-warn">WARN&le;' || dtf_warn || '</span></h2>');
  p('<p class="desc">Which tablespace runs out first, at any fit quality (only OK is a dependable estimate); top ' || top_n
      || '. Uncertainty range and acceleration are in the fold below the table.</p>');

  -- Primary table keeps DB/PDB / Tablespace / a combined Used-limit cell /
  -- Growth / Days to full / Severity / Quality; the 95% band bounds
  -- (dtf_worst/dtf_best) and ACCEL are captured into v_dtf_diag as each row
  -- renders, then walked a second time -- same rows, same order -- for the
  -- collapsed Diagnostics table beneath it (one query, two renderings).
  any_rows := FALSE;
  v_dtf_diag_n := 0;
  FOR r IN (
    SELECT con_dbid,
           db_pdb,
           tablespace_name,
           cur_gb,
           limit_gb,
           pct_used,
           slope_mb,
           days_to_full,
           dtf_worst AS days_to_full_lo,
           dtf_best  AS days_to_full_hi,
           sev_dtf   AS sev,
           quality,
           accel
    FROM   capr_tbspc_days_to_full
    WHERE  days_to_full IS NOT NULL
      AND  rank_dtf <= top_n
    ORDER  BY rank_dtf
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB' || info_icon('which database or container this row belongs to, relevant when one report covers a fleet (CAPR column: DB_PDB)')
        || '</th><th>Tablespace' || info_icon('CAPR column: TABLESPACE_NAME')
        || '</th><th>Used / limit' || info_icon('how much is used against its allocated limit today (CAPR columns: CUR_GB, LIMIT_GB, PCT_USED)')
        || '</th><th class="num">Growth (MiB/day)' || info_icon('the average mebibytes (MiB) this tablespace grows per day (CAPR column: SLOPE_MB)')
        || '</th><th class="num">Days to full' || info_icon('estimated days until it reaches its allocated limit at the current rate (CAPR column: DAYS_TO_FULL)')
        || '</th><th>Severity' || info_icon('how urgent this is: CRIT is within the critical window, WARN within the warning window (CAPR column: SEV_DTF)')
        || '</th><th>Quality' || info_icon('reliability of the estimate -- only OK is a dependable forecast (CAPR column: QUALITY)')
        || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    -- Row id: the attention banner's "View evidence" links for a specific
    -- tablespace jump straight here.
    p('<tr' || row_cls(r.sev) || ' id="' || dtf_row_id(r.con_dbid, r.tablespace_name) || '"><td>' || esc(r.db_pdb)
      || '</td><td>' || esc(r.tablespace_name) || '</td>'
      || '<td>' || used_limit_cell(r.cur_gb, r.limit_gb, r.pct_used,
                        CASE r.sev WHEN 'CRIT' THEN 'crit' WHEN 'WARN' THEN 'warn' ELSE '' END) || '</td>'
      || '<td class="num">' || nz(r.slope_mb, 'FM9999990.000') || '</td>'
      || '<td class="num">' || dtf_cell(r.days_to_full, r.quality, 'FM99999990') || '</td>'
      || '<td>' || sev_pill(r.sev) || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td></tr>');

    v_dtf_diag_n := v_dtf_diag_n + 1;
    v_dtf_diag(v_dtf_diag_n).db_pdb          := r.db_pdb;
    v_dtf_diag(v_dtf_diag_n).tablespace_name := r.tablespace_name;
    v_dtf_diag(v_dtf_diag_n).dtf_lo          := r.days_to_full_lo;
    v_dtf_diag(v_dtf_diag_n).dtf_hi          := r.days_to_full_hi;
    v_dtf_diag(v_dtf_diag_n).accel           := r.accel;
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll

    p('<details class="diag">');
    p('<summary>Uncertainty range and acceleration</summary>');
    p('<div class="diag-body">');
    p('<p class="desc">ACCEL&gt;1.5 = growth accelerating. Fill low / Fill high bracket '
        || 'Days to full with its statistical uncertainty range: earliest and latest credible fill '
        || 'day. A blank Fill high means the range includes "not growing", so it may never '
        || 'fill.</p>');
    p('<div class="tscroll">');
    p('<table class="tbl"><thead><tr>'
      || '<th>DB/PDB</th><th>Tablespace' || info_icon('CAPR column: TABLESPACE_NAME') || '</th>'
      || '<th class="num">Fill low' || info_icon('earliest credible fill day, the low end of the growth-rate uncertainty range (CAPR column: DTF_WORST)')
      || '</th><th class="num">Fill high' || info_icon('latest credible fill day; blank means the range includes not growing at all, i.e. it may never fill (CAPR column: DTF_BEST)')
      || '</th><th class="num">Accel.' || info_icon('above 1.5 means growth is speeding up (CAPR column: ACCEL)') || '</th>'
      || '</tr></thead><tbody>');
    FOR i IN 1 .. v_dtf_diag_n LOOP
      p('<tr><td>' || esc(v_dtf_diag(i).db_pdb) || '</td>'
        || '<td>' || esc(v_dtf_diag(i).tablespace_name) || '</td>'
        || '<td class="num">' || nz(v_dtf_diag(i).dtf_lo, 'FM99999990') || '</td>'
        || '<td class="num">' || nz(v_dtf_diag(i).dtf_hi, 'FM99999990') || '</td>'
        || '<td class="num">' || nz(v_dtf_diag(i).accel, 'FM990.00') || '</td></tr>');
    END LOOP;
    p('</tbody></table>');
    p('</div>');  -- .tscroll
    p('</div>');  -- .diag-body
    p('</details>');
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
    SELECT con_dbid,
           db_pdb,
           tablespace_name,
           cur_gb,
           limit_gb,
           pct_used,
           days_to_full,
           sev_nearfull AS sev,
           quality
    FROM   capr_tbspc_days_to_full
    WHERE  pct_used IS NOT NULL
      AND  rank_nearfull <= top_n
    ORDER  BY rank_nearfull
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Tablespace' || info_icon('CAPR column: TABLESPACE_NAME') || '</th>'
        || '<th>Used / limit' || info_icon('how much is used against its allocated limit today (CAPR columns: CUR_GB, LIMIT_GB, PCT_USED)')
        || '</th><th class="num">Days to full' || info_icon('shown when a usable trend exists; a blank cell explains why there is none (CAPR column: DAYS_TO_FULL)')
        || '</th><th>Severity' || info_icon('graded on percent used, not on the forecast (CAPR column: SEV_NEARFULL)')
        || '</th><th>Quality' || info_icon('the reliability of the trend, for context only -- it does not gate this table (CAPR column: QUALITY)')
        || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    -- Row id: TBSPC_NEARFULL alerts can name a tablespace that never appears
    -- in the days-to-full table above (that one requires a computable
    -- days_to_full; this one does not), so this table needs its own anchor.
    p('<tr' || row_cls(r.sev) || ' id="' || nf_row_id(r.con_dbid, r.tablespace_name) || '"><td>' || esc(r.db_pdb)
      || '</td><td>' || esc(r.tablespace_name) || '</td>'
      || '<td>' || used_limit_cell(r.cur_gb, r.limit_gb, r.pct_used,
                        CASE r.sev WHEN 'CRIT' THEN 'crit' WHEN 'WARN' THEN 'warn' ELSE '' END) || '</td>'
      || '<td class="num">' || dtf_cell(r.days_to_full, r.quality, 'FM99999990') || '</td>'
      || '<td>' || sev_pill(r.sev) || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="empty-note">No tablespaces with a known allocation limit to rank.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 2: tablespace forecast
  ----------------------------------------------------------------------
  p('<section id="s2">');
  -- M7.4: the table below is bounded (is_reportable + rank_report, decided in
  -- CAPR_TBSPC_FORECAST), so say so in the heading -- exactly like the text
  -- report's section 2 header.
  SELECT COUNT(*) INTO v_ts_all FROM capr_tbspc_forecast;
  SELECT COUNT(*) INTO v_ts_shown FROM capr_tbspc_forecast
  WHERE  is_reportable = 'Y' AND rank_report <= top_n;
  v_total_ts := v_ts_all;
  p('<h2>2. Tablespace forecast (GiB) '
      || '<span style="font-weight:400;color:var(--muted);font-size:12px">('
      || v_ts_shown || ' of ' || v_ts_all || ': growing, near-full, or &ge; '
      || RTRIM(TO_CHAR(min_gb, 'FM99999990.999'), '.') || ' GiB, top '
      || top_n || ')</span></h2>');
  p('<p class="desc">Where each tablespace is headed. A card for every one that needs a look, a one-line strip for the '
      || 'quiet ones, then the numbers at +30 / +90 / +180 with the 95% band and the ESM +30 second opinion. '
      || 'Small, flat, half-empty tablespaces are left out of the table (knob report_min_gb); CAPR_TBSPC_FORECAST still has every row.</p>');

  ----------------------------------------------------------------------
  -- Chart grid: history + REGR projection (+180) + ESM+30 point/CI + limit
  -- line + anomaly dots, one card per tablespace, capped at top_n (ordered
  -- by days_to_full NULLS LAST, then name) so a fleet with hundreds of
  -- tablespaces doesn't render hundreds of charts. The legend above this
  -- grid is shared by every chart in the document (this is the first grid
  -- in document order).
  ----------------------------------------------------------------------
  chart_legend;

  ----------------------------------------------------------------------
  -- Chart cards for the tablespaces that need a look (near-full now, a
  -- crossing within a year, or a fit that is erratic / too new to trust);
  -- everything quiet (FLAT, or a crossing more than a year out) goes to the
  -- one-row sparkline strip underneath. Both read CAPR_TBSPC_FORECAST; the
  -- 95% band knots come from CAPF_TBSPC_FORECAST's proj_*_lo/hi columns,
  -- centred on the line the report projects from today's actual value.
  ----------------------------------------------------------------------
  IF v_total_ts = 0 THEN
    p('<div class="empty-note">No tablespace forecast data to chart.</div>');
  ELSE
    v_quiet := 0;
    p('<div class="chart-grid">');
    FOR f IN (
      SELECT r.dbid, r.con_dbid, r.db_pdb, r.tablespace_name, r.cur_bytes, r.limit_bytes, r.slope_bpd, r.quality,
             r.esm30, r.esm30_lo, r.esm30_hi, r.days_to_full, r.r2, r.cur_gb, r.limit_gb, r.rank_chart,
             c.proj_30_lo, c.proj_30_hi, c.proj_90_lo, c.proj_90_hi, c.proj_180_lo, c.proj_180_hi,
             c.proj_365_lo, c.proj_365_hi, c.days_to_full_lo, c.last_day, c.accel_ratio
      FROM   capr_tbspc_forecast r
      LEFT   JOIN capf_tbspc_forecast c
        ON   c.dbid = r.dbid AND c.con_dbid = r.con_dbid AND c.tablespace_name = r.tablespace_name
      WHERE  r.rank_chart <= top_n
        AND  (   (r.limit_gb IS NOT NULL AND r.limit_gb > 0 AND 100 * r.cur_gb / r.limit_gb >= nf_warn)
              OR (r.quality = 'OK' AND r.days_to_full IS NOT NULL AND r.days_to_full <= 365)
              OR  r.quality IN ('LOW_CONFIDENCE', 'INSUFFICIENT_HISTORY'))
      ORDER  BY r.rank_chart
    ) LOOP
      xs.DELETE; ys.DELETE; v_cnt := 0; v_cnt2 := 0; v_nband := 0; v_nanom := 0; v_has_proj := FALSE;
      FOR h IN (SELECT day_dt, used_bytes / 1073741824 AS gb
                FROM   capd_tbspc_daily
                WHERE  dbid = f.dbid AND con_dbid = f.con_dbid AND tablespace_name = f.tablespace_name
                ORDER  BY day_dt) LOOP
        v_cnt := v_cnt + 1;
        xs(v_cnt) := h.day_dt - c_epoch;
        ys(v_cnt) := h.gb;
      END LOOP;

      v_pct := CASE WHEN f.limit_gb > 0 THEN 100 * f.cur_gb / f.limit_gb END;
      v_big := NULL; v_big_lbl := NULL; v_big_cls := NULL; v_accent := NULL;
      IF f.quality = 'OK' AND f.days_to_full IS NOT NULL THEN
        v_big := short_dur(f.days_to_full);
        v_big_lbl := 'to full &middot; ' || CASE WHEN f.days_to_full_lo IS NOT NULL AND f.days_to_full_lo < f.days_to_full
                                                 THEN 'worst ' || TO_CHAR(f.days_to_full_lo, 'FM999990')
                                                 ELSE '&asymp; ' || dfmt(NVL(f.last_day, SYSDATE) + f.days_to_full) END;
        v_big_cls := CASE WHEN f.days_to_full <= dtf_crit THEN 'crit' WHEN f.days_to_full <= dtf_warn THEN 'warn' ELSE 'ok' END;
        v_accent  := CASE WHEN f.days_to_full <= dtf_crit THEN 'crit' WHEN f.days_to_full <= dtf_warn THEN 'warn' END;
      ELSIF v_pct IS NOT NULL AND v_pct >= nf_warn THEN
        v_big := TO_CHAR(v_pct, 'FM990.0') || '%';
        v_big_lbl := 'full now';
        v_big_cls := CASE WHEN v_pct >= nf_crit THEN 'crit' ELSE 'warn' END;
        v_accent  := v_big_cls;
      END IF;
      IF v_pct IS NOT NULL AND v_pct >= nf_warn AND v_accent IS NULL THEN
        v_accent := CASE WHEN v_pct >= nf_crit THEN 'crit' ELSE 'warn' END;
      END IF;
      v_subtitle := CASE WHEN v_con_count > 1 THEN esc(f.db_pdb) || ' &middot; ' END
                    || fmt_size_gb(f.cur_gb) || CASE WHEN f.limit_gb IS NOT NULL THEN ' of ' || fmt_size_gb(f.limit_gb) END
                    || CASE WHEN f.slope_bpd IS NOT NULL AND f.quality <> 'FLAT'
                            THEN ' &middot; ' || CASE WHEN f.slope_bpd < 0 THEN '&minus;' END || fmt_rate_mb(ABS(f.slope_bpd) / 1048576) END
                    || CASE WHEN f.accel_ratio >= 1.5 THEN ' &middot; accelerating &times;' || TO_CHAR(f.accel_ratio, 'FM990.0') END
                    || CASE WHEN f.r2 IS NOT NULL AND f.quality IN ('OK','LOW_CONFIDENCE') THEN ' &middot; R2 ' || TO_CHAR(f.r2, 'FM0.00') END;
      card_open(esc(f.tablespace_name) || ' ' || quality_pill(f.quality), v_subtitle, v_big, v_big_lbl, v_big_cls, v_accent, NULL);

      IF v_cnt = 0 THEN
        p('<div class="empty-note">No daily history collected yet for this tablespace.</div>');
      ELSE
        v_last_day_n := xs(v_cnt);
        v_xmin := xs(1); v_xmax := v_last_day_n; v_proj_y := NULL;
        v_horizon := CASE WHEN f.days_to_full > 180 AND f.days_to_full <= 365 THEN 365 ELSE 180 END;
        IF f.quality = 'OK' AND f.slope_bpd IS NOT NULL THEN
          v_proj_y := ys(v_cnt) + (f.slope_bpd / 1073741824) * v_horizon;
          v_xmax   := v_last_day_n + v_horizon;
          px1(1) := v_last_day_n; py1(1) := ys(v_cnt);
          px1(2) := v_xmax;       py1(2) := v_proj_y;
          v_has_proj := TRUE;
          IF f.proj_30_lo IS NOT NULL THEN
            v_nband := 0;
            v_half := (f.proj_30_hi - f.proj_30_lo) / 2 / 1073741824;
            v_nband := v_nband + 1; bx(v_nband) := v_last_day_n + 30;
            blo(v_nband) := ys(v_cnt) + (f.slope_bpd / 1073741824) * 30 - v_half; bhi(v_nband) := blo(v_nband) + 2 * v_half;
            v_half := (f.proj_90_hi - f.proj_90_lo) / 2 / 1073741824;
            v_nband := v_nband + 1; bx(v_nband) := v_last_day_n + 90;
            blo(v_nband) := ys(v_cnt) + (f.slope_bpd / 1073741824) * 90 - v_half; bhi(v_nband) := blo(v_nband) + 2 * v_half;
            v_half := (f.proj_180_hi - f.proj_180_lo) / 2 / 1073741824;
            v_nband := v_nband + 1; bx(v_nband) := v_last_day_n + 180;
            blo(v_nband) := ys(v_cnt) + (f.slope_bpd / 1073741824) * 180 - v_half; bhi(v_nband) := blo(v_nband) + 2 * v_half;
            IF v_horizon = 365 AND f.proj_365_lo IS NOT NULL THEN
              v_half := (f.proj_365_hi - f.proj_365_lo) / 2 / 1073741824;
              v_nband := v_nband + 1; bx(v_nband) := v_last_day_n + 365;
              blo(v_nband) := v_proj_y - v_half; bhi(v_nband) := v_proj_y + v_half;
            END IF;
          END IF;
        END IF;
        v_esm_val := f.esm30; v_esm_lo := f.esm30_lo; v_esm_hi := f.esm30_hi;
        IF v_esm_val IS NOT NULL THEN v_xmax := GREATEST(v_xmax, v_last_day_n + 30); END IF;

        v_ymin := 0; v_ymax := ys(1);
        FOR i IN 1 .. v_cnt LOOP IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF; END LOOP;
        IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
        FOR i IN 1 .. v_nband LOOP IF bhi(i) > v_ymax THEN v_ymax := bhi(i); END IF; END LOOP;
        IF v_esm_hi IS NOT NULL AND v_esm_hi > v_ymax THEN v_ymax := v_esm_hi; END IF;
        IF (v_ymax - v_ymin) < 1 THEN v_ymax := v_ymin + 1; END IF;
        v_limit_gb   := f.limit_bytes / 1073741824;
        v_range      := v_ymax - v_ymin;
        v_show_limit := (v_limit_gb IS NOT NULL) AND (v_limit_gb - v_ymax) <= 3 * v_range;
        IF v_show_limit THEN v_ymax := GREATEST(v_ymax, v_limit_gb * 1.04); END IF;
        v_ymax := v_ymax + (v_ymax - v_ymin) * 0.10;
        -- a band or ESM interval far below zero would waste the scale
        FOR i IN 1 .. v_nband LOOP blo(i) := GREATEST(blo(i), 0); END LOOP;
        IF v_esm_lo IS NOT NULL THEN v_esm_lo := GREATEST(v_esm_lo, 0); END IF;

        FOR a IN (SELECT an.day_dt, d.used_bytes / 1073741824 AS gb
                  FROM   capa_tbspc_anom an
                  JOIN   capd_tbspc_daily d
                    ON   d.dbid = an.dbid AND d.con_dbid = an.con_dbid
                   AND   d.tablespace_name = an.tablespace_name AND d.day_dt = an.day_dt
                  WHERE  an.dbid = f.dbid AND an.con_dbid = f.con_dbid
                    AND  an.tablespace_name = f.tablespace_name
                    AND  an.anomaly_flag IS NOT NULL) LOOP
          v_nanom := v_nanom + 1; ax(v_nanom) := a.day_dt - c_epoch; ay(v_nanom) := a.gb;
        END LOOP;
        v_cross_x := NULL; v_cross_lbl := NULL;
        IF v_show_limit AND f.quality = 'OK' AND f.days_to_full IS NOT NULL AND f.days_to_full <= v_horizon THEN
          v_cross_x := v_last_day_n + f.days_to_full;
          v_cross_lbl := 'full &asymp; ' || dfmt(NVL(f.last_day, SYSDATE) + f.days_to_full);
        END IF;
        chart_svg(esc(f.tablespace_name) || ' growth: history, projection with its 95 percent band, and the allocated limit',
                  v_xmin, v_xmax, v_ymin, v_ymax, 'GiB', v_last_day_n,
                  CASE WHEN v_show_limit THEN v_limit_gb END,
                  CASE WHEN v_show_limit THEN 'ceiling ' || fmt_size_gb(v_limit_gb) END,
                  NULL, NULL,
                  CASE WHEN v_esm_val IS NOT NULL THEN v_last_day_n + 30 END, v_esm_val, v_esm_lo, v_esm_hi,
                  NULL, NULL, NULL,
                  v_cross_x, CASE WHEN v_show_limit THEN v_limit_gb END, v_cross_lbl);
        IF v_limit_gb IS NOT NULL AND NOT v_show_limit THEN
          p('<div class="chart-sub">ceiling hidden: ' || fmt_size_gb(v_limit_gb) || ' is off the chart scale</div>');
        END IF;
      END IF;
      p('</div>');  -- .chart-card
    END LOOP;
    p('</div>');  -- .chart-grid

    -- Quiet strip: one row per tablespace not charted above.
    FOR f IN (
      SELECT r.dbid, r.con_dbid, r.db_pdb, r.tablespace_name, r.quality, r.days_to_full, r.cur_gb, r.limit_gb, r.slope_bpd
      FROM   capr_tbspc_forecast r
      WHERE  NOT (r.rank_chart <= top_n
                  AND (   (r.limit_gb IS NOT NULL AND r.limit_gb > 0 AND 100 * r.cur_gb / r.limit_gb >= nf_warn)
                       OR (r.quality = 'OK' AND r.days_to_full IS NOT NULL AND r.days_to_full <= 365)
                       OR  r.quality IN ('LOW_CONFIDENCE', 'INSUFFICIENT_HISTORY')))
      ORDER  BY CASE WHEN r.quality = 'OK' AND r.days_to_full IS NOT NULL THEN 0 ELSE 1 END, r.days_to_full, r.cur_gb DESC
      FETCH FIRST 60 ROWS ONLY
    ) LOOP
      v_quiet := v_quiet + 1;
      IF v_quiet = 1 THEN
        p('<div class="quiet"><div class="qh">Quiet tablespaces: flat, or more than a year from their ceiling. '
          || 'History only, drawn to each one''s own scale.</div>');
      END IF;
      xs.DELETE; ys.DELETE; v_cnt := 0;
      FOR h IN (SELECT day_dt, used_bytes / 1073741824 AS gb FROM capd_tbspc_daily
                WHERE dbid = f.dbid AND con_dbid = f.con_dbid AND tablespace_name = f.tablespace_name ORDER BY day_dt) LOOP
        v_cnt := v_cnt + 1; xs(v_cnt) := h.day_dt - c_epoch; ys(v_cnt) := h.gb;
      END LOOP;
      v_pct := CASE WHEN f.limit_gb > 0 THEN 100 * f.cur_gb / f.limit_gb END;
      p('<div class="qrow"><div>' || con_prefix(f.db_pdb) || esc(f.tablespace_name) || ' ' || quality_pill(f.quality) || '</div>');
      IF v_cnt >= 2 THEN spark_svg; ELSE p('<div></div>'); END IF;
      p('<div class="q">' || fmt_size_gb(f.cur_gb) || CASE WHEN f.limit_gb IS NOT NULL THEN ' / ' || fmt_size_gb(f.limit_gb) END || '</div>'
        || '<div class="q">' || CASE WHEN v_pct IS NOT NULL THEN TO_CHAR(v_pct, 'FM990') || '%' ELSE '&ndash;' END || '</div>'
        || '<div class="q qd">' || CASE WHEN f.quality = 'OK' AND f.days_to_full IS NOT NULL THEN 'full in ' || short_dur(f.days_to_full)
                                        WHEN f.quality = 'FLAT' THEN 'flat'
                                        WHEN f.quality = 'OK' THEN 'not filling'
                                        ELSE '&ndash;' END || '</div></div>');
    END LOOP;
    IF v_quiet > 0 THEN p('</div>'); END IF;
  END IF;

  any_rows := FALSE;
  FOR r IN (
    SELECT db_pdb,
           tablespace_name,
           train_n AS n,
           cur_gb,
           p30,
           p90,
           p180,
           p180_lo,
           p180_hi,
           r2,
           quality,
           esm30
    FROM   capr_tbspc_forecast
    WHERE  is_reportable = 'Y'
      AND  rank_report <= top_n
    ORDER  BY rank_report
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Tablespace' || info_icon('CAPR column: TABLESPACE_NAME') || '</th>'
        || '<th class="num">Train days' || info_icon('how many days of history the estimate is based on -- more is better (CAPR column: TRAIN_N)')
        || '</th><th class="num">Current (GiB)' || info_icon('CAPR column: CUR_GB') || '</th>'
        || '<th class="num">+30d (GiB)' || info_icon('CAPR column: P30')
        || '</th><th class="num">+90d (GiB)' || info_icon('CAPR column: P90')
        || '</th><th class="num">+180d (GiB)' || info_icon('CAPR column: P180')
        || '</th><th class="num">180d low' || info_icon('CAPR column: P180_LO')
        || '</th><th class="num">180d high'
        || info_icon('95% prediction band on the +180-day projection; the actual value should land between low and high 95 times out of 100 if growth stays like the recent past (CAPR column: P180_HI)')
        || '</th><th class="num">R2' || info_icon('how closely growth follows a straight line: 1.00 = perfectly steady, near 0 = erratic')
        || '</th><th>Quality' || info_icon('our own reliability grade for this estimate -- hover the colored labels below (CAPR column: QUALITY)')
        || '</th><th class="num">ESM +30 (GiB)' || info_icon('a second, machine-learning estimate of the size 30 days from now -- usually the most accurate short-term number when present (CAPR column: ESM30)')
        || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(r.db_pdb) || '</td><td>' || esc(r.tablespace_name) || '</td>'
      || '<td class="num">' || nz(r.n, 'FM9990') || '</td>'
      || '<td class="num">' || nz(r.cur_gb) || '</td>'
      || '<td class="num">' || nz(r.p30) || '</td>'
      || '<td class="num">' || nz(r.p90) || '</td>'
      || '<td class="num">' || nz(r.p180) || '</td>'
      || '<td class="num">' || nz(r.p180_lo) || '</td>'
      || '<td class="num">' || nz(r.p180_hi) || '</td>'
      || '<td class="num">' || nz(r.r2, 'FM90.000') || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td>'
      || '<td class="num">' || CASE WHEN r.esm30 IS NULL
                                    THEN '<span class="na">no model</span>'
                                    ELSE nz(r.esm30) END || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="empty-note">No tablespace forecast rows found.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 3: tablespace growth anomalies
  ----------------------------------------------------------------------
  p('<section id="s3">');
  p('<h2>3. Unusual tablespace days <span style="font-weight:400;color:var(--muted);font-size:12px">(last '
      || anomaly_days || ' days)</span></h2>');
  p('<p class="desc">Days when a tablespace grew or shrank much faster than its own normal pace. One strip per '
      || 'series: red = grew, blue = shrank, bigger = further outside normal. The numbers behind every dot are in the fold.</p>');

  SELECT MAX(day_dt) INTO v_win_hi FROM capd_tbspc_daily;
  v_strip_n := 0;
  IF v_win_hi IS NOT NULL THEN
    v_win_lo := v_win_hi - anomaly_days;
    v_xmin := v_win_lo - c_epoch; v_xmax := v_win_hi - c_epoch;
    FOR ln IN (
      SELECT con_dbid, tablespace_name, db_pdb, COUNT(*) AS n_all,
             SUM(CASE WHEN anomaly_flag = 'HIGH' THEN 1 ELSE 0 END) AS n_hi,
             SUM(CASE WHEN anomaly_flag = 'LOW'  THEN 1 ELSE 0 END) AS n_lo,
             MAX(ABS(delta_mb)) AS max_delta, MAX(ABS(z)) AS max_z
      FROM   capr_tbspc_anomalies
      WHERE  days_ago < anomaly_days
      GROUP  BY con_dbid, tablespace_name, db_pdb
      ORDER  BY n_all DESC, max_z DESC, tablespace_name
      FETCH FIRST 16 ROWS ONLY
    ) LOOP
      v_strip_n := v_strip_n + 1;
      IF v_strip_n = 1 THEN p('<div class="strips">'); END IF;
      p('<div class="strip"><div class="sl"><b>' || esc(ln.tablespace_name) || '</b>'
        || CASE WHEN v_con_count > 1 THEN ' <span class="dim">' || esc(ln.db_pdb) || '</span>' END
        || '<span>' || CASE WHEN ln.n_hi > 0 THEN TO_CHAR(ln.n_hi, 'FM990') || ' day' || CASE WHEN ln.n_hi = 1 THEN '' ELSE 's' END || ' up' END
        || CASE WHEN ln.n_hi > 0 AND ln.n_lo > 0 THEN ' &middot; ' END
        || CASE WHEN ln.n_lo > 0 THEN TO_CHAR(ln.n_lo, 'FM990') || ' day' || CASE WHEN ln.n_lo = 1 THEN '' ELSE 's' END || ' down' END
        || ' &middot; biggest ' || fmt_size_gb(ln.max_delta / 1024) || '</span></div>');
      strip_open(v_xmin, v_xmax);
      FOR a IN (SELECT day_dt, day_str, delta_mb, rate_mb, med_mb, z, anomaly_flag
                FROM capr_tbspc_anomalies
                WHERE con_dbid = ln.con_dbid AND tablespace_name = ln.tablespace_name AND days_ago < anomaly_days) LOOP
        v_tip := a.day_str || ': ' || CASE WHEN a.delta_mb >= 0 THEN 'grew ' ELSE 'shrank ' END
                 || fmt_size_gb(ABS(a.delta_mb) / 1024) || ' (usual ' || fmt_size_gb(NVL(a.med_mb, 0) / 1024) || '/day), robust z '
                 || TO_CHAR(a.z, 'FM99990.0');
        p('<circle class="' || CASE WHEN a.anomaly_flag = 'HIGH' THEN 'sd-hi' ELSE 'sd-lo' END
          || '" cx="' || fmt_px(lin(a.day_dt - c_epoch, v_xmin, v_xmax, 4, 596)) || '" cy="15" r="'
          || fmt_px(3.5 + LEAST(4, ABS(NVL(a.z, 0)) / 6)) || '"><title>' || esc(v_tip) || '</title></circle>');
      END LOOP;
      p('</svg></div>');
    END LOOP;
    IF v_strip_n > 0 THEN
      p('<div class="strip-axis"><div></div><div><span>' || dfmt(v_win_lo + 1) || '</span><span>'
        || dfmt(v_win_lo + FLOOR(anomaly_days / 2)) || '</span><span>' || dfmt(v_win_hi) || '</span></div></div>');
      p('</div>');  -- .strips
    END IF;
  END IF;

  any_rows := FALSE;
  FOR r IN (
    SELECT db_pdb, tablespace_name, day_str AS day_dt, gap, delta_mb, rate_mb, med_mb, thr_mb, z, anomaly_flag
    FROM   capr_tbspc_anomalies
    WHERE  days_ago < anomaly_days
    ORDER  BY con_dbid, tablespace_name, days_ago
  ) LOOP
    IF NOT any_rows THEN
      p('<details class="fold"><summary>The numbers behind every dot</summary><div class="fold-body">');
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Tablespace' || info_icon('CAPR column: TABLESPACE_NAME')
        || '</th><th>Day' || info_icon('CAPR column: DAY_DT')
        || '</th><th class="num">Gap' || info_icon('days since the previous sample -- a big gap can inflate a one-day change (CAPR column: GAP)')
        || '</th><th class="num">Delta (MiB)' || info_icon('CAPR column: DELTA_MB')
        || '</th><th class="num">Rate (MiB/day)' || info_icon('how fast it grew that day, in mebibytes (MiB) per day (CAPR column: RATE_MB)')
        || '</th><th class="num">Median (MiB/day)' || info_icon('its usual daily growth rate over the recent baseline window (CAPR column: MED_MB)')
        || '</th><th class="num">Threshold (MiB/day)' || info_icon('how far from usual a day must be before it is flagged (CAPR column: THR_MB)')
        || '</th><th class="num">Robust z' || info_icon('how far outside its normal range this day was -- 3 or more is clearly unusual (CAPR column: Z)')
        || '</th><th>Flag' || info_icon('the direction of the flagged change for this day (CAPR column: ANOMALY_FLAG)') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(r.db_pdb) || '</td><td>' || esc(r.tablespace_name) || '</td><td style="white-space:nowrap">' || r.day_dt || '</td>'
      || '<td class="num">' || nz(r.gap, 'FM990') || '</td>'
      || '<td class="num">' || nz(r.delta_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.rate_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.med_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.thr_mb, 'FM9999990.0') || '</td>'
      || '<td class="num' || (CASE WHEN ABS(NVL(r.z,0)) >= 3 THEN ' z-hi' ELSE '' END) || '">'
         || nz(r.z, 'FM99990.0') || '</td>'
      || '<td class="' || CASE WHEN r.anomaly_flag = 'HIGH' THEN 'sev-crit' ELSE 'sev-ok' END || '">' || esc(r.anomaly_flag) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div></div></details>');
  ELSE
    p('<div class="glance-ok">No unusual tablespace days in the last ' || TO_CHAR(anomaly_days, 'FM999990') || ' days.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 4: CPU trend
  ----------------------------------------------------------------------
  p('<section id="s4">');
  p('<h2>4. CPU trend</h2>');
  p('<p class="desc">How busy the host has been and when it runs out of headroom. The busy-hour p95 is what '
      || 'saturates; each container''s DB CPU is shown as a share of the host''s cores, with any sustained level '
      || 'shift shaded. The table has every metric, including the daily average and peak window.</p>');

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

      -- ---- Host busy% card: only where the container owns host OSSTAT ----
      xs.DELETE; ys.DELETE; xs2.DELETE; ys2.DELETE; v_cnt := 0; v_cnt2 := 0; v_nband := 0; v_nanom := 0; v_has_proj := FALSE;
      FOR h IN (SELECT day_dt, busy_pct, busy_p95 FROM capd_cpu_daily
                WHERE con_dbid = cd.con_dbid ORDER BY day_dt) LOOP
        v_cnt := v_cnt + 1;  xs(v_cnt) := h.day_dt - c_epoch;  ys(v_cnt) := NVL(h.busy_p95, h.busy_pct);
        v_cnt2 := v_cnt2 + 1; xs2(v_cnt2) := h.day_dt - c_epoch; ys2(v_cnt2) := h.busy_pct;
      END LOOP;
      IF v_cnt > 0 THEN
        v_quality := NULL; v_slope := NULL; v_dtf := NULL; v_n := NULL;
        v_big := NULL; v_big_lbl := NULL; v_big_cls := NULL; v_accent := NULL;
        FOR t IN (SELECT t.slope_per_day, t.quality, t.days_to_sat, t.sat_worst, t.sat_best, t.r2, t.cur_val,
                         f.proj_30_lo, f.proj_30_hi, f.proj_90_lo, f.proj_90_hi
                  FROM capr_cpu_trend t
                  LEFT JOIN capf_cpu_trend f ON f.dbid = t.dbid AND f.con_dbid = t.con_dbid AND f.metric = t.metric
                  WHERE t.con_dbid = cd.con_dbid AND t.metric = 'BUSY_P95'
                  ORDER BY t.dbid FETCH FIRST 1 ROW ONLY) LOOP
          v_quality := t.quality; v_slope := t.slope_per_day; v_dtf := t.days_to_sat; v_n := t.r2;
          IF t.quality = 'OK' AND t.days_to_sat IS NOT NULL THEN
            v_big := short_dur(t.days_to_sat);
            v_big_lbl := 'to ' || TO_CHAR(cpu_sat, 'FM990') || '% &middot; '
                         || CASE WHEN t.sat_worst IS NOT NULL THEN TO_CHAR(t.sat_worst, 'FM999990') || '&ndash;' || NVL(TO_CHAR(t.sat_best, 'FM999990'), 'never')
                                 ELSE '&asymp; ' || dfmt(SYSDATE + t.days_to_sat) END;
            v_big_cls := CASE WHEN t.days_to_sat <= dtf_crit THEN 'crit' WHEN t.days_to_sat <= dtf_warn THEN 'warn' ELSE 'ok' END;
            v_accent  := CASE WHEN t.days_to_sat <= dtf_crit THEN 'crit' WHEN t.days_to_sat <= dtf_warn THEN 'warn' END;
          END IF;
          IF t.proj_30_lo IS NOT NULL AND t.proj_90_lo IS NOT NULL AND t.quality = 'OK' THEN
            v_nband := 2;
            v_half := (t.proj_30_hi - t.proj_30_lo) / 2;
            bx(1) := xs(v_cnt) + 30; blo(1) := ys(v_cnt) + t.slope_per_day * 30 - v_half; bhi(1) := blo(1) + 2 * v_half;
            v_half := (t.proj_90_hi - t.proj_90_lo) / 2;
            bx(2) := xs(v_cnt) + 90; blo(2) := ys(v_cnt) + t.slope_per_day * 90 - v_half; bhi(2) := blo(2) + 2 * v_half;
          END IF;
        END LOOP;
        card_open('Host CPU busy-hour p95 <span class="dim" style="font-weight:400">' || esc(db_label(NULL, cd.con_dbid)) || '</span> '
                  || CASE WHEN v_quality IS NOT NULL THEN quality_pill(v_quality) END,
                  'p95 of the day''s hourly intervals, what actually saturates &middot; faint line = daily average'
                  || CASE WHEN v_n IS NOT NULL THEN ' &middot; R2 ' || TO_CHAR(v_n, 'FM0.00') END,
                  v_big, v_big_lbl, v_big_cls, v_accent, NULL);
        v_xmin := xs(1); v_xmax := xs(v_cnt); v_last_day_n := xs(v_cnt); v_proj_y := NULL;
        IF v_quality = 'OK' AND v_slope IS NOT NULL THEN
          v_proj_y := ys(v_cnt) + v_slope * 90;
          v_xmax   := v_last_day_n + 90;
          px1(1) := v_last_day_n; py1(1) := ys(v_cnt);
          px1(2) := v_xmax;       py1(2) := v_proj_y;
          v_has_proj := TRUE;
        ELSE
          v_nband := 0;
        END IF;
        v_ymin := 0; v_ymax := 100;
        FOR i IN 1 .. v_cnt LOOP IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF; END LOOP;
        IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
        FOR i IN 1 .. v_nband LOOP IF bhi(i) > v_ymax THEN v_ymax := bhi(i); END IF; END LOOP;
        v_ymax := v_ymax * 1.06;
        FOR a IN (SELECT day_dt, busy_pct FROM capa_cpu_anom WHERE con_dbid = cd.con_dbid AND anomaly_flag IS NOT NULL) LOOP
          v_nanom := v_nanom + 1; ax(v_nanom) := a.day_dt - c_epoch; ay(v_nanom) := a.busy_pct;
        END LOOP;
        v_cross_x := NULL; v_cross_lbl := NULL;
        IF v_quality = 'OK' AND v_dtf IS NOT NULL AND v_dtf <= 90 THEN
          v_cross_x := v_last_day_n + v_dtf;
          v_cross_lbl := TO_CHAR(cpu_sat, 'FM990') || '% &asymp; ' || dfmt(SYSDATE + v_dtf);
        END IF;
        chart_svg('Host CPU busy-hour p95 for ' || esc(db_label(NULL, cd.con_dbid)) || ' with projection and saturation line',
                  v_xmin, v_xmax, v_ymin, v_ymax, '%', v_last_day_n,
                  NULL, NULL, cpu_sat, 'saturation ' || TO_CHAR(cpu_sat, 'FM990') || '%',
                  NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                  v_cross_x, cpu_sat, v_cross_lbl);
        p('</div>');
      END IF;

      -- ---- DB CPU as % of host cores: comparable to the busy% chart, and the
      --      metric CAPA_CPU_SHIFT scores, so a sustained step is shaded here ----
      xs.DELETE; ys.DELETE; xs2.DELETE; ys2.DELETE; v_cnt := 0; v_cnt2 := 0; v_nband := 0; v_nanom := 0; v_has_proj := FALSE;
      FOR h IN (SELECT day_dt, db_cpu_pct FROM capd_dbtime_daily
                WHERE con_dbid = cd.con_dbid AND db_cpu_pct IS NOT NULL ORDER BY day_dt) LOOP
        v_cnt := v_cnt + 1; xs(v_cnt) := h.day_dt - c_epoch; ys(v_cnt) := h.db_cpu_pct;
      END LOOP;
      IF v_cnt > 0 THEN
        v_quality := NULL; v_slope := NULL; v_dtf := NULL; v_n := NULL;
        v_big := NULL; v_big_lbl := NULL; v_big_cls := NULL; v_accent := NULL;
        v_shift_from := NULL; v_shift_to := NULL; v_shift_lbl := NULL;
        FOR t IN (SELECT slope_per_day, quality, days_to_sat, r2 FROM capr_cpu_trend
                  WHERE con_dbid = cd.con_dbid AND metric = 'DB_CPU_PCT'
                  ORDER BY dbid FETCH FIRST 1 ROW ONLY) LOOP
          v_quality := t.quality; v_slope := t.slope_per_day; v_dtf := t.days_to_sat; v_n := t.r2;
        END LOOP;
        FOR s IN (SELECT last_day, recent_days, shift_pct, shift_flag, sev FROM capr_cpu_shifts
                  WHERE con_dbid = cd.con_dbid AND metric = 'DB_CPU_PCT' AND shift_flag IS NOT NULL
                  ORDER BY rank_shift FETCH FIRST 1 ROW ONLY) LOOP
          v_shift_from := (s.last_day - s.recent_days + 1) - c_epoch;
          v_shift_to   := s.last_day - c_epoch;
          v_shift_lbl  := CASE WHEN s.shift_pct >= 0 THEN '+' END || TO_CHAR(s.shift_pct, 'FM9990.0') || ' pts since '
                          || dfmt(s.last_day - s.recent_days + 1);
          v_big := CASE WHEN s.shift_pct >= 0 THEN '+' END || TO_CHAR(s.shift_pct, 'FM9990.0');
          v_big_lbl := 'pts, sustained ' || LOWER(s.shift_flag);
          v_big_cls := CASE WHEN s.sev = 'WARN' THEN 'warn' ELSE 'muted' END;
          v_accent  := CASE WHEN s.sev = 'WARN' THEN 'warn' END;
        END LOOP;
        IF v_big IS NULL AND v_quality = 'OK' AND v_dtf IS NOT NULL AND v_dtf <= 365 THEN
          v_big := short_dur(v_dtf); v_big_lbl := 'to ' || TO_CHAR(cpu_sat, 'FM990') || '% of cores';
          v_big_cls := CASE WHEN v_dtf <= dtf_crit THEN 'crit' WHEN v_dtf <= dtf_warn THEN 'warn' ELSE 'ok' END;
          v_accent  := CASE WHEN v_dtf <= dtf_crit THEN 'crit' WHEN v_dtf <= dtf_warn THEN 'warn' END;
        END IF;
        card_open('DB CPU, % of host cores <span class="dim" style="font-weight:400">' || esc(db_label(NULL, cd.con_dbid)) || '</span> '
                  || CASE WHEN v_shift_lbl IS NOT NULL THEN '<span class="pill pill-warn">SHIFT</span> ' END
                  || CASE WHEN v_quality IS NOT NULL THEN quality_pill(v_quality) END,
                  'this container''s DB CPU seconds as a share of the host''s core capacity, daily'
                  || CASE WHEN v_n IS NOT NULL THEN ' &middot; R2 ' || TO_CHAR(v_n, 'FM0.00') END
                  || CASE WHEN v_shift_lbl IS NOT NULL AND v_quality = 'LOW_CONFIDENCE' THEN ' (the step breaks the straight-line fit)' END,
                  v_big, v_big_lbl, v_big_cls, v_accent, NULL);
        v_xmin := xs(1); v_xmax := xs(v_cnt); v_last_day_n := xs(v_cnt); v_proj_y := NULL;
        IF v_quality = 'OK' AND v_slope IS NOT NULL THEN
          v_proj_y := ys(v_cnt) + v_slope * 90;
          v_xmax   := v_last_day_n + 90;
          px1(1) := v_last_day_n; py1(1) := ys(v_cnt);
          px1(2) := v_xmax;       py1(2) := v_proj_y;
          v_has_proj := TRUE;
        END IF;
        v_ymin := 0; v_ymax := 0;
        FOR i IN 1 .. v_cnt LOOP IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF; END LOOP;
        IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
        -- keep the saturation line in view when the series is within reach of it
        IF v_ymax >= cpu_sat * 0.35 THEN v_ymax := GREATEST(v_ymax, cpu_sat); END IF;
        IF v_ymax < 1 THEN v_ymax := 1; END IF;
        v_ymax := v_ymax * 1.08;
        chart_svg('DB CPU as a percent of host cores for ' || esc(db_label(NULL, cd.con_dbid))
                  || CASE WHEN v_shift_lbl IS NOT NULL THEN ', with the sustained level shift shaded' END,
                  v_xmin, v_xmax, v_ymin, v_ymax, '%', v_last_day_n,
                  NULL, NULL,
                  CASE WHEN v_ymax >= cpu_sat THEN cpu_sat END,
                  CASE WHEN v_ymax >= cpu_sat THEN 'saturation ' || TO_CHAR(cpu_sat, 'FM990') || '%' END,
                  NULL, NULL, NULL, NULL,
                  v_shift_from, v_shift_to, v_shift_lbl,
                  NULL, NULL, NULL);
        p('</div>');
      END IF;
    END LOOP;
    p('</div>');
  END IF;

  any_rows := FALSE;
  FOR r IN (
    SELECT db_pdb,
           metric,
           train_n       AS n,
           cur_val,
           slope_per_day AS slope_day,
           r2,
           days_to_sat   AS days_sat,
           sat_worst,
           sat_best,
           quality
    FROM   capr_cpu_trend
    ORDER  BY con_dbid, metric
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Metric' || info_icon('CAPR column: METRIC')
        || '</th><th class="num">Train days' || info_icon('CAPR column: TRAIN_N')
        || '</th><th>Fill' || info_icon('CAPR column: CUR_VAL')
        || '</th><th class="num">Current' || info_icon('CAPR column: CUR_VAL')
        || '</th><th class="num">Slope/day' || info_icon('how much this metric moves per day on average (CAPR column: SLOPE_DAY)')
        || '</th><th class="num">R2</th>'
        || '<th class="num">Days to saturation' || info_icon('estimated days until this metric reaches the saturation threshold (none for DB_CPU_SEC, which has no ceiling) (CAPR column: DAYS_SAT)')
        || '</th><th class="num">Range' || info_icon('worst-to-best case days-to-saturation from the statistical uncertainty of the trend; never = it may not saturate at the slow end (CAPR columns: SAT_WORST, SAT_BEST)')
        || '</th><th>Quality' || info_icon('CAPR column: QUALITY') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(r.db_pdb) || '</td><td>' || esc(r.metric) || '</td>'
      || '<td class="num">' || nz(r.n, 'FM9990') || '</td>'
      || '<td>' || CASE WHEN r.metric <> 'DB_CPU_SEC' THEN bar(r.cur_val,
                     CASE WHEN r.cur_val >= cpu_sat THEN 'crit'
                          WHEN r.cur_val >= cpu_sat * 0.75 THEN 'warn' ELSE '' END)
                   ELSE '&ndash;' END || '</td>'
      || '<td class="num">' || nz(r.cur_val, 'FM99999990.00') || '</td>'
      || '<td class="num">' || nz(r.slope_day, 'FM9999990.0000') || '</td>'
      || '<td class="num">' || nz(r.r2, 'FM90.000') || '</td>'
      || '<td class="num' || (CASE WHEN r.days_sat IS NOT NULL AND r.days_sat <= dtf_warn THEN ' sev-warn' END)
         || '">' || dtf_cell(r.days_sat, r.quality, 'FM99999990', TRUE) || '</td>'
      || '<td class="num">'
      || CASE WHEN r.sat_worst IS NULL THEN '&ndash;'
              WHEN r.sat_worst > 365 THEN '<span class="na">&gt; 1 year</span>'
              ELSE TO_CHAR(r.sat_worst, 'FM99999990') || '&ndash;'
                   || NVL(TO_CHAR(r.sat_best, 'FM99999990'), 'never') END || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="empty-note">No CPU trend rows found.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 5: CPU anomalies
  ----------------------------------------------------------------------
  p('<section id="s5">');
  p('<h2>5. Unusual CPU days <span style="font-weight:400;color:var(--muted);font-size:12px">'
      || 'vs the same weekday, last ' || anomaly_days || ' days</span></h2>');
  p('<p class="desc">Days when the host was much busier (red) or quieter (blue) than it usually is on that weekday, '
      || 'then the sustained level shifts a single-day test cannot see.</p>');

  SELECT MAX(day_dt) INTO v_win_hi FROM capd_cpu_daily;
  v_strip_n := 0;
  IF v_win_hi IS NOT NULL THEN
    v_win_lo := v_win_hi - anomaly_days;
    v_xmin := v_win_lo - c_epoch; v_xmax := v_win_hi - c_epoch;
    FOR ln IN (
      SELECT con_dbid, db_pdb, COUNT(*) AS n_all,
             SUM(CASE WHEN anomaly_flag = 'HIGH' THEN 1 ELSE 0 END) AS n_hi,
             SUM(CASE WHEN anomaly_flag = 'LOW'  THEN 1 ELSE 0 END) AS n_lo,
             MAX(busy_pct) AS max_busy
      FROM   capr_cpu_anomalies
      WHERE  days_ago < anomaly_days
      GROUP  BY con_dbid, db_pdb
      ORDER  BY n_all DESC, con_dbid
    ) LOOP
      v_strip_n := v_strip_n + 1;
      IF v_strip_n = 1 THEN p('<div class="strips">'); END IF;
      p('<div class="strip"><div class="sl"><b>Host CPU</b>' || CASE WHEN v_con_count > 1 THEN ' <span class="dim">' || esc(ln.db_pdb) || '</span>' END
        || '<span>' || CASE WHEN ln.n_hi > 0 THEN TO_CHAR(ln.n_hi, 'FM990') || ' busier' END
        || CASE WHEN ln.n_hi > 0 AND ln.n_lo > 0 THEN ' &middot; ' END
        || CASE WHEN ln.n_lo > 0 THEN TO_CHAR(ln.n_lo, 'FM990') || ' quieter' END
        || ' &middot; busiest ' || TO_CHAR(ln.max_busy, 'FM990') || '%</span></div>');
      strip_open(v_xmin, v_xmax);
      FOR a IN (SELECT day_dt, day_str, busy_pct, median_pct, z, anomaly_flag FROM capr_cpu_anomalies
                WHERE con_dbid = ln.con_dbid AND days_ago < anomaly_days) LOOP
        v_tip := a.day_str || ': ' || TO_CHAR(a.busy_pct, 'FM990') || '% busy vs the usual '
                 || TO_CHAR(a.median_pct, 'FM990') || '% for that weekday, robust z ' || TO_CHAR(a.z, 'FM99990.0');
        p('<circle class="' || CASE WHEN a.anomaly_flag = 'HIGH' THEN 'sd-hi' ELSE 'sd-lo' END
          || '" cx="' || fmt_px(lin(a.day_dt - c_epoch, v_xmin, v_xmax, 4, 596)) || '" cy="15" r="'
          || fmt_px(3.5 + LEAST(4, ABS(NVL(a.z, 0)) / 3)) || '"><title>' || esc(v_tip) || '</title></circle>');
      END LOOP;
      p('</svg></div>');
    END LOOP;
    IF v_strip_n > 0 THEN
      p('<div class="strip-axis"><div></div><div><span>' || dfmt(v_win_lo + 1) || '</span><span>'
        || dfmt(v_win_lo + FLOOR(anomaly_days / 2)) || '</span><span>' || dfmt(v_win_hi) || '</span></div></div>');
      p('</div>');
    END IF;
  END IF;

  any_rows := FALSE;
  FOR r IN (
    SELECT db_pdb, day_str AS day_dt, busy_pct, median_pct, threshold_pct, z, anomaly_flag
    FROM   capr_cpu_anomalies
    WHERE  days_ago < anomaly_days
    ORDER  BY days_ago, con_dbid
  ) LOOP
    IF NOT any_rows THEN
      p('<details class="fold"><summary>The numbers behind every dot</summary><div class="fold-body">');
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Day' || info_icon('CAPR column: DAY_DT')
        || '</th><th class="num">Busy %' || info_icon('CAPR column: BUSY_PCT')
        || '</th><th class="num">Median %' || info_icon('the usual busy percent for that same weekday (CAPR column: MEDIAN_PCT)')
        || '</th><th class="num">Threshold %' || info_icon('how far from usual a day must be before it is flagged (CAPR column: THRESHOLD_PCT)')
        || '</th><th class="num">Robust z' || info_icon('how far outside its normal range this day was -- 3 or more is clearly unusual (CAPR column: Z)')
        || '</th><th>Flag' || info_icon('CAPR column: ANOMALY_FLAG') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(r.db_pdb) || '</td><td style="white-space:nowrap">' || r.day_dt || '</td>'
      || '<td class="num">' || nz(r.busy_pct, 'FM9990.00') || '</td>'
      || '<td class="num">' || nz(r.median_pct, 'FM9990.00') || '</td>'
      || '<td class="num">' || nz(r.threshold_pct, 'FM9990.00') || '</td>'
      || '<td class="num' || (CASE WHEN ABS(NVL(r.z,0)) >= 3 THEN ' z-hi' ELSE '' END) || '">'
         || nz(r.z, 'FM99990.0') || '</td>'
      || '<td class="' || CASE WHEN r.anomaly_flag = 'HIGH' THEN 'sev-crit' ELSE 'sev-ok' END || '">' || esc(r.anomaly_flag) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div></div></details>');
  ELSE
    p('<div class="glance-ok">No unusual CPU days in the last ' || TO_CHAR(anomaly_days, 'FM999990') || ' days.</div>');
  END IF;

  -- 5b: level shifts (M10.3). A different question from 5a -- not "was one
  -- day odd?" but "does this machine run at a different level than it did a
  -- month ago?", which no single-day test can answer.
  p('<h3 style="font-size:13px;margin:16px 0 6px">Level shifts '
      || info_icon('a sustained step in the level a series runs at -- the thing a single-day outlier test structurally cannot see')
      || '</h3>');
  p('<p class="desc">A sustained step, not a one-day spike: the median of the '
      || 'recent window against the median of the baseline window before it. '
      || 'Flagged only when the gap exceeds the threshold in percentage points '
      || 'AND every day of the recent window stays on the same side of the '
      || 'baseline median plus its MAD sigma.</p>');
  any_rows := FALSE;
  FOR r IN (
    SELECT db_pdb, metric, recent_days, base_days, recent_med, base_med,
           shift_pct, threshold_pct, n_above, n_below, n_recent, shift_flag, sev
    FROM   capr_cpu_shifts
    ORDER  BY rank_shift
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Metric' || info_icon('CAPR column: METRIC')
        || '</th><th>Windows' || info_icon('recent window vs the baseline window before it (CAPR columns: RECENT_DAYS, BASE_DAYS)')
        || '</th><th class="num">Recent %' || info_icon('median over the recent window (CAPR column: RECENT_MED)')
        || '</th><th class="num">Base %' || info_icon('median over the baseline window just before it (CAPR column: BASE_MED)')
        || '</th><th class="num">Shift (pts)' || info_icon('recent median minus baseline median, in percentage points (CAPR column: SHIFT_PCT)')
        || '</th><th class="num">Threshold' || info_icon('CAPR column: THRESHOLD_PCT')
        || '</th><th class="num">N of M' || info_icon('how many days of the recent window are past the baseline median plus its MAD sigma -- all of them, for a flag (CAPR columns: N_ABOVE, N_BELOW, N_RECENT)')
        || '</th><th>Flag' || info_icon('CAPR column: SHIFT_FLAG') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(r.db_pdb) || '</td><td>' || esc(r.metric) || '</td>'
      || '<td>' || TO_CHAR(r.recent_days, 'FM990') || ' vs ' || TO_CHAR(r.base_days, 'FM990') || ' d</td>'
      || '<td class="num">' || nz(r.recent_med, 'FM9990.0') || '</td>'
      || '<td class="num">' || nz(r.base_med, 'FM9990.0') || '</td>'
      || '<td class="num">' || nz(r.shift_pct, 'FMS9990.0') || '</td>'
      || '<td class="num">' || nz(r.threshold_pct, 'FM9990.0') || '</td>'
      || '<td class="num">' || TO_CHAR(GREATEST(r.n_above, r.n_below), 'FM990')
         || '/' || TO_CHAR(r.n_recent, 'FM990') || '</td>'
      || '<td class="' || (CASE WHEN r.sev = 'WARN' THEN 'sev-warn' ELSE 'sev-ok' END)
         || '">' || esc(r.shift_flag) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="empty-note">No sustained level shifts detected.</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 6: ESM vs REGR compare (dispatch identical to report.sql /
  -- 06_esm_compare.sql / 06_esm_skip.sql)
  ----------------------------------------------------------------------
  p('<section id="s6">');
  p('<h2>6. Tier 2 vs Tier 1 at +30 days '
      || info_icon('Tier 1 fits a straight line through recent history; Tier 2 is an Oracle ML model that also learns weekly patterns -- trust Tier 2 for the next 30 days when both exist, Tier 1 for further out')
      || '</h2>');

  IF NOT do_esm THEN
    p('<p class="desc">A second-opinion short-term forecast from a machine-learning model, shown when one has been trained. '
        || 'Skipped: either show_esm=N, or show_esm=AUTO with no ESM models trained. '
        || 'Run <code>EXEC cap_forecast_ml.train_all</code> then re-run the report (or set '
        || 'show_esm=&#39;Y&#39; to force the (empty) table).</p>');
  ELSE
    p('<p class="desc">A second opinion on the next 30 days from an Oracle ML model (ESM), beside the straight-line '
        || 'forecast (REGR), with the holdout backtest that says which engine was right over the last '
        || 'few weeks. ' || esm_ok || ' OML ESM model(s) trained. ESM reaches +30 only on 19c; the +90 / +180 / +365 '
        || 'numbers in section 2 are REGR-only. HOLT = EXSM_HOLT, ADDW = EXSM_ADDWINTERS with a 7-day season.</p>');

    any_rows := FALSE;
    FOR r IN (
      SELECT c.db_pdb, c.series_kind, c.series_key, c.con_dbid,
             CASE WHEN c.series_kind = 'TBSPC' THEN c.regr_gb   ELSE c.regr   END AS regr,
             CASE WHEN c.series_kind = 'TBSPC' THEN c.esm_gb    ELSE c.esm    END AS esm,
             CASE WHEN c.series_kind = 'TBSPC' THEN c.esm_lo_gb ELSE c.esm_lo END AS esm_lo,
             CASE WHEN c.series_kind = 'TBSPC' THEN c.esm_hi_gb ELSE c.esm_hi END AS esm_hi,
             c.esm_model, c.rank_report,
             b.regr_mape, b.esm_mape, b.better, b.esm_pick
      FROM   capr_esm_compare c
      LEFT   JOIN capr_backtest b
        ON   b.dbid = c.dbid AND b.con_dbid = c.con_dbid AND b.series_kind = c.series_kind AND b.series_key = c.series_key
      WHERE  c.horizon_days = 30
        AND  (c.series_kind = 'CPU' OR (c.is_reportable = 'Y' AND c.rank_report <= top_n))
        AND  (c.series_kind = 'TBSPC' OR c.series_key IN ('BUSY_PCT', 'BUSY_P95', 'DB_CPU_SEC', 'DB_CPU_PCT'))
      ORDER  BY CASE c.series_kind WHEN 'TBSPC' THEN 0 ELSE 1 END, NVL(c.rank_report, 999), c.con_dbid, c.series_key
    ) LOOP
      IF NOT any_rows THEN
        p('<div class="tscroll">');
        p('<table class="tbl"><thead><tr>'
          || '<th>Series' || info_icon('tablespaces in GiB (the same ones as section 2), CPU metrics in their own unit (CAPR column: SERIES_KEY)')
          || '</th><th class="num">REGR +30' || info_icon('straight-line projection 30 days out (CAPR column: REGR_GB / REGR)')
          || '</th><th class="num">ESM +30' || info_icon('the Oracle ML forecast 30 days out (CAPR column: ESM_GB / ESM)')
          || '</th><th class="num">ESM 95% band' || info_icon('CAPR columns: ESM_LO, ESM_HI')
          || '</th><th class="num">Gap' || info_icon('ESM minus REGR as a percent of REGR; a large gap means the two engines disagree about the near future')
          || '</th><th>ESM model' || info_icon('HOLT = trend only; ADDW = trend plus a 7-day season (CAPR column: ESM_MODEL)')
          || '</th><th class="num">Backtest MAPE, REGR / ESM' || info_icon('average percent miss of each engine over the held-out window before today; lower is better (CAPR columns: REGR_MAPE, ESM_MAPE)')
          || '</th><th>Right last month' || info_icon('which engine had the lower backtest error, and which ESM variant AUTO picked and why (CAPR columns: BETTER, ESM_PICK)')
          || '</th></tr></thead><tbody>');
        any_rows := TRUE;
      END IF;
      v_gap_pct := CASE WHEN r.regr IS NOT NULL AND r.esm IS NOT NULL AND r.regr <> 0 THEN 100 * (r.esm - r.regr) / ABS(r.regr) END;
      p('<tr><td><b>' || esc(r.series_key) || '</b>' || CASE WHEN v_con_count > 1 OR r.series_kind = 'CPU' THEN ' <span class="dim">' || esc(r.db_pdb) || '</span>' END || '</td>'
        || '<td class="num">' || nz(r.regr, CASE WHEN r.series_kind = 'TBSPC' THEN 'FM999999990.0' ELSE 'FM99999990.00' END) || '</td>'
        || '<td class="num">' || CASE WHEN r.esm IS NULL THEN '<span class="na">no model</span>'
                                      ELSE nz(r.esm, CASE WHEN r.series_kind = 'TBSPC' THEN 'FM999999990.0' ELSE 'FM99999990.00' END) END || '</td>'
        || '<td class="num dim">' || CASE WHEN r.esm_lo IS NULL THEN '&ndash;'
                                          ELSE nz(r.esm_lo, CASE WHEN r.series_kind = 'TBSPC' THEN 'FM999999990.0' ELSE 'FM99999990.00' END)
                                               || ' &ndash; ' || nz(r.esm_hi, CASE WHEN r.series_kind = 'TBSPC' THEN 'FM999999990.0' ELSE 'FM99999990.00' END) END || '</td>'
        || '<td class="num' || CASE WHEN ABS(v_gap_pct) >= 10 THEN ' gap-hi' END || '">'
        || CASE WHEN v_gap_pct IS NULL THEN '&ndash;' ELSE CASE WHEN v_gap_pct >= 0 THEN '+' END || TO_CHAR(v_gap_pct, 'FM9990.0') || '%' END || '</td>'
        || '<td>' || NVL(esc(r.esm_model), '&ndash;') || '</td>'
        || '<td class="num">' || CASE WHEN r.regr_mape IS NULL THEN '&ndash;' ELSE nz(r.regr_mape, 'FM99990.00') END
        || ' / ' || CASE WHEN r.esm_mape IS NULL THEN '&ndash;' ELSE nz(r.esm_mape, 'FM99990.00') END || '</td>'
        || '<td>' || CASE WHEN r.better IS NULL THEN '&ndash;'
                          ELSE '<span class="win' || CASE WHEN r.better = 'REGR' THEN ' r' END || '">' || r.better || '</span>' END
        || CASE WHEN r.esm_pick IS NOT NULL THEN ' <span class="dim">' || esc(r.esm_pick) || '</span>' END || '</td></tr>');
    END LOOP;
    IF any_rows THEN
      p('</tbody></table>');
      p('</div>');  -- .tscroll
    ELSE
      p('<div class="empty-note">No ESM/REGR comparison rows found.</div>');
    END IF;
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 7: fixed-ceiling series (M11) -- processes / sessions / redo /
  -- total DB size. Deliberately minimal: one table straight off CAPR_SERIES,
  -- the same view report/sections/07_series.sql reads.
  ----------------------------------------------------------------------
  p('<section id="s7">');
  p('<h2>7. Fixed-ceiling series '
      || info_icon('peak processes and sessions against the init parameters, redo written per day, and total database size against the summed tablespace ceilings')
      || '</h2>');
  p('<p class="desc">Series with a hard ceiling that is not a tablespace; a dash in Days to limit means no crossing at the current trend. '
      || 'PROCESSES / SESSIONS are the AWR peak-concurrency high-water marks against the '
      || 'init parameter (summed over RAC instances); DB_SIZE_GB is total permanent-tablespace '
      || 'usage against the sum of the same tablespaces&#39; ceilings; REDO_GB_DAY has no ceiling '
      || 'and is a sizing trend for the FRA / archive destination. DAYS_LIM is the projected '
      || 'days until the series reaches SAT, and WORST/BEST bound it with the 95% CI on the slope.</p>');

  any_rows := FALSE;
  FOR r IN (
    SELECT db_pdb, series, unit, cur_val, cur_limit, sat_value, pct_of_limit,
           slope_per_day, r2, days_to_limit, limit_worst, limit_best, sev, quality
    FROM   capr_series
    ORDER  BY rank_series
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Series' || info_icon('CAPR column: SERIES')
        || '</th><th>Unit' || info_icon('CAPR column: UNIT')
        || '</th><th class="num">Current' || info_icon('CAPR column: CUR_VAL')
        || '</th><th class="num">Limit' || info_icon('CAPR column: CUR_LIMIT')
        || '</th><th class="num">Sat'
        || info_icon('the fraction of the limit treated as saturated -- the level Days to limit counts down to (CAPR column: SAT_VALUE)')
        || '</th><th>Fill' || info_icon('current value as a percent of the limit (CAPR column: PCT_OF_LIMIT)')
        || '</th><th class="num">Slope/day' || info_icon('CAPR column: SLOPE_PER_DAY')
        || '</th><th class="num">R2</th>'
        || '<th class="num">Days to limit' || info_icon('CAPR column: DAYS_TO_LIMIT')
        || '</th><th class="num">Worst' || info_icon('CAPR column: LIMIT_WORST')
        || '</th><th class="num">Best' || info_icon('CAPR column: LIMIT_BEST')
        || '</th><th>Severity' || info_icon('CAPR column: SEV')
        || '</th><th>Quality' || info_icon('CAPR column: QUALITY') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr' || row_cls(r.sev) || '><td>' || esc(r.db_pdb) || '</td><td><b>' || esc(r.series) || '</b></td>'
      || '<td>' || esc(r.unit) || '</td>'
      || '<td class="num">' || nz(r.cur_val) || '</td>'
      || '<td class="num">' || nz(r.cur_limit) || '</td>'
      || '<td class="num">' || nz(r.sat_value) || '</td>'
      || '<td>' || CASE WHEN r.pct_of_limit IS NULL THEN '&ndash;'
                     ELSE bar(r.pct_of_limit, CASE r.sev WHEN 'CRIT' THEN 'crit' WHEN 'WARN' THEN 'warn' ELSE '' END) END || '</td>'
      || '<td class="num">' || nz(r.slope_per_day, 'FM999999990.0000') || '</td>'
      || '<td class="num">' || nz(r.r2, 'FM90.000') || '</td>'
      || '<td class="num">' || CASE WHEN r.days_to_limit IS NULL THEN '&mdash;' ELSE TO_CHAR(r.days_to_limit, 'FM99999990') END || '</td>'
      || '<td class="num">' || nz(r.limit_worst, 'FM99999990') || '</td>'
      || '<td class="num">' || nz(r.limit_best, 'FM99999990') || '</td>'
      || '<td>' || sev_pill(r.sev) || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="empty-note">No fixed-ceiling series yet (needs DBA_HIST_RESOURCE_LIMIT / '
      || 'DBA_HIST_SYSSTAT history, or tablespace history for DB_SIZE_GB).</div>');
  END IF;
  p('</section>');

  ----------------------------------------------------------------------
  -- Footer + close document
  ----------------------------------------------------------------------
  p('<footer>End of report -- read-only run, no database objects created or modified. '
      || 'Written to reports/' || cap_file || '</footer>');
  p('</div>');
  -- Theme toggle: the only script in the document. It stamps data-theme on
  -- the root (the CSS tokens above react to it) and remembers the choice in
  -- localStorage; without it the page follows the OS preference.
  p('<script>(function(){var r=document.documentElement,k="cap-theme";try{var t=localStorage.getItem(k);if(t){r.setAttribute("data-theme",t);}}catch(e){}'
    || 'var b=document.getElementById("themeBtn");if(b){b.onclick=function(){var c=r.getAttribute("data-theme");'
    || 'var d=c?c==="dark":window.matchMedia("(prefers-color-scheme: dark)").matches;var n=d?"light":"dark";'
    || 'r.setAttribute("data-theme",n);try{localStorage.setItem(k,n);}catch(e){}};}})();</script>');
  p('</body></html>');
END;
/

SPOOL OFF

SET DEFINE '&'
SET TERMOUT ON

-- M7.6: positional arguments stay DEFINEd for the rest of the SQL*Plus
-- session, so drop them -- otherwise a following `@report/report.sql` with no
-- arguments would silently inherit this run's.
UNDEFINE 1
UNDEFINE 2
UNDEFINE 3
PROMPT
PROMPT Report written to: &cap_path
PROMPT
