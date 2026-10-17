--
-- report/report_html.sql -- read-only, self-contained HTML capacity report.
-- =====================================================================
-- Spools a single-file HTML dashboard from the CAPR_/CAPF_ views to
-- reports/cap_report_<db>_<ts>.html. READ-ONLY: only SELECTs (the CAPF_ESM
-- views call a pipelined function, which writes nothing). Creates/modifies no
-- database object. This is a SIBLING of report/report.sql (the plain-text
-- report): since M8.2 BOTH drivers read the same CAPR_* per-section views
-- (ddl/45_report_views.sql + ddl/55_report_views_ml.sql) and only FORMAT --
-- the analytics SQL is no longer duplicated here, so text and HTML cannot
-- drift. Only chart geometry (pixel positions of the CAPD_* history points
-- and of the CAPR_FORECAST_POINTS / CAPF_* projections) is computed here; the
-- whole-database hero reads CAPR_SERIES DB_SIZE_GB, the number section 7
-- prints.
--
-- Run from the REPO ROOT so the @@report/defaults.sql include resolves
-- (SQL*Plus @@ is relative to the outermost caller's directory on 19c):
--   sqlplus user/pw@svc
--   SQL> @report/report_html.sql              -- defaults from report/defaults.sql
--   SQL> @report/report_html.sql 25 60 Y      -- top_n / anomaly_days / show_esm
--   SQL> @report/report_html.sql - - - 42424242 42424243   -- one container
--   SQL> @report/report_html.sql - - - - - SNAPSHOT        -- from the last refresh run
-- Arguments are positional and optional (M7.6); each one omitted (or '-')
-- falls back to report/defaults.sql. show_esm is AUTO | Y | N. [dbid]
-- [con_dbid] scope every section and rank top_n inside the scope; [source]
-- LIVE (default) or SNAPSHOT, as in report/report.sql.
--
-- Each section renders inside its own exception handler: a failing query
-- prints a visible "section N failed" block and the page carries on; the
-- footer counts the failed sections.
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
--   @report/report_html.sql [top_n] [anomaly_days] [show_esm] [dbid] [con_dbid] [source]
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
COLUMN 4 NEW_VALUE 4 NOPRINT
COLUMN 5 NEW_VALUE 5 NOPRINT
COLUMN 6 NEW_VALUE 6 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3",
       NULL AS "4", NULL AS "5", NULL AS "6" FROM dual WHERE 1 = 0;

-- Effective knobs = positional argument, else the defaults.sql value. An
-- omitted argument is the empty string, and '' IS NULL in Oracle, so NVL
-- picks the default. Re-DEFINEs the same three names bound below.
COLUMN eff_top_n NEW_VALUE top_n        NOPRINT
COLUMN eff_anom  NEW_VALUE anomaly_days NOPRINT
COLUMN eff_esm   NEW_VALUE show_esm     NOPRINT
SELECT NVL(NULLIF(TRIM('&1'), '-'), '&top_n')                  AS eff_top_n,
       NVL(NULLIF(TRIM('&2'), '-'), '&anomaly_days')           AS eff_anom,
       NVL(NULLIF(UPPER(TRIM('&3')), '-'), UPPER('&show_esm')) AS eff_esm
FROM   dual;

-- Scope and source, as in report/report.sql: digits or the literal NULL.
COLUMN eff_sdbid NEW_VALUE cap_sdbid NOPRINT
COLUMN eff_scon  NEW_VALUE cap_scon  NOPRINT
COLUMN eff_src   NEW_VALUE cap_src   NOPRINT
SELECT NVL(REGEXP_SUBSTR(TRIM('&4'), '^[0-9]+$'), 'NULL')                  AS eff_sdbid,
       NVL(REGEXP_SUBSTR(TRIM('&5'), '^[0-9]+$'), 'NULL')                  AS eff_scon,
       CASE WHEN UPPER(TRIM('&6')) = 'SNAPSHOT' THEN 'SNAPSHOT' ELSE 'LIVE' END AS eff_src
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
COLUMN esm_failed NEW_VALUE esm_failed NOPRINT
COLUMN esm_stale  NEW_VALUE esm_stale  NOPRINT
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
-- CAP_CFG only to echo them in the "How to read this report" fold.
SELECT c.dtf_warn                                         AS dtf_warn,
       c.dtf_crit                                         AS dtf_crit,
       c.cpu_sat_pct                                      AS cpu_sat,
       c.nearfull_warn_pct                                AS nf_warn,
       c.nearfull_crit_pct                                AS nf_crit,
       -- Tier 2 health, FORECAST models only (same counts as report.sql).
       (SELECT NVL(SUM(n_ok), 0)     FROM capf_esm_health_summary) AS esm_ok,
       (SELECT NVL(SUM(n_failed), 0) FROM capf_esm_health_summary) AS esm_failed,
       (SELECT NVL(SUM(n_stale), 0)  FROM capf_esm_health_summary) AS esm_stale,
       c.train_days                                       AS train_days,
       c.min_train_days                                   AS min_train_days,
       c.r2_gate                                          AS r2_gate,
       c.report_min_gb                                    AS min_gb
FROM   cap_cfg c;

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
VARIABLE b_esm_failed   NUMBER
VARIABLE b_esm_stale    NUMBER
VARIABLE b_train_days     NUMBER
VARIABLE b_min_train_days NUMBER
VARIABLE b_r2_gate        NUMBER
VARIABLE b_min_gb         NUMBER
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
  :b_dtf_warn     := &dtf_warn;
  :b_dtf_crit     := &dtf_crit;
  :b_cpu_sat      := &cpu_sat;
  :b_nf_warn      := &nf_warn;
  :b_nf_crit      := &nf_crit;
  :b_esm_ok       := &esm_ok;
  :b_esm_failed   := &esm_failed;
  :b_esm_stale    := &esm_stale;
  :b_train_days     := &train_days;
  :b_min_train_days := &min_train_days;
  :b_r2_gate        := &r2_gate;
  :b_min_gb         := &min_gb;
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
  esm_ok       PLS_INTEGER := :b_esm_ok;       -- FORECAST models with status OK
  esm_failed   PLS_INTEGER := :b_esm_failed;   -- FORECAST models whose last build failed
  esm_stale    PLS_INTEGER := :b_esm_stale;    -- FORECAST models older than esm_max_age_days
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
  -- Scope (NULL = any) and source (LIVE | SNAPSHOT). Every top-level query
  -- filters with (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR
  -- con_dbid = s_con); ranked lists re-number the view's rank inside it.
  s_dbid   NUMBER       := :b_sdbid;
  s_con    NUMBER       := :b_scon;
  v_src    VARCHAR2(10) := :b_src;
  v_snap_run  NUMBER;              -- SNAPSHOT: CAPR_RUNS.last_ok_run_id
  v_scope_lbl VARCHAR2(1000);
  v_src_lbl   VARCHAR2(300);
  v_failed    PLS_INTEGER := 0;    -- sections whose rendering raised
  v_esm_lbl   VARCHAR2(60);        -- chart_svg: tooltip on the ESM marker

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
    accel           NUMBER,
    cycle_days      NUMBER,
    cycle_peak_pct  NUMBER
  );
  TYPE dtf_diag_tab IS TABLE OF dtf_diag_rec INDEX BY PLS_INTEGER;
  v_dtf_diag   dtf_diag_tab;
  v_dtf_diag_n PLS_INTEGER;


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
  atip str_tab;                    -- anomaly ring tooltips, parallel to ax/ay
  mad_window  NUMBER;              -- CAP_CONFIG mad_window_days (TRAILING baseline)
  dow_wk      NUMBER;              -- CAP_CONFIG dow_weeks (SAME_DOW / HOUR_OF_WEEK)
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
  v_n_hlth    PLS_INTEGER := 0;
  v_first_crit VARCHAR2(300);
  v_p95_cur   NUMBER;
  v_p95_dts   NUMBER;
  v_p95_q     VARCHAR2(30);
  v_bt_rows   PLS_INTEGER := 0;
  v_run_line  VARCHAR2(600);       -- CAPR_RUNS: the last refresh run, or none
  v_cov_line  VARCHAR2(4000);      -- CAPR_COVERAGE summaries, one per dbid
  v_n_dbid    PLS_INTEGER := 0;
  v_n_current PLS_INTEGER := 0;    -- dbids not retired (data_stale_max_days)
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
  c_chip_cap  CONSTANT PLS_INTEGER := 30;   -- healthy chips per group (tablespaces, series, hosts)
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
  -- sec_failed: called from a section's exception handler. Closes whatever
  -- table the section had open (outside a table the end tags are ignored;
  -- an open div is closed by the section's own </section>),
  -- prints the error where the section's content would be, and counts it
  -- for the footer. The rest of the page still renders.
  ----------------------------------------------------------------------
  PROCEDURE sec_failed(p_sec IN VARCHAR2, p_err IN VARCHAR2) IS
  BEGIN
    v_failed := v_failed + 1;
    p('</tbody></table>');
    p('<div class="sec-fail"><b>Section ' || p_sec || ' failed:</b> '
      || REPLACE(REPLACE(REPLACE(SUBSTR(p_err, 1, 800), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
      || '. The rest of the report is unaffected.</div>');
  END sec_failed;

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
                  WHEN 'CYCLIC'                THEN 'pill-flat'
                  ELSE 'pill-flat' END;
    -- Plain-English gloss per quality value, shown as a native tooltip on hover.
    ttl := CASE q WHEN 'OK'                   THEN 'steady enough to forecast reliably'
                  WHEN 'LOW_CONFIDENCE'       THEN 'growth is too erratic for a dependable estimate'
                  WHEN 'FLAT'                 THEN 'not growing at all'
                  WHEN 'INSUFFICIENT_HISTORY' THEN 'not enough days of AWR history yet'
                  WHEN 'CYCLIC'               THEN 'a recurring purge cycle, judged on its peaks'
                  ELSE NULL END;
    RETURN '<span class="pill ' || cls || '"'
           || CASE WHEN ttl IS NOT NULL THEN ' title="' || ttl || '"' END
           || '>' || esc(q) || '</span>';
  END quality_pill;

  FUNCTION sev_pill(sev IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF sev = 'CRIT' THEN RETURN '<span class="sev-crit">CRIT</span>';
    ELSIF sev = 'WARN' THEN RETURN '<span class="sev-warn">WARN</span>';
    ELSE RETURN '<span class="sev-ok">OK</span>';
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
    IF q = 'CYCLIC' THEN RETURN '<span class="na">peaks not growing</span>'; END IF;
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
  -- (the DB_SIZE_GB hero / CAPR_CPU_TREND) rather than reading from CAPR_ALERTS.
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
                WHEN 'CPU_HOT'        THEN '#s4'
                WHEN 'DBCPU_HOT'      THEN '#s4'
                WHEN 'MODEL_HEALTH'   THEN '#s6'
                WHEN 'CPU_SHIFT'      THEN '#s5'
                WHEN 'CPU_ANOM'       THEN '#s5'
                WHEN 'DBCPU_ANOM'     THEN '#s5'
                WHEN 'TBSPC_ANOM'     THEN '#s3'
                WHEN 'SERIES_ANOM'    THEN '#s7'
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

  -- The sizing ask (CAPR_TBSPC_DAYS_TO_FULL need_gib_90 / add_by_day) as a
  -- phrase, NULL when nothing needs adding within 90 days.
  FUNCTION ask_txt(p_need IN NUMBER, p_by IN DATE) RETURN VARCHAR2 IS
  BEGIN
    IF p_need IS NULL OR p_need <= 0 THEN RETURN NULL; END IF;
    RETURN 'add ' || CASE WHEN p_need < 10 THEN TO_CHAR(p_need, 'FM9990.00') || ' GiB'
                          ELSE fmt_size_gb(p_need) END
           || CASE WHEN p_by IS NOT NULL THEN ' by ' || dfmt(p_by) END;
  END ask_txt;

  -- growth rate from MiB/day: MiB below 1 GiB/day, GiB above
  FUNCTION fmt_rate_mb(mb IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF mb IS NULL THEN RETURN 'unknown'; END IF;
    IF ABS(mb) >= 1024 THEN RETURN TO_CHAR(mb / 1024, 'FM999990.0') || ' GiB/day'; END IF;
    RETURN TO_CHAR(ROUND(mb), 'FM999990') || ' MiB/day';
  END fmt_rate_mb;

  -- Baseline-mode wording (CAPR_* baseline_mode): what "usual" was measured
  -- against. Weekday names are pinned to English like the CAPR messages.
  FUNCTION mode_phrase(p_mode IN VARCHAR2, p_ts IN DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE p_mode
             WHEN 'TRAILING' THEN 'over the last ' || TO_CHAR(mad_window, 'FM9990') || ' days'
             WHEN 'SAME_DOW' THEN 'for a ' || TO_CHAR(p_ts, 'FMDay', 'NLS_DATE_LANGUAGE=ENGLISH')
             ELSE 'for ' || TO_CHAR(p_ts, 'Dy HH24', 'NLS_DATE_LANGUAGE=ENGLISH') || ':00'
           END;
  END mode_phrase;

  FUNCTION mode_label(p_mode IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE p_mode
             WHEN 'TRAILING' THEN 'Last ' || TO_CHAR(mad_window, 'FM9990') || ' days'
             WHEN 'SAME_DOW' THEN 'Same weekday'
             ELSE 'Same hour of week'
           END;
  END mode_label;

  -- an M11 series value in its CAPA unit (COUNT / GIB_PER_DAY)
  FUNCTION series_val(p_val IN NUMBER, p_unit IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE p_unit WHEN 'COUNT' THEN TO_CHAR(p_val, 'FM99999999990')
                       ELSE TO_CHAR(p_val, 'FM99999990.00') || ' GiB/day' END;
  END series_val;

  -- Chart-ring tooltip from CAPR_SERIES_POINTS: which day baselines flagged
  -- the point (anomaly_modes, comma-separated) and how many hours of it the
  -- hour-of-week baseline flagged.
  FUNCTION ring_tip(p_ts IN DATE, p_val IN VARCHAR2, p_modes IN VARCHAR2, p_hours IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN dfmt(p_ts) || ': ' || p_val
           || CASE WHEN p_modes IS NOT NULL THEN ', unusual vs '
                   || REPLACE(REPLACE(REPLACE(p_modes, ',', ' and '),
                              'TRAILING', 'the last ' || TO_CHAR(mad_window, 'FM9990') || ' days'),
                              'SAME_DOW', 'the same weekday') END
           || CASE WHEN p_hours > 0 THEN CASE WHEN p_modes IS NOT NULL THEN ';' ELSE ',' END || ' '
                   || TO_CHAR(p_hours, 'FM990') || ' hour' || CASE WHEN p_hours = 1 THEN '' ELSE 's' END
                   || ' unusual for the hour of the week' END;
  END ring_tip;

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
    -- prediction band: from the projection's anchor (px1/py1(1), the
    -- horizon-0 point of the view) out along the hi knots, back along the
    -- lo knots
    IF v_nband >= 1 AND v_cnt >= 1 THEN
      IF v_has_proj THEN
        buf := 'M' || fmt_px(sx(px1(1))) || ' ' || fmt_px(sy(py1(1)));
      ELSE
        buf := 'M' || fmt_px(sx(xs(v_cnt))) || ' ' || fmt_px(sy(ys(v_cnt)));
      END IF;
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
      p('<circle class="anom-dot" cx="' || fmt_px(sx(ax(i))) || '" cy="' || fmt_px(sy(ay(i))) || '" r="4">'
        || CASE WHEN atip.EXISTS(i) THEN '<title>' || esc(atip(i)) || '</title>' END || '</circle>');
    END LOOP;
    -- ESM point: whisker + diamond, at the model's furthest step
    IF p_esm_val IS NOT NULL AND p_esm_x IS NOT NULL THEN
      xpx := sx(p_esm_x);
      IF p_esm_lo IS NOT NULL AND p_esm_hi IS NOT NULL THEN
        p('<line class="esm-line" x1="' || fmt_px(xpx) || '" y1="' || fmt_px(sy(GREATEST(p_esm_lo, p_ymin)))
          || '" x2="' || fmt_px(xpx) || '" y2="' || fmt_px(sy(LEAST(p_esm_hi, p_ymax))) || '"/>');
      END IF;
      ypx := sy(p_esm_val);
      p('<path class="esm-dot" d="M' || fmt_px(xpx) || ' ' || fmt_px(ypx - 5) || ' l5 5 -5 5 -5 -5 Z">'
        || CASE WHEN v_esm_lbl IS NOT NULL THEN '<title>' || v_esm_lbl || '</title>' END || '</path>');
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
    p('<svg viewBox="0 0 900 30" class="strip-svg" aria-hidden="true">');
    p('<line class="tl-baseline" x1="4" y1="15" x2="896" y2="15"/>');
    WHILE d > c_epoch + p_xmin LOOP
      p('<line class="tl-grid" x1="' || fmt_px(lin(d - c_epoch, p_xmin, p_xmax, 4, 896)) || '" y1="8" x2="'
        || fmt_px(lin(d - c_epoch, p_xmin, p_xmax, 4, 896)) || '" y2="22"/>');
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
  p('section{scroll-margin-top:56px;margin:34px 0}');
  p('section h2{font-size:18px;letter-spacing:-.01em;margin:0 0 4px;display:flex;align-items:center;gap:8px}');
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
  p('.attn .when{font-variant-numeric:tabular-nums;text-align:right;font-weight:700;font-size:16px;white-space:nowrap}');
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
  p('.cross-label,.limit-label,.thresh-label,.shift-label,.today-label,.axis-unit{paint-order:stroke;stroke:var(--panel);stroke-width:3px;stroke-linejoin:round}');
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
  p('.strip-svg{width:100%;height:auto;display:block}');
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
  p('.sec-fail{border:1px solid var(--crit);border-left-width:4px;border-radius:8px;padding:10px 14px;margin:10px 0;color:var(--crit);background:var(--panel2)}');
  p('.gap-hi{color:var(--warn);font-weight:700}');
  p('.nowrap{white-space:nowrap}');
  p('table.tight{font-size:12.5px} table.tight th,table.tight td{padding:6px 7px}');
  p('.glossary dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:10px 0 0}');
  p('.rep-head,.chart-card,.attn,.quiet,.strips,details.fold,table.tbl{box-shadow:0 1px 2px rgba(16,24,40,.05)}');
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
  BEGIN
  SELECT COUNT(DISTINCT con_dbid) INTO v_con_count FROM capd_tbspc_daily
  WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  SELECT mad_window_days, dow_weeks INTO mad_window, dow_wk FROM cap_cfg;
  SELECT NVL(MAX(day_dt) - MIN(day_dt) + 1, 0), MAX(day_dt) INTO v_hist_days, v_last_day FROM capd_tbspc_daily
  WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  -- Scope and source labels; SNAPSHOT reads the newest OK live refresh run.
  SELECT MAX(last_ok_run_id) INTO v_snap_run FROM capr_runs;
  IF s_dbid IS NULL AND s_con IS NULL THEN
    v_scope_lbl := NULL;
  ELSE
    SELECT 'scope ' || TRIM(CASE WHEN s_dbid IS NOT NULL THEN 'dbid ' || s_dbid END
                            || CASE WHEN s_con IS NOT NULL THEN ' con_dbid ' || s_con END)
           || ' (' || NVL(LISTAGG(db_pdb, ', ') WITHIN GROUP (ORDER BY db_pdb), 'no such container') || ')'
      INTO v_scope_lbl
      FROM capr_container
     WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  END IF;
  IF v_src = 'SNAPSHOT' THEN
    v_src_lbl := 'SNAPSHOT: no OK refresh run yet, so the alert list and the section 1 and 7 tables are empty';
    FOR r IN (SELECT run_id, started_at, as_of_day FROM capr_runs WHERE run_id = last_ok_run_id) LOOP
      v_src_lbl := 'SNAPSHOT: alerts and the section 1 / 7 fits from refresh run ' || r.run_id || ' at '
                   || TO_CHAR(r.started_at, 'YYYY-MM-DD HH24:MI') || ' (as of ' || TO_CHAR(r.as_of_day, 'YYYY-MM-DD') || ')';
    END LOOP;
  END IF;
  -- The alert source: CAPR_ALERTS (LIVE) or CAPR_ALERTS_LATEST (SNAPSHOT).
  -- The branch whose constant predicate is false is never evaluated.
  SELECT SUM(CASE WHEN severity = 'CRIT' THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity = 'WARN' THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity = 'INFO' THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity IN ('CRIT','WARN') AND kind IN ('TBSPC_FULL','TBSPC_NEARFULL','CPU_SAT','DBCPU_SAT','CPU_HOT','DBCPU_HOT','SERIES_LIMIT','SERIES_NEARLIMIT') THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity IN ('CRIT','WARN') AND kind IN ('TBSPC_ANOM','CPU_ANOM','DBCPU_ANOM','SERIES_ANOM','CPU_SHIFT') THEN 1 ELSE 0 END),
         SUM(CASE WHEN severity IN ('CRIT','WARN') AND kind IN ('DATA_STALE','MODEL_HEALTH') THEN 1 ELSE 0 END)
    INTO v_n_crit, v_n_warn, v_n_info, v_n_cap, v_n_beh, v_n_hlth
  FROM  (SELECT severity, kind, dbid, con_dbid FROM capr_alerts        WHERE v_src = 'LIVE'
         UNION ALL
         SELECT severity, kind, dbid, con_dbid FROM capr_alerts_latest WHERE v_src = 'SNAPSHOT')
  WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  v_n_crit := NVL(v_n_crit, 0); v_n_warn := NVL(v_n_warn, 0); v_n_info := NVL(v_n_info, 0);
  v_n_cap := NVL(v_n_cap, 0); v_n_beh := NVL(v_n_beh, 0); v_n_hlth := NVL(v_n_hlth, 0);
  v_first_crit := NULL;
  FOR a IN (SELECT series_key, kind, value, unit
            FROM  (SELECT severity, sev_rank, series_key, kind, value, unit, dbid, con_dbid
                   FROM   capr_alerts        WHERE v_src = 'LIVE'
                   UNION ALL
                   SELECT severity, sev_rank, series_key, kind, value, unit, dbid, con_dbid
                   FROM   capr_alerts_latest WHERE v_src = 'SNAPSHOT')
            WHERE  severity = 'CRIT'
              AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
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
  FROM   capr_tbspc_days_to_full
  WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  -- host CPU busy-hour p95 (first container that has one)
  v_p95_cur := NULL; v_p95_dts := NULL; v_p95_q := NULL;
  FOR c IN (SELECT cur_val, days_to_sat, quality FROM capr_cpu_trend
            WHERE metric = 'BUSY_P95'
              AND (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
            ORDER BY con_dbid FETCH FIRST 1 ROW ONLY) LOOP
    v_p95_cur := c.cur_val; v_p95_dts := c.days_to_sat; v_p95_q := c.quality;
  END LOOP;
  SELECT COUNT(*) INTO v_bt_rows FROM capr_backtest WHERE esm_mape IS NOT NULL
     AND (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  -- Results layer and coverage lines (ddl/60). Both views answer on an
  -- install that never ran cap_results.refresh. CAPR_COVERAGE is read once,
  -- here; under SNAPSHOT the line is the refresh run's own summary, since
  -- coverage is not snapshotted.
  SELECT NVL(MAX(CASE WHEN r.is_last = 'Y'
                      THEN 'last ' || r.summary
                           || CASE WHEN r.stale_run = 'Y'
                                   THEN ' (stale: no OK refresh run in the last '
                                        || TO_CHAR(cfg.refresh_stale_hours) || ' h)' END END),
             'no refresh run yet (live evaluation)')
    INTO v_run_line
    FROM capr_runs r CROSS JOIN cap_cfg cfg;
  IF v_src = 'SNAPSHOT' THEN
    SELECT COUNT(*), 1, MAX('coverage as of ' || summary)
      INTO v_n_dbid, v_n_current, v_cov_line
      FROM capr_runs WHERE run_id = last_ok_run_id;
  ELSE
    SELECT COUNT(*), COUNT(CASE WHEN retired = 'N' THEN 1 END),
           LISTAGG(summary, ' | ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY dbid)
      INTO v_n_dbid, v_n_current, v_cov_line
      FROM capr_coverage
     WHERE (s_dbid IS NULL OR dbid = s_dbid)
       AND (s_con IS NULL OR dbid IN (SELECT dbid FROM capr_container WHERE con_dbid = s_con));
  END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_tmp := SQLERRM;
      v_n_current := NVL(v_n_current, 1);
  END;

  p('<div class="rep-head">');
  p('<div><h1>AWR Capacity Report</h1><div class="id"><b>' || esc(cap_db) || '</b> &middot; ' || esc(cap_host)
    || ' &middot; generated ' || esc(cap_gen) || ' &middot; ' || TO_CHAR(v_hist_days, 'FM999990')
    || ' days of AWR history &middot; schema ' || esc(cap_user) || '</div>'
    || CASE WHEN v_scope_lbl IS NOT NULL THEN '<div class="id"><b>' || esc(v_scope_lbl) || '</b></div>' END
    || CASE WHEN v_src_lbl IS NOT NULL THEN '<div class="id"><b>' || esc(v_src_lbl) || '</b></div>' END
    || '<div class="id">' || esc(v_run_line) || '</div>'
    || '<div class="id">' || esc(NVL(v_cov_line, 'coverage: no AWR snapshots in this seam')) || '</div></div>');
  IF v_tmp IS NOT NULL THEN
    sec_failed('header', v_tmp);
    v_tmp := NULL;
  END IF;
  p('<div class="tools"><button class="tbtn" id="themeBtn" type="button" title="Switch light / dark">&#9681; Theme</button>'
    || '<button class="tbtn" type="button" onclick="window.print()">&#9113; Print</button></div>');
  p('<div class="kpis">');
  p('<div class="kpi' || CASE WHEN v_n_crit > 0 THEN ' crit' END || '"><div class="l">Critical</div><div class="v">'
    || TO_CHAR(v_n_crit, 'FM999990') || '</div><div class="s">' || NVL(v_first_crit, 'nothing critical') || '</div></div>');
  p('<div class="kpi' || CASE WHEN v_n_warn > 0 THEN ' warn' END || '"><div class="l">Warnings</div><div class="v">'
    || TO_CHAR(v_n_warn, 'FM999990') || '</div><div class="s">' || TO_CHAR(v_n_cap, 'FM999990') || ' capacity &middot; '
    || TO_CHAR(v_n_beh, 'FM999990') || ' behaviour'
    || CASE WHEN v_n_hlth > 0 THEN ' &middot; ' || TO_CHAR(v_n_hlth, 'FM999990') || ' health' END || '</div></div>');
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
  p('<div class="kpi' || CASE WHEN esm_failed > 0 OR esm_stale > 0 THEN ' warn' END
    || '"><div class="l">Tier 2 models</div><div class="v">' || TO_CHAR(esm_ok, 'FM999990') || '</div><div class="s">'
    || CASE WHEN esm_ok + esm_failed = 0 THEN 'none trained'
            ELSE TO_CHAR(esm_ok, 'FM999990') || ' ok, ' || TO_CHAR(esm_failed, 'FM999990') || ' failed, '
                 || TO_CHAR(esm_stale, 'FM999990') || ' stale &middot; '
                 || CASE WHEN v_bt_rows > 0 THEN 'backtest on' ELSE 'no backtest yet' END
       END || '</div></div>');
  p('</div>');  -- .kpis
  -- one fold for everything about reading the report
  p('<details class="fold"><summary>How to read this report</summary><div class="fold-body">');
  p('<dl class="kv-grid" style="margin:8px 0 0">');
  p('<div class="kv"><dt>Thresholds</dt><dd>days-to-full WARN&lt;=' || dtf_warn
      || ' CRIT&lt;=' || dtf_crit || '; near-full WARN&gt;=' || TO_CHAR(nf_warn, 'FM990') || '% CRIT&gt;=' || TO_CHAR(nf_crit, 'FM990')
      || '%; CPU saturation ' || cpu_sat || '%</dd></div>');
  p('<div class="kv"><dt>Training window</dt><dd>last ' || TO_CHAR(train_days, 'FM999990') || ' days; at least '
      || TO_CHAR(min_train_days, 'FM999990') || ' days before a forecast is trusted; R2 gate ' || TO_CHAR(r2_gate, 'FM0.00') || '</dd></div>');
  p('<div class="kv"><dt>Tier 2 models</dt><dd>OML ESM forecast models: ' || esm_ok || ' ok, ' || esm_failed || ' failed, '
      || esm_stale || ' stale (detail: CAPF_ESM_HEALTH)</dd></div>');
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
  p('<dt>Anomaly</dt><dd>A day (or, for CPU, an hour) that stands out sharply from what is normal for that series.</dd>');
  p('<dt>Baseline</dt><dd>What "normal" is measured against: the last few weeks of days, the same weekday in recent weeks, or (CPU hours) the same hour of the week.</dd>');
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
  -- Everything below is SELECT-only over the same CAPR_/CAPF_/CAPD_ views
  -- the detailed sections use; nothing new is computed.
  ----------------------------------------------------------------------
  p('<section id="s0">');
  BEGIN
  p('<h2>At a glance</h2>');
  p('<p class="desc">What needs attention, ranked, then everything that is fine in one line. '
      || 'Every row comes from CAPR_ALERTS, the same view a monitoring system would poll.</p>');

  ----------------------------------------------------------------------
  -- Attention list: one row per CRIT / WARN alert, with the kind, a plain
  -- sentence, one line of supporting numbers and the number that matters
  -- at the right. The lookups only fetch columns the detail sections print.
  ----------------------------------------------------------------------
  IF v_n_crit + v_n_warn = 0 AND v_n_current = 0 THEN
    -- Nothing alerts because nothing current is left to judge: every dbid
    -- is retired (CAPR_COVERAGE), so "all clear" would be a false comfort.
    p('<div class="glance-warn">No current data: ' || TO_CHAR(v_n_dbid, 'FM999990')
      || ' database(s) in this schema, none with an AWR snapshot in the last '
      || 'data_stale_max_days days, so there is nothing to judge. See the coverage line above.</div>');
  ELSIF v_n_crit + v_n_warn = 0 THEN
    p('<div class="glance-ok">All clear: nothing is near-full, no tablespace, series or CPU is forecast to hit its limit within '
      || TO_CHAR(dtf_warn, 'FM999990') || ' days, and no sustained shift or spike is open.'
      || CASE WHEN v_n_info > 0 THEN ' ' || TO_CHAR(v_n_info, 'FM999990') || ' informational item(s) below.' END || '</div>');
  ELSE
    p('<div class="attn">');
    FOR a IN (
      SELECT severity, kind, dbid, con_dbid, db_pdb, series_key, day_dt, value, threshold, unit, message,
             baseline_mode,
             CASE kind WHEN 'DATA_STALE' THEN 0
                       WHEN 'TBSPC_FULL' THEN 1 WHEN 'CPU_SAT' THEN 2 WHEN 'DBCPU_SAT' THEN 2 WHEN 'SERIES_LIMIT' THEN 3
                       WHEN 'CPU_SHIFT' THEN 4 WHEN 'TBSPC_NEARFULL' THEN 5 WHEN 'SERIES_NEARLIMIT' THEN 6
                       WHEN 'CPU_HOT' THEN 6 WHEN 'DBCPU_HOT' THEN 6
                       WHEN 'TBSPC_ANOM' THEN 7 WHEN 'CPU_ANOM' THEN 8 WHEN 'DBCPU_ANOM' THEN 9
                       WHEN 'SERIES_ANOM' THEN 10 WHEN 'MODEL_HEALTH' THEN 12 ELSE 11 END AS kord
      FROM  (SELECT severity, sev_rank, kind, dbid, con_dbid, db_pdb, series_key, day_dt, value,
                    threshold, unit, message, baseline_mode
             FROM   capr_alerts        WHERE v_src = 'LIVE'
             UNION ALL
             SELECT severity, sev_rank, kind, dbid, con_dbid, db_pdb, series_key, day_dt, value,
                    threshold, unit, message, baseline_mode
             FROM   capr_alerts_latest WHERE v_src = 'SNAPSHOT')
      WHERE  severity IN ('CRIT','WARN')
        AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
      -- a stale AWR qualifies every other row, so it leads whatever its rank
      ORDER  BY CASE kind WHEN 'DATA_STALE' THEN 0 ELSE 1 END, sev_rank, kord, value
    ) LOOP
      v_main := NULL; v_sub := NULL; v_big := NULL; v_small := NULL; v_kind_lbl := NULL;
      v_tmp := CASE WHEN v_con_count > 1 THEN esc(a.db_pdb) || ' &middot; ' END;

      IF a.kind = 'TBSPC_FULL' THEN
        v_kind_lbl := 'Days to full';
        FOR t IN (SELECT slope_mb, cur_gb, limit_gb, dtf_worst, accel, pct_used, days_to_full,
                         need_gib_90, add_by_day
                  FROM capr_tbspc_days_to_full WHERE con_dbid = a.con_dbid AND tablespace_name = a.series_key
                  FETCH FIRST 1 ROW ONLY) LOOP
          v_main := '<b>' || esc(a.series_key) || '</b> fills at ' || fmt_rate_mb(t.slope_mb)
                    || CASE WHEN t.accel >= 1.5 THEN ', growth &times;' || TO_CHAR(t.accel, 'FM990.0') || ' vs its longer-term pace' END;
          v_sub  := v_tmp || fmt_size_gb(t.cur_gb) || ' of ' || fmt_size_gb(t.limit_gb) || ' (' || TO_CHAR(t.pct_used, 'FM990.0') || '%)'
                    || CASE WHEN t.dtf_worst IS NOT NULL AND t.dtf_worst < t.days_to_full
                            THEN ' &middot; worst case ' || TO_CHAR(t.dtf_worst, 'FM999990') || ' days' END
                    || CASE WHEN t.need_gib_90 > 0 THEN ' &middot; ' || ask_txt(t.need_gib_90, t.add_by_day) END;
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
                  WHERE dbid = a.dbid AND con_dbid = a.con_dbid AND tablespace_name = a.series_key
                    AND baseline_mode = a.baseline_mode AND day_dt = a.day_dt) LOOP
          v_main := '<b>' || esc(a.series_key) || '</b> ' || CASE WHEN t.delta_mb >= 0 THEN 'grew ' ELSE 'shrank ' END
                    || fmt_size_gb(ABS(t.delta_mb) / 1024) || ' in one day'
                    || CASE WHEN t.med_mb IS NOT NULL THEN ' (normal ' || mode_phrase(a.baseline_mode, a.day_dt)
                            || ': ' || fmt_rate_mb(t.med_mb) || ')' END;
          v_sub  := v_tmp || dfmt(a.day_dt) || ' &middot; robust z ' || TO_CHAR(t.z, 'FM99990.0')
                    || ' &middot; one day; the forecast is not driven by it';
          v_big  := CASE WHEN t.delta_mb >= 0 THEN '+' ELSE '&minus;' END || fmt_size_gb(ABS(t.delta_mb) / 1024);
        END LOOP;
        v_small := dfmt(a.day_dt);
      ELSIF a.kind IN ('CPU_ANOM', 'DBCPU_ANOM') THEN
        v_kind_lbl := 'Anomaly';
        -- an hour-of-week alert carries its worst hour: largest |z|, earliest
        -- on a tie, the same pick CAPR_ALERTS makes
        FOR t IN (SELECT value_pct, median_pct, z, grain, ts, ts_str, COUNT(*) OVER () AS n_events
                  FROM capr_cpu_anomalies
                  WHERE dbid = a.dbid AND con_dbid = a.con_dbid AND metric = a.series_key
                    AND baseline_mode = a.baseline_mode AND day_dt = a.day_dt
                  ORDER BY ABS(z) DESC NULLS LAST, ts FETCH FIRST 1 ROW ONLY) LOOP
          v_main := '<b>' || CASE a.kind WHEN 'CPU_ANOM' THEN 'Host CPU' ELSE esc(a.db_pdb) || ' DB CPU' END || '</b> ran '
                    || TO_CHAR(t.value_pct, 'FM990.0') || CASE a.kind WHEN 'CPU_ANOM' THEN '% busy' ELSE '% of host cores' END
                    || ' vs the usual ' || TO_CHAR(t.median_pct, 'FM990.0') || '% ' || mode_phrase(a.baseline_mode, t.ts);
          v_sub  := v_tmp || CASE WHEN t.grain = 'HOUR' THEN esc(t.ts_str) ELSE dfmt(a.day_dt) END
                    || ' &middot; robust z ' || TO_CHAR(t.z, 'FM99990.0') || ' &middot; '
                    || CASE WHEN t.n_events > 1 THEN TO_CHAR(t.n_events, 'FM990') || ' hours flagged that day'
                            WHEN t.grain = 'HOUR' THEN 'single hour' ELSE 'single day' END;
          v_big  := CASE WHEN t.value_pct >= t.median_pct THEN '+' ELSE '&minus;' END
                    || TO_CHAR(ABS(t.value_pct - t.median_pct), 'FM990') || ' pts';
        END LOOP;
        v_small := dfmt(a.day_dt);
      ELSIF a.kind = 'SERIES_ANOM' THEN
        v_kind_lbl := 'Anomaly';
        FOR t IN (SELECT value, expected, z, unit FROM capr_series_anomalies
                  WHERE dbid = a.dbid AND con_dbid = a.con_dbid AND series = a.series_key
                    AND baseline_mode = a.baseline_mode AND day_dt = a.day_dt) LOOP
          v_main := '<b>' || esc(a.series_key) || '</b> '
                    || CASE WHEN a.series_key = 'DB_SIZE_GB' THEN 'grew ' ELSE 'at ' END
                    || series_val(t.value, t.unit) || ' vs the usual ' || series_val(t.expected, t.unit)
                    || ' ' || mode_phrase(a.baseline_mode, a.day_dt);
          v_sub  := v_tmp || dfmt(a.day_dt) || ' &middot; robust z ' || TO_CHAR(t.z, 'FM99990.0') || ' &middot; single day';
          v_big  := CASE WHEN t.value >= t.expected THEN '+' ELSE '&minus;' END
                    || series_val(ABS(t.value - t.expected), t.unit);
        END LOOP;
        v_small := dfmt(a.day_dt);
      END IF;

      IF v_main IS NULL THEN
        v_kind_lbl := NVL(v_kind_lbl, esc(REPLACE(a.kind, '_', ' ')));
        v_main := esc(a.message);
        v_big  := CASE a.unit WHEN 'DAYS' THEN TO_CHAR(a.value, 'FM999990') || ' days'
                              WHEN 'PCT'  THEN TO_CHAR(a.value, 'FM990.0') || '%'
                              WHEN 'BYTES' THEN fmt_size_gb(a.value / 1073741824)
                              WHEN 'COUNT' THEN TO_CHAR(a.value, 'FM99999999990')
                              WHEN 'GIB'   THEN fmt_size_gb(a.value)
                              WHEN 'HOURS' THEN TO_CHAR(a.value, 'FM9999990.0') || ' h' END;
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
    FOR a IN (SELECT message, kind, con_dbid, series_key
              FROM  (SELECT severity, message, kind, dbid, con_dbid, series_key, value
                     FROM   capr_alerts        WHERE v_src = 'LIVE'
                     UNION ALL
                     SELECT severity, message, kind, dbid, con_dbid, series_key, value
                     FROM   capr_alerts_latest WHERE v_src = 'SNAPSHOT')
              WHERE  severity = 'INFO'
                AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
              ORDER BY kind, value) LOOP
      p('<li>' || esc(a.message) || evidence_link(a.kind, a.con_dbid, a.series_key) || '</li>');
    END LOOP;
    p('</ul></div></details>');
  END IF;

  ----------------------------------------------------------------------
  -- Healthy line: every capacity series NOT in the attention list, with a
  -- short verdict each, so "fine" is stated rather than implied.
  ----------------------------------------------------------------------
  -- Each chip group stops at c_chip_cap chips and says "+N more", so a fleet
  -- cannot overflow the v_tmp accumulator (32000 bytes, about 150 per chip).
  v_chips := 0; v_tmp := NULL;
  FOR r IN (
    SELECT t.tablespace_name, t.db_pdb, t.days_to_full, t.quality, t.pct_used
    FROM   capr_tbspc_days_to_full t
    WHERE  (s_dbid IS NULL OR t.dbid = s_dbid) AND (s_con IS NULL OR t.con_dbid = s_con)
      AND  NOT EXISTS (SELECT 1
                       FROM  (SELECT con_dbid, series_key, kind, severity FROM capr_alerts        WHERE v_src = 'LIVE'
                              UNION ALL
                              SELECT con_dbid, series_key, kind, severity FROM capr_alerts_latest WHERE v_src = 'SNAPSHOT') a
                       WHERE a.con_dbid = t.con_dbid AND a.series_key = t.tablespace_name
                         AND a.kind IN ('TBSPC_FULL','TBSPC_NEARFULL') AND a.severity IN ('CRIT','WARN'))
    ORDER  BY CASE WHEN t.quality = 'OK' AND t.days_to_full IS NOT NULL THEN 0 ELSE 1 END, t.days_to_full, t.tablespace_name
  ) LOOP
    v_chips := v_chips + 1;
    IF v_chips <= c_chip_cap THEN
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
  IF v_chips > c_chip_cap THEN
    v_tmp := v_tmp || '<span class="chip q">+' || TO_CHAR(v_chips - c_chip_cap, 'FM999990') || ' more</span>';
  END IF;
  v_chips := 0;
  FOR r IN (
    SELECT s.series, s.db_pdb, s.pct_of_limit, s.days_to_limit, s.quality, s.cur_val, s.unit
    FROM   capr_series s
    WHERE  (s_dbid IS NULL OR s.dbid = s_dbid) AND (s_con IS NULL OR s.con_dbid = s_con)
      AND  NOT EXISTS (SELECT 1
                       FROM  (SELECT con_dbid, series_key, kind, severity FROM capr_alerts        WHERE v_src = 'LIVE'
                              UNION ALL
                              SELECT con_dbid, series_key, kind, severity FROM capr_alerts_latest WHERE v_src = 'SNAPSHOT') a
                       WHERE a.con_dbid = s.con_dbid AND a.series_key = s.series
                         AND a.kind IN ('SERIES_LIMIT','SERIES_NEARLIMIT') AND a.severity IN ('CRIT','WARN'))
    ORDER  BY s.rank_series
  ) LOOP
    v_chips := v_chips + 1;
    CONTINUE WHEN v_chips > c_chip_cap;
    v_tmp := v_tmp || '<span class="chip' || CASE WHEN r.quality <> 'OK' THEN ' q' END || '">'
             || con_prefix(r.db_pdb)
             || CASE r.series WHEN 'DB_SIZE_GB' THEN 'DB size' WHEN 'REDO_GB_DAY' THEN 'Redo'
                             WHEN 'PROCESSES' THEN 'Processes' WHEN 'SESSIONS' THEN 'Sessions' ELSE esc(r.series) END
             || CASE WHEN r.pct_of_limit IS NOT NULL THEN ' &middot; ' || TO_CHAR(r.pct_of_limit, 'FM990') || '%'
                     WHEN r.series = 'REDO_GB_DAY' THEN ' &middot; ' || TO_CHAR(r.cur_val, 'FM999990.0') || ' GiB/day' END
             || CASE WHEN r.quality = 'OK' AND r.days_to_limit IS NOT NULL THEN ' &middot; ' || short_dur(r.days_to_limit)
                     WHEN r.quality = 'FLAT' THEN ' &middot; flat'
                     WHEN r.quality = 'OK' THEN ''
                     WHEN r.quality = 'LOW_CONFIDENCE' THEN ' &middot; erratic'
                     ELSE ' &middot; new' END || '</span>';
  END LOOP;
  IF v_chips > c_chip_cap THEN
    v_tmp := v_tmp || '<span class="chip q">+' || TO_CHAR(v_chips - c_chip_cap, 'FM999990') || ' more series</span>';
  END IF;
  v_chips := 0;
  FOR r IN (
    SELECT c.db_pdb, c.cur_val, c.days_to_sat, c.quality
    FROM   capr_cpu_trend c
    WHERE  c.metric = 'BUSY_P95'
      AND  (s_dbid IS NULL OR c.dbid = s_dbid) AND (s_con IS NULL OR c.con_dbid = s_con)
      AND  NOT EXISTS (SELECT 1
                       FROM  (SELECT con_dbid, kind FROM capr_alerts        WHERE v_src = 'LIVE'
                              UNION ALL
                              SELECT con_dbid, kind FROM capr_alerts_latest WHERE v_src = 'SNAPSHOT') a
                       WHERE a.con_dbid = c.con_dbid AND a.kind IN ('CPU_SAT', 'CPU_HOT'))
    ORDER  BY c.con_dbid
  ) LOOP
    v_chips := v_chips + 1;
    CONTINUE WHEN v_chips > c_chip_cap;
    v_tmp := v_tmp || '<span class="chip' || CASE WHEN r.quality <> 'OK' THEN ' q' END || '">Host CPU'
             || CASE WHEN v_con_count > 1 THEN ' (' || esc(r.db_pdb) || ')' END
             || ' &middot; p95 ' || TO_CHAR(ROUND(r.cur_val), 'FM990') || '%'
             || CASE WHEN r.quality = 'OK' AND r.days_to_sat IS NOT NULL THEN ' &middot; ' || short_dur(r.days_to_sat)
                     WHEN r.quality = 'OK' THEN ' &middot; no saturation in sight'
                     WHEN r.quality = 'LOW_CONFIDENCE' THEN ' &middot; erratic'
                     WHEN r.quality = 'FLAT' THEN ' &middot; flat'
                     ELSE ' &middot; new' END || '</span>';
  END LOOP;
  IF v_chips > c_chip_cap THEN
    v_tmp := v_tmp || '<span class="chip q">+' || TO_CHAR(v_chips - c_chip_cap, 'FM999990') || ' more hosts</span>';
  END IF;
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
  -- with the shared chart grammar. The size hero is CAPR_SERIES DB_SIZE_GB,
  -- the row section 7 prints, so both say the same days to the limit: the
  -- history is CAPR_SERIES_POINTS, the projection and its band
  -- CAPR_FORECAST_POINTS (anchored at today by the view, +30 and +90).
  ----------------------------------------------------------------------
  p('<div class="hero-duo">');
  FOR hf IN (SELECT dbid, con_dbid, db_pdb, cur_val, cur_limit, sat_value, slope_per_day,
                    days_to_limit, limit_worst, limit_best, quality, last_day
             FROM   capr_series
             WHERE  series = 'DB_SIZE_GB'
               AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
             ORDER  BY dbid, con_dbid) LOOP
    v_hlabel := 'Whole database' || CASE WHEN v_con_count > 1 THEN ' (' || hf.db_pdb || ')' END;
    v_hquality   := hf.quality;
    v_hero_gb    := hf.cur_val;
    v_rate_gb_mo := hf.slope_per_day * 30;
    v_hlimit_gb  := hf.cur_limit;
    v_days_to_lim := hf.days_to_limit;
    -- the saturation line days_to_limit counts to: series_sat_pct of the limit
    v_pct := ROUND(100 * hf.sat_value / NULLIF(hf.cur_limit, 0));
    v_big := NULL; v_big_lbl := NULL; v_big_cls := NULL; v_accent := NULL;
    IF v_days_to_lim IS NOT NULL AND v_hquality = 'OK' THEN
      v_big := short_dur(v_days_to_lim);
      v_big_lbl := TO_CHAR(v_days_to_lim, 'FM99999990') || ' days to ' || TO_CHAR(v_pct, 'FM990')
                   || '% of the allocated limit &middot; &asymp; ' || dfmt(hf.last_day + v_days_to_lim);
      v_big_cls := CASE WHEN v_days_to_lim <= dtf_crit THEN 'crit' WHEN v_days_to_lim <= dtf_warn THEN 'warn' ELSE 'ok' END;
      v_accent  := CASE WHEN v_days_to_lim <= dtf_crit THEN 'crit' WHEN v_days_to_lim <= dtf_warn THEN 'warn' END;
    END IF;
    v_subtitle := 'using ' || fmt_size_gb(v_hero_gb)
                  || CASE WHEN v_hlimit_gb IS NOT NULL THEN ' of ' || fmt_size_gb(v_hlimit_gb) || ' allocated' END
                  || CASE WHEN v_hquality = 'OK' AND hf.slope_per_day > 0 THEN ' &middot; growing ' || fmt_size_gb(v_rate_gb_mo) || ' per month'
                          WHEN v_hquality = 'OK' AND hf.slope_per_day < 0 THEN ' &middot; shrinking ' || fmt_size_gb(ABS(v_rate_gb_mo)) || ' per month'
                          WHEN v_hquality = 'FLAT' THEN ' &middot; not growing'
                          WHEN v_hquality = 'INSUFFICIENT_HISTORY' THEN ' &middot; not enough history for a whole-database estimate yet'
                          ELSE ' &middot; size changes too unevenly for a reliable estimate' END
                  || CASE WHEN v_days_to_lim IS NOT NULL AND v_hquality <> 'OK'
                          THEN ' (at the current trend ' || TO_CHAR(v_days_to_lim, 'FM99999990') || ' days to '
                               || TO_CHAR(v_pct, 'FM990') || '% of the limit, low confidence)' END;
    card_open(esc(v_hlabel) || ' ' || quality_pill(v_hquality), v_subtitle, v_big, v_big_lbl, v_big_cls, v_accent,
              'dbhero-' || TO_CHAR(hf.con_dbid));

    xs.DELETE; ys.DELETE; v_cnt := 0; v_cnt2 := 0; v_nband := 0; v_nanom := 0; v_has_proj := FALSE;
    FOR d IN (SELECT ts, value FROM capr_series_points
              WHERE  dbid = hf.dbid AND con_dbid = hf.con_dbid
                AND  kind = 'SERIES' AND series = 'DB_SIZE_GB'
              ORDER  BY ts) LOOP
      v_cnt := v_cnt + 1;
      xs(v_cnt) := d.ts - c_epoch;
      ys(v_cnt) := d.value;
    END LOOP;

    IF v_cnt = 0 THEN
      p('<div class="empty-note">No daily totals collected yet to chart.</div>');
    ELSE
      v_last_day_n := xs(v_cnt);
      v_xmin := xs(1); v_xmax := v_last_day_n; v_proj_y := NULL;
      IF v_hquality = 'OK' THEN
        FOR fp IN (SELECT ts, horizon_days, value, lo, hi FROM capr_forecast_points
                   WHERE  dbid = hf.dbid AND con_dbid = hf.con_dbid
                     AND  kind = 'SERIES' AND series = 'DB_SIZE_GB' AND method = 'REGR'
                   ORDER  BY horizon_days) LOOP
          IF fp.horizon_days = 0 THEN
            px1(1) := fp.ts - c_epoch; py1(1) := fp.value;
          ELSE
            px1(2) := fp.ts - c_epoch; py1(2) := fp.value;
            v_proj_y := fp.value; v_xmax := GREATEST(v_xmax, fp.ts - c_epoch);
            v_has_proj := TRUE;
            IF fp.lo IS NOT NULL THEN
              v_nband := v_nband + 1; bx(v_nband) := fp.ts - c_epoch;
              blo(v_nband) := GREATEST(fp.lo, 0); bhi(v_nband) := fp.hi;
            END IF;
          END IF;
        END LOOP;
      END IF;
      v_ymin := 0; v_ymax := ys(1);
      FOR i IN 1 .. v_cnt LOOP
        IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF;
      END LOOP;
      IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
      FOR i IN 1 .. v_nband LOOP IF bhi(i) > v_ymax THEN v_ymax := bhi(i); END IF; END LOOP;
      v_limit_gb   := v_hlimit_gb;
      v_range      := v_ymax - v_ymin;
      v_show_limit := (v_limit_gb IS NOT NULL) AND (v_limit_gb - v_ymax) <= 3 * v_range;
      IF v_show_limit THEN v_ymax := GREATEST(v_ymax, v_limit_gb * 1.04); END IF;
      IF (v_ymax - v_ymin) < 0.001 THEN v_ymax := v_ymin + 1; END IF;
      v_ymax := v_ymax + (v_ymax - v_ymin) * 0.10;
      v_cross_x := NULL; v_cross_lbl := NULL;
      IF v_show_limit AND v_has_proj AND v_days_to_lim IS NOT NULL
         AND hf.last_day + v_days_to_lim - c_epoch <= v_xmax THEN
        v_cross_x := hf.last_day + v_days_to_lim - c_epoch;
        v_cross_lbl := TO_CHAR(v_pct, 'FM990') || '% &asymp; ' || dfmt(hf.last_day + v_days_to_lim);
      END IF;
      chart_svg('Whole database total size: history, projection with its 95 percent band, and allocated limit',
                v_xmin, v_xmax, v_ymin, v_ymax, 'GiB', v_last_day_n,
                CASE WHEN v_show_limit THEN v_limit_gb END,
                CASE WHEN v_show_limit THEN 'allocated ' || fmt_size_gb(v_limit_gb) END,
                CASE WHEN v_show_limit THEN hf.sat_value END,
                CASE WHEN v_show_limit THEN TO_CHAR(v_pct, 'FM990') || '% of allocated' END,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                v_cross_x, CASE WHEN v_cross_x IS NOT NULL THEN hf.sat_value END, v_cross_lbl, 250);
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
           t.last_day, t.anchor_value,
           f.proj_30_lo, f.proj_30_hi, f.proj_90_lo, f.proj_90_hi, f.proj_30, f.proj_90
    FROM   capr_cpu_trend t
    LEFT   JOIN capf_cpu_trend f ON f.dbid = t.dbid AND f.con_dbid = t.con_dbid AND f.metric = t.metric
    WHERE  t.metric = 'BUSY_P95'
      AND  (s_dbid IS NULL OR t.dbid = s_dbid) AND (s_con IS NULL OR t.con_dbid = s_con)
    ORDER  BY t.con_dbid
  ) LOOP
    v_hlabel := 'Host CPU busy-hour p95' || CASE WHEN v_con_count > 1 THEN ' (' || ch.db_pdb || ')' END;
    v_big := NULL; v_big_lbl := NULL; v_big_cls := NULL; v_accent := NULL;
    IF ch.quality = 'OK' AND ch.days_to_sat IS NOT NULL THEN
      v_big := short_dur(ch.days_to_sat);
      v_big_lbl := 'to ' || TO_CHAR(cpu_sat, 'FM990') || '% &middot; '
                   || CASE WHEN ch.sat_worst IS NOT NULL THEN TO_CHAR(ch.sat_worst, 'FM999990') || '&ndash;' || NVL(TO_CHAR(ch.sat_best, 'FM999990'), 'never')
                           ELSE '&asymp; ' || dfmt(ch.last_day + ch.days_to_sat) END;
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
      -- CAPF_CPU_TREND's own anchored line: anchor_value at last_day, then
      -- proj_30 / proj_90 and their bands, drawn as the view states them.
      IF ch.quality = 'OK' AND ch.proj_90 IS NOT NULL THEN
        px1(1) := ch.last_day - c_epoch;      py1(1) := ch.anchor_value;
        px1(2) := ch.last_day + 90 - c_epoch; py1(2) := ch.proj_90;
        v_proj_y := ch.proj_90;
        v_xmax   := GREATEST(v_xmax, px1(2));
        v_has_proj := TRUE;
        IF ch.proj_30_lo IS NOT NULL AND ch.proj_90_lo IS NOT NULL THEN
          v_nband := 2;
          bx(1) := ch.last_day + 30 - c_epoch; blo(1) := ch.proj_30_lo; bhi(1) := ch.proj_30_hi;
          bx(2) := px1(2);                     blo(2) := ch.proj_90_lo; bhi(2) := ch.proj_90_hi;
        END IF;
      END IF;
      v_ymin := 0; v_ymax := 100;
      FOR i IN 1 .. v_cnt LOOP IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF; END LOOP;
      IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
      IF v_nband = 2 AND bhi(2) > v_ymax THEN v_ymax := bhi(2); END IF;
      v_ymax := v_ymax * 1.06;
      FOR a IN (SELECT ts, value, anomaly_modes, how_hours_flagged FROM capr_series_points
                WHERE con_dbid = ch.con_dbid AND kind = 'CPU' AND series = 'BUSY_PCT' AND anomaly = 1) LOOP
        v_nanom := v_nanom + 1; ax(v_nanom) := a.ts - c_epoch; ay(v_nanom) := a.value;
        atip(v_nanom) := ring_tip(a.ts, TO_CHAR(a.value, 'FM990.0') || '% busy (daily average)', a.anomaly_modes, a.how_hours_flagged);
      END LOOP;
      v_cross_x := NULL; v_cross_lbl := NULL;
      IF ch.quality = 'OK' AND ch.days_to_sat IS NOT NULL AND ch.days_to_sat <= 90 THEN
        v_cross_x := ch.last_day + ch.days_to_sat - c_epoch;
        v_cross_lbl := TO_CHAR(cpu_sat, 'FM990') || '% &asymp; ' || dfmt(ch.last_day + ch.days_to_sat);
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
  EXCEPTION
    WHEN OTHERS THEN sec_failed('0 (at a glance)', SQLERRM);
  END;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 1: days-to-full ranking
  ----------------------------------------------------------------------
  p('<section id="s1">');
  BEGIN
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
           gate,
           quality,
           accel,
           cycle_days,
           cycle_peak_pct,
           need_gib_90,
           add_by_day
    -- LIVE: CAPR_TBSPC_DAYS_TO_FULL, its rank_dtf re-numbered inside the
    -- scope. SNAPSHOT: the TBSPC rows of CAPR_FIT_HISTORY for the last OK
    -- refresh run, ordered like rank_dtf; CAPR_FIT has no gate and one sev
    -- per tablespace (the worse of TBSPC_FULL / TBSPC_NEARFULL).
    FROM  (SELECT t.con_dbid, t.db_pdb, t.tablespace_name, t.cur_gb, t.limit_gb, t.pct_used, t.slope_mb,
                  t.days_to_full, t.dtf_worst, t.dtf_best, t.sev_dtf, t.gate, t.quality, t.accel,
                  t.cycle_days, t.cycle_peak_pct, t.need_gib_90, t.add_by_day,
                  ROW_NUMBER() OVER (ORDER BY t.rank_dtf) AS s_rank
           FROM   capr_tbspc_days_to_full t
           WHERE  v_src = 'LIVE'
             AND  (s_dbid IS NULL OR t.dbid = s_dbid) AND (s_con IS NULL OR t.con_dbid = s_con)
           UNION ALL
           SELECT h.con_dbid, h.db, h.series, h.value / 1073741824, h.limit_value / 1073741824, h.pct,
                  h.slope_per_day / 1048576, h.days_to_full, h.days_to_full_lo, h.days_to_full_hi, h.sev,
                  CAST(NULL AS VARCHAR2(8)), h.quality, h.accel, h.cycle_days, h.cycle_peak_pct,
                  h.need_gib_90, h.add_by_day,
                  ROW_NUMBER() OVER (ORDER BY CASE WHEN h.days_to_full IS NOT NULL THEN 0
                                                   WHEN h.quality = 'CYCLIC'      THEN 1 ELSE 2 END,
                                              h.days_to_full, h.con_dbid, h.series)
           FROM   capr_fit_history h
           WHERE  v_src = 'SNAPSHOT' AND h.run_id = v_snap_run AND h.kind = 'TBSPC'
             AND  (s_dbid IS NULL OR h.dbid = s_dbid) AND (s_con IS NULL OR h.con_dbid = s_con))
    -- CYCLIC rows are listed even without a days_to_full (their peak line's
    -- crossing, often empty): rank_dtf puts them after the rows that have
    -- one, so top_n bounds them like every other row.
    WHERE  (days_to_full IS NOT NULL OR quality = 'CYCLIC')
      AND  s_rank <= top_n
    ORDER  BY s_rank
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB' || info_icon('which database or container this row belongs to, relevant when one report covers a fleet (CAPR column: DB_PDB)')
        || '</th><th>Tablespace' || info_icon('CAPR column: TABLESPACE_NAME')
        || '</th><th>Used / limit' || info_icon('how much is used against its allocated limit today (CAPR columns: CUR_GB, LIMIT_GB, PCT_USED)')
        || '</th><th class="num">Growth (MiB/day)' || info_icon('the average mebibytes (MiB) this tablespace grows per day (CAPR column: SLOPE_MB)')
        || '</th><th class="num">Days to full' || info_icon('estimated days until it reaches its allocated limit at the current rate (CAPR column: DAYS_TO_FULL)')
        || '</th><th>Severity' || info_icon('the severity CAPR_ALERTS raises: CRIT within the critical window, WARN within the warning window, on an OK fit or a CYCLIC peak line; a grey tag says why a row inside the window does not page: low-q / short = fit not OK, cyclic = purge cycle judged on its peaks, stale = no longer reported, lim&lt;used = limit under the usage (CAPR columns: SEV_DTF, GATE)')
        || '</th><th>Quality' || info_icon('reliability of the estimate -- only OK is a dependable forecast (CAPR column: QUALITY)')
        || '</th><th>Sizing ask' || info_icon('space to add so the worst case (the upper 95% band) stays under the limit for 90 days, and the worst-case fill date (CAPR columns: NEED_GIB_90, ADD_BY_DAY)')
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
      || '<td>' || sev_pill(r.sev) || CASE WHEN r.gate IS NOT NULL THEN ' <span class="na">' || esc(r.gate) || '</span>' END || '</td>'
      || '<td>' || quality_pill(r.quality) || '</td>'
      || '<td>' || NVL(ask_txt(r.need_gib_90, r.add_by_day), '&ndash;') || '</td></tr>');

    v_dtf_diag_n := v_dtf_diag_n + 1;
    v_dtf_diag(v_dtf_diag_n).db_pdb          := r.db_pdb;
    v_dtf_diag(v_dtf_diag_n).tablespace_name := r.tablespace_name;
    v_dtf_diag(v_dtf_diag_n).dtf_lo          := r.days_to_full_lo;
    v_dtf_diag(v_dtf_diag_n).dtf_hi          := r.days_to_full_hi;
    v_dtf_diag(v_dtf_diag_n).accel           := r.accel;
    v_dtf_diag(v_dtf_diag_n).cycle_days      := r.cycle_days;
    v_dtf_diag(v_dtf_diag_n).cycle_peak_pct  := r.cycle_peak_pct;
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
      || '<th>Cycle' || info_icon('CYCLIC rows only: days between purges and the highest fill in the window, where the peak line starts (CAPR columns: CYCLE_DAYS, CYCLE_PEAK_PCT)') || '</th>'
      || '</tr></thead><tbody>');
    FOR i IN 1 .. v_dtf_diag_n LOOP
      p('<tr><td>' || esc(v_dtf_diag(i).db_pdb) || '</td>'
        || '<td>' || esc(v_dtf_diag(i).tablespace_name) || '</td>'
        || '<td class="num">' || nz(v_dtf_diag(i).dtf_lo, 'FM99999990') || '</td>'
        || '<td class="num">' || nz(v_dtf_diag(i).dtf_hi, 'FM99999990') || '</td>'
        || '<td class="num">' || nz(v_dtf_diag(i).accel, 'FM990.00') || '</td>'
        || '<td>' || CASE WHEN v_dtf_diag(i).cycle_days IS NOT NULL
                          THEN 'every ' || TO_CHAR(v_dtf_diag(i).cycle_days, 'FM9990') || ' d, peak '
                               || TO_CHAR(v_dtf_diag(i).cycle_peak_pct, 'FM990.0') || '%'
                          ELSE '&ndash;' END || '</td></tr>');
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
    FROM  (SELECT t.con_dbid, t.db_pdb, t.tablespace_name, t.cur_gb, t.limit_gb, t.pct_used,
                  t.days_to_full, t.sev_nearfull, t.quality,
                  ROW_NUMBER() OVER (ORDER BY t.rank_nearfull) AS s_rank
           FROM   capr_tbspc_days_to_full t
           WHERE  v_src = 'LIVE'
             AND  (s_dbid IS NULL OR t.dbid = s_dbid) AND (s_con IS NULL OR t.con_dbid = s_con)
           UNION ALL
           SELECT h.con_dbid, h.db, h.series, h.value / 1073741824, h.limit_value / 1073741824, h.pct,
                  h.days_to_full, h.sev, h.quality,
                  ROW_NUMBER() OVER (ORDER BY h.pct DESC NULLS LAST, h.con_dbid, h.series)
           FROM   capr_fit_history h
           WHERE  v_src = 'SNAPSHOT' AND h.run_id = v_snap_run AND h.kind = 'TBSPC'
             AND  (s_dbid IS NULL OR h.dbid = s_dbid) AND (s_con IS NULL OR h.con_dbid = s_con))
    WHERE  pct_used IS NOT NULL
      AND  s_rank <= top_n
    ORDER  BY s_rank
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
  EXCEPTION
    WHEN OTHERS THEN sec_failed('1 (days to full)', SQLERRM);
  END;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 2: tablespace forecast
  ----------------------------------------------------------------------
  p('<section id="s2">');
  BEGIN
  -- M7.4: the table below is bounded (is_reportable + rank_report, decided in
  -- CAPR_TBSPC_FORECAST), so say so in the heading -- exactly like the text
  -- report's section 2 header. Ranks are re-numbered inside the scope.
  SELECT COUNT(*) INTO v_ts_all FROM capr_tbspc_forecast
  WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  SELECT COUNT(*) INTO v_ts_shown
  FROM  (SELECT is_reportable, ROW_NUMBER() OVER (ORDER BY rank_report) AS s_rank
         FROM   capr_tbspc_forecast
         WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con))
  WHERE  is_reportable = 'Y' AND s_rank <= top_n;
  v_total_ts := v_ts_all;
  p('<h2>2. Tablespace forecast (GiB) '
      || '<span style="font-weight:400;color:var(--muted);font-size:12px">('
      || v_ts_shown || ' of ' || v_ts_all || ': growing, near-full, or &ge; '
      || RTRIM(TO_CHAR(min_gb, 'FM99999990.999'), '.') || ' GiB, top '
      || top_n || ')</span></h2>');
  p('<p class="desc">Where each tablespace is headed. A card for every one that needs a look, a one-line strip for the '
      || 'quiet ones, then the numbers at +30 / +90 / +180 with the 95% band and the ESM second opinion (at most +30). '
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
  -- projection and its 95% band knots are CAPF_TBSPC_FORECAST's proj_*
  -- columns as the view anchors them (cur_used at last_day), drawn as is.
  ----------------------------------------------------------------------
  IF v_total_ts = 0 THEN
    p('<div class="empty-note">No tablespace forecast data to chart.</div>');
  ELSE
    v_quiet := 0;
    p('<div class="chart-grid">');
    FOR f IN (
      SELECT r.dbid, r.con_dbid, r.db_pdb, r.tablespace_name, r.cur_bytes, r.limit_bytes, r.slope_bpd, r.quality,
             r.esm30, r.esm30_lo, r.esm30_hi, r.days_to_full, r.r2, r.cur_gb, r.limit_gb, r.s_chart,
             r.esm_horizon_days, r.esm_age_days,
             c.cur_used, c.proj_30_bytes, c.proj_90_bytes, c.proj_180_bytes, c.proj_365_bytes,
             c.proj_30_lo, c.proj_30_hi, c.proj_90_lo, c.proj_90_hi, c.proj_180_lo, c.proj_180_hi,
             c.proj_365_lo, c.proj_365_hi, c.days_to_full_lo, c.last_day, c.accel_ratio
      FROM  (SELECT x.*, ROW_NUMBER() OVER (ORDER BY x.rank_chart) AS s_chart
             FROM   capr_tbspc_forecast x
             WHERE  (s_dbid IS NULL OR x.dbid = s_dbid) AND (s_con IS NULL OR x.con_dbid = s_con)) r
      LEFT   JOIN capf_tbspc_forecast c
        ON   c.dbid = r.dbid AND c.con_dbid = r.con_dbid AND c.tablespace_name = r.tablespace_name
      WHERE  r.s_chart <= top_n
        AND  (   (r.limit_gb IS NOT NULL AND r.limit_gb > 0 AND 100 * r.cur_gb / r.limit_gb >= nf_warn)
              OR (r.quality = 'OK' AND r.days_to_full IS NOT NULL AND r.days_to_full <= 365)
              OR  r.quality IN ('LOW_CONFIDENCE', 'INSUFFICIENT_HISTORY'))
      ORDER  BY r.s_chart
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
        -- The view's anchored projection: cur_used at last_day, proj_* at
        -- last_day + h, with the proj_*_lo/hi band knots as stated.
        IF f.quality = 'OK' AND f.proj_180_bytes IS NOT NULL THEN
          px1(1) := f.last_day - c_epoch; py1(1) := f.cur_used / 1073741824;
          px1(2) := f.last_day + v_horizon - c_epoch;
          py1(2) := CASE v_horizon WHEN 365 THEN f.proj_365_bytes ELSE f.proj_180_bytes END / 1073741824;
          v_proj_y := py1(2);
          v_xmax   := GREATEST(v_xmax, px1(2));
          v_has_proj := TRUE;
          IF f.proj_30_lo IS NOT NULL THEN
            v_nband := 3;
            bx(1) := f.last_day + 30  - c_epoch; blo(1) := f.proj_30_lo  / 1073741824; bhi(1) := f.proj_30_hi  / 1073741824;
            bx(2) := f.last_day + 90  - c_epoch; blo(2) := f.proj_90_lo  / 1073741824; bhi(2) := f.proj_90_hi  / 1073741824;
            bx(3) := f.last_day + 180 - c_epoch; blo(3) := f.proj_180_lo / 1073741824; bhi(3) := f.proj_180_hi / 1073741824;
            IF v_horizon = 365 AND f.proj_365_lo IS NOT NULL THEN
              v_nband := 4;
              bx(4) := f.last_day + 365 - c_epoch; blo(4) := f.proj_365_lo / 1073741824; bhi(4) := f.proj_365_hi / 1073741824;
            END IF;
          END IF;
        END IF;
        -- ESM: the model's furthest step minus its age, the same offset
        -- CAPR_FORECAST_POINTS gives the ESM row (30 for a fresh 30-step model).
        v_esm_val := f.esm30; v_esm_lo := f.esm30_lo; v_esm_hi := f.esm30_hi;
        v_esm_lbl := NULL;
        IF v_esm_val IS NOT NULL THEN
          v_xmax := GREATEST(v_xmax, f.last_day + (f.esm_horizon_days - f.esm_age_days) - c_epoch);
          v_esm_lbl := 'ESM +' || TO_CHAR(f.esm_horizon_days - f.esm_age_days, 'FM990') || ' days: '
                       || TO_CHAR(v_esm_val, 'FM999999990.00') || ' GiB';
        END IF;

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

        FOR a IN (SELECT ts, value / 1073741824 AS gb, anomaly_modes FROM capr_series_points
                  WHERE  dbid = f.dbid AND con_dbid = f.con_dbid
                    AND  kind = 'TBSPC' AND series = f.tablespace_name AND anomaly = 1) LOOP
          v_nanom := v_nanom + 1; ax(v_nanom) := a.ts - c_epoch; ay(v_nanom) := a.gb;
          atip(v_nanom) := ring_tip(a.ts, fmt_size_gb(a.gb) || ' used', a.anomaly_modes, NULL);
        END LOOP;
        v_cross_x := NULL; v_cross_lbl := NULL;
        IF v_show_limit AND f.quality = 'OK' AND f.days_to_full IS NOT NULL AND f.days_to_full <= v_horizon THEN
          v_cross_x := f.last_day + f.days_to_full - c_epoch;
          v_cross_lbl := 'full &asymp; ' || dfmt(NVL(f.last_day, SYSDATE) + f.days_to_full);
        END IF;
        chart_svg(esc(f.tablespace_name) || ' growth: history, projection with its 95 percent band, and the allocated limit',
                  v_xmin, v_xmax, v_ymin, v_ymax, 'GiB', v_last_day_n,
                  CASE WHEN v_show_limit THEN v_limit_gb END,
                  CASE WHEN v_show_limit THEN 'ceiling ' || fmt_size_gb(v_limit_gb) END,
                  NULL, NULL,
                  CASE WHEN v_esm_val IS NOT NULL THEN f.last_day + (f.esm_horizon_days - f.esm_age_days) - c_epoch END,
                  v_esm_val, v_esm_lo, v_esm_hi,
                  NULL, NULL, NULL,
                  v_cross_x, CASE WHEN v_show_limit THEN v_limit_gb END, v_cross_lbl);
        IF v_limit_gb IS NOT NULL AND NOT v_show_limit THEN
          p('<div class="chart-sub">ceiling hidden: ' || fmt_size_gb(v_limit_gb) || ' is off the chart scale</div>');
        END IF;
      END IF;
      p('</div>');  -- .chart-card
    END LOOP;
    v_esm_lbl := NULL;
    p('</div>');  -- .chart-grid

    -- Quiet strip: one row per tablespace not charted above.
    FOR f IN (
      SELECT r.dbid, r.con_dbid, r.db_pdb, r.tablespace_name, r.quality, r.days_to_full, r.cur_gb, r.limit_gb, r.slope_bpd
      FROM  (SELECT x.*, ROW_NUMBER() OVER (ORDER BY x.rank_chart) AS s_chart
             FROM   capr_tbspc_forecast x
             WHERE  (s_dbid IS NULL OR x.dbid = s_dbid) AND (s_con IS NULL OR x.con_dbid = s_con)) r
      WHERE  NOT (r.s_chart <= top_n
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
           esm30,
           esm_horizon_days - esm_age_days AS esm_h
    FROM  (SELECT t.*, ROW_NUMBER() OVER (ORDER BY t.rank_report) AS s_rank
           FROM   capr_tbspc_forecast t
           WHERE  (s_dbid IS NULL OR t.dbid = s_dbid) AND (s_con IS NULL OR t.con_dbid = s_con))
    WHERE  is_reportable = 'Y'
      AND  s_rank <= top_n
    ORDER  BY s_rank
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
        || '</th><th class="num">ESM (GiB)' || info_icon('a second, machine-learning estimate of the size at the model&#39;s furthest step, at most 30 days out, shown as at +N -- usually the most accurate short-term number when present (CAPR columns: ESM30, ESM_HORIZON_DAYS - ESM_AGE_DAYS)')
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
                                    ELSE nz(r.esm30) || ' <span class="dim">at +' || TO_CHAR(r.esm_h, 'FM990') || '</span>' END || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="empty-note">No tablespace forecast rows found.</div>');
  END IF;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('2 (tablespace forecast)', SQLERRM);
  END;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 3: tablespace growth anomalies
  ----------------------------------------------------------------------
  p('<section id="s3">');
  BEGIN
  p('<h2>3. Unusual tablespace days <span style="font-weight:400;color:var(--muted);font-size:12px">(last '
      || anomaly_days || ' days)</span></h2>');
  p('<p class="desc">Days when a tablespace grew or shrank much faster than its own normal pace, judged twice: against the last '
      || TO_CHAR(mad_window, 'FM9990') || ' days and against the same weekday over the last ' || TO_CHAR(dow_wk, 'FM9990')
      || ' weeks. One strip per series: red = grew, blue = shrank, bigger = further outside normal. '
      || 'The numbers behind every dot, one row per baseline that flagged it, are in the fold.</p>');

  SELECT MAX(day_dt) INTO v_win_hi FROM capd_tbspc_daily
  WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  v_strip_n := 0;
  IF v_win_hi IS NOT NULL THEN
    v_win_lo := v_win_hi - anomaly_days;
    v_xmin := v_win_lo - c_epoch; v_xmax := v_win_hi - c_epoch;
    FOR ln IN (
      SELECT con_dbid, tablespace_name, db_pdb, COUNT(DISTINCT day_dt) AS n_all,
             COUNT(DISTINCT CASE WHEN anomaly_flag = 'HIGH' THEN day_dt END) AS n_hi,
             COUNT(DISTINCT CASE WHEN anomaly_flag = 'LOW'  THEN day_dt END) AS n_lo,
             MAX(ABS(delta_mb)) AS max_delta, MAX(ABS(z)) AS max_z
      FROM   capr_tbspc_anomalies
      WHERE  days_ago < anomaly_days
        AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
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
      -- one dot per day: the baseline with the largest |z| sizes it, the
      -- others are named in the tooltip
      FOR a IN (SELECT day_dt, day_str, delta_mb, med_mb, z, anomaly_flag, baseline_mode, n_modes
                FROM  (SELECT t.*,
                              ROW_NUMBER() OVER (PARTITION BY day_dt ORDER BY ABS(z) DESC NULLS LAST, mode_rank) AS rn,
                              COUNT(*) OVER (PARTITION BY day_dt) AS n_modes
                       FROM   capr_tbspc_anomalies t
                       WHERE  con_dbid = ln.con_dbid AND tablespace_name = ln.tablespace_name AND days_ago < anomaly_days)
                WHERE rn = 1) LOOP
        v_tip := a.day_str || ': ' || CASE WHEN a.delta_mb >= 0 THEN 'grew ' ELSE 'shrank ' END
                 || fmt_size_gb(ABS(a.delta_mb) / 1024) || ' (usual ' || fmt_rate_mb(NVL(a.med_mb, 0)) || ' '
                 || mode_phrase(a.baseline_mode, a.day_dt) || '), robust z ' || TO_CHAR(a.z, 'FM99990.0')
                 || CASE WHEN a.n_modes > 1 THEN '; both baselines flagged it' END;
        p('<circle class="' || CASE WHEN a.anomaly_flag = 'HIGH' THEN 'sd-hi' ELSE 'sd-lo' END
          || '" cx="' || fmt_px(lin(a.day_dt - c_epoch, v_xmin, v_xmax, 4, 896)) || '" cy="15" r="'
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
    SELECT db_pdb, tablespace_name, day_str AS day_dt, baseline_mode, gap, delta_mb, rate_mb, med_mb, thr_mb, z,
           pct_vs_med, pct_vs_avg, anomaly_flag
    FROM   capr_tbspc_anomalies
    WHERE  days_ago < anomaly_days
      AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
    ORDER  BY con_dbid, tablespace_name, days_ago, mode_rank
  ) LOOP
    IF NOT any_rows THEN
      p('<details class="fold"><summary>The numbers behind every dot</summary><div class="fold-body">');
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Tablespace' || info_icon('CAPR column: TABLESPACE_NAME')
        || '</th><th>Day' || info_icon('CAPR column: DAY_DT')
        || '</th><th>Baseline' || info_icon('what the day was compared against: the last '
           || TO_CHAR(mad_window, 'FM9990') || ' days, or the same weekday over the last '
           || TO_CHAR(dow_wk, 'FM9990') || ' weeks (CAPR column: BASELINE_MODE)')
        || '</th><th class="num">Gap' || info_icon('days since the previous sample -- a big gap can inflate a one-day change (CAPR column: GAP)')
        || '</th><th class="num">Delta (MiB)' || info_icon('CAPR column: DELTA_MB')
        || '</th><th class="num">Rate (MiB/day)' || info_icon('how fast it grew that day, in mebibytes (MiB) per day (CAPR column: RATE_MB)')
        || '</th><th class="num">Median (MiB/day)' || info_icon('its usual daily growth rate on that baseline (CAPR column: MED_MB)')
        || '</th><th class="num">Threshold (MiB/day)' || info_icon('how far from usual a day must be before it is flagged (CAPR column: THR_MB)')
        || '</th><th class="num">Robust z' || info_icon('how far outside its normal range this day was -- 3 or more is clearly unusual (CAPR column: Z)')
        || '</th><th class="num">vs median %' || info_icon('how much faster (+) or slower (-) it grew that day than its usual daily rate, in percent -- +25 means 25% more (CAPR column: PCT_VS_MED)')
        || '</th><th class="num">vs avg %' || info_icon('the same comparison against its average daily growth over the previous '
           || TO_CHAR(train_days, 'FM9990') || ' days (CAPR column: PCT_VS_AVG)')
        || '</th><th>Flag' || info_icon('the direction of the flagged change for this day (CAPR column: ANOMALY_FLAG)') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(r.db_pdb) || '</td><td>' || esc(r.tablespace_name) || '</td><td style="white-space:nowrap">' || r.day_dt || '</td>'
      || '<td style="white-space:nowrap">' || mode_label(r.baseline_mode) || '</td>'
      || '<td class="num">' || nz(r.gap, 'FM990') || '</td>'
      || '<td class="num">' || nz(r.delta_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.rate_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.med_mb, 'FM9999990.0') || '</td>'
      || '<td class="num">' || nz(r.thr_mb, 'FM9999990.0') || '</td>'
      || '<td class="num' || (CASE WHEN ABS(NVL(r.z,0)) >= 3 THEN ' z-hi' ELSE '' END) || '">'
         || nz(r.z, 'FM99990.0') || '</td>'
      || '<td class="num">' || nz(r.pct_vs_med, 'FMS999999999990') || '</td>'
      || '<td class="num">' || nz(r.pct_vs_avg, 'FMS999999999990') || '</td>'
      || '<td class="' || CASE WHEN r.anomaly_flag = 'HIGH' THEN 'sev-crit' ELSE 'sev-ok' END || '">' || esc(r.anomaly_flag) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div></div></details>');
  ELSE
    p('<div class="glance-ok">No unusual tablespace days in the last ' || TO_CHAR(anomaly_days, 'FM999990') || ' days.</div>');
  END IF;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('3 (unusual tablespace days)', SQLERRM);
  END;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 4: CPU trend
  ----------------------------------------------------------------------
  p('<section id="s4">');
  BEGIN
  p('<h2>4. CPU trend</h2>');
  p('<p class="desc">How busy the host has been and when it runs out of headroom. The busy-hour p95 is what '
      || 'saturates; each container''s DB CPU is shown as a share of the host''s cores, with any sustained level '
      || 'shift shaded. The table has every metric, including the daily average and peak window.</p>');

  ----------------------------------------------------------------------
  -- Chart grid: one busy% card (history + saturation threshold + REGR
  -- projection to +90 + anomaly dots) and one DB CPU % of cores card
  -- (history + REGR projection to +90 + anomaly dots + level-shift shading)
  -- per con_dbid.
  -- Note (fleet/warehouse edge case): like the existing section 4/5 tables,
  -- this groups by con_dbid only, matching CAPF_CPU_TREND/CAPD_*_DAILY's own
  -- grouping; a con_dbid shared by more than one dbid (uncommon) would blend
  -- those dbids' days into one history line and pick one dbid's trend row
  -- arbitrarily for the projection.
  ----------------------------------------------------------------------
  SELECT COUNT(*) INTO v_total_ts FROM dual
  WHERE  EXISTS (SELECT 1 FROM capd_cpu_daily
                 WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con))
     OR  EXISTS (SELECT 1 FROM capd_dbtime_daily
                 WHERE (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con));
  IF v_total_ts = 0 THEN
    p('<div class="empty-note">No daily CPU history collected yet to chart.</div>');
  ELSE
    p('<div class="chart-grid">');
    FOR cd IN (SELECT con_dbid FROM (
                 SELECT DISTINCT con_dbid FROM capd_cpu_daily
                 WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
                 UNION
                 SELECT DISTINCT con_dbid FROM capd_dbtime_daily
                 WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
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
        v_proj_y := NULL; v_cross_x := NULL; v_has_proj := FALSE;
        FOR t IN (SELECT t.slope_per_day, t.quality, t.days_to_sat, t.sat_worst, t.sat_best, t.r2, t.cur_val,
                         t.last_day, t.anchor_value, f.proj_90,
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
                                 ELSE '&asymp; ' || dfmt(t.last_day + t.days_to_sat) END;
            v_big_cls := CASE WHEN t.days_to_sat <= dtf_crit THEN 'crit' WHEN t.days_to_sat <= dtf_warn THEN 'warn' ELSE 'ok' END;
            v_accent  := CASE WHEN t.days_to_sat <= dtf_crit THEN 'crit' WHEN t.days_to_sat <= dtf_warn THEN 'warn' END;
          END IF;
          -- CAPF_CPU_TREND's anchored line and bands, as the view states them
          IF t.quality = 'OK' AND t.proj_90 IS NOT NULL THEN
            px1(1) := t.last_day - c_epoch;      py1(1) := t.anchor_value;
            px1(2) := t.last_day + 90 - c_epoch; py1(2) := t.proj_90;
            v_proj_y := t.proj_90; v_has_proj := TRUE;
            IF t.days_to_sat IS NOT NULL AND t.days_to_sat <= 90 THEN
              v_cross_x := t.last_day + t.days_to_sat - c_epoch;
              v_cross_lbl := TO_CHAR(cpu_sat, 'FM990') || '% &asymp; ' || dfmt(t.last_day + t.days_to_sat);
            END IF;
            IF t.proj_30_lo IS NOT NULL AND t.proj_90_lo IS NOT NULL THEN
              v_nband := 2;
              bx(1) := t.last_day + 30 - c_epoch; blo(1) := t.proj_30_lo; bhi(1) := t.proj_30_hi;
              bx(2) := px1(2);                    blo(2) := t.proj_90_lo; bhi(2) := t.proj_90_hi;
            END IF;
          END IF;
        END LOOP;
        card_open('Host CPU busy-hour p95 <span class="dim" style="font-weight:400">' || esc(db_label(NULL, cd.con_dbid)) || '</span> '
                  || CASE WHEN v_quality IS NOT NULL THEN quality_pill(v_quality) END,
                  'p95 of the day''s hourly intervals, what actually saturates &middot; faint line = daily average'
                  || CASE WHEN v_n IS NOT NULL THEN ' &middot; R2 ' || TO_CHAR(v_n, 'FM0.00') END,
                  v_big, v_big_lbl, v_big_cls, v_accent, NULL);
        v_xmin := xs(1); v_xmax := xs(v_cnt); v_last_day_n := xs(v_cnt);
        IF v_has_proj THEN
          v_xmax := GREATEST(v_xmax, px1(2));
        ELSE
          v_nband := 0;
        END IF;
        v_ymin := 0; v_ymax := 100;
        FOR i IN 1 .. v_cnt LOOP IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF; END LOOP;
        IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
        FOR i IN 1 .. v_nband LOOP IF bhi(i) > v_ymax THEN v_ymax := bhi(i); END IF; END LOOP;
        v_ymax := v_ymax * 1.06;
        FOR a IN (SELECT ts, value, anomaly_modes, how_hours_flagged FROM capr_series_points
                  WHERE con_dbid = cd.con_dbid AND kind = 'CPU' AND series = 'BUSY_PCT' AND anomaly = 1) LOOP
          v_nanom := v_nanom + 1; ax(v_nanom) := a.ts - c_epoch; ay(v_nanom) := a.value;
          atip(v_nanom) := ring_tip(a.ts, TO_CHAR(a.value, 'FM990.0') || '% busy (daily average)', a.anomaly_modes, a.how_hours_flagged);
        END LOOP;
        chart_svg('Host CPU busy-hour p95 for ' || esc(db_label(NULL, cd.con_dbid)) || ' with projection and saturation line',
                  v_xmin, v_xmax, v_ymin, v_ymax, '%', v_last_day_n,
                  NULL, NULL, cpu_sat, 'saturation ' || TO_CHAR(cpu_sat, 'FM990') || '%',
                  NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                  v_cross_x, cpu_sat, v_cross_lbl);
        p('</div>');
      END IF;

      -- ---- DB CPU as % of host cores: comparable to the busy% chart, and the
      --      metric the level-shift test scores, so a sustained step is shaded here ----
      xs.DELETE; ys.DELETE; xs2.DELETE; ys2.DELETE; v_cnt := 0; v_cnt2 := 0; v_nband := 0; v_nanom := 0; v_has_proj := FALSE;
      FOR h IN (SELECT day_dt, db_cpu_pct FROM capd_dbtime_daily
                WHERE con_dbid = cd.con_dbid AND db_cpu_pct IS NOT NULL ORDER BY day_dt) LOOP
        v_cnt := v_cnt + 1; xs(v_cnt) := h.day_dt - c_epoch; ys(v_cnt) := h.db_cpu_pct;
      END LOOP;
      IF v_cnt > 0 THEN
        v_quality := NULL; v_slope := NULL; v_dtf := NULL; v_n := NULL;
        v_big := NULL; v_big_lbl := NULL; v_big_cls := NULL; v_accent := NULL;
        v_shift_from := NULL; v_shift_to := NULL; v_shift_lbl := NULL;
        v_proj_y := NULL;
        FOR t IN (SELECT t.slope_per_day, t.quality, t.days_to_sat, t.r2, t.last_day, t.anchor_value, f.proj_90
                  FROM capr_cpu_trend t
                  LEFT JOIN capf_cpu_trend f ON f.dbid = t.dbid AND f.con_dbid = t.con_dbid AND f.metric = t.metric
                  WHERE t.con_dbid = cd.con_dbid AND t.metric = 'DB_CPU_PCT'
                    AND (s_dbid IS NULL OR t.dbid = s_dbid)
                  ORDER BY t.dbid FETCH FIRST 1 ROW ONLY) LOOP
          v_quality := t.quality; v_slope := t.slope_per_day; v_dtf := t.days_to_sat; v_n := t.r2;
          -- the view's anchored line (no band on this card)
          IF t.quality = 'OK' AND t.proj_90 IS NOT NULL THEN
            px1(1) := t.last_day - c_epoch;      py1(1) := t.anchor_value;
            px1(2) := t.last_day + 90 - c_epoch; py1(2) := t.proj_90;
            v_proj_y := t.proj_90; v_has_proj := TRUE;
          END IF;
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
        v_xmin := xs(1); v_xmax := xs(v_cnt); v_last_day_n := xs(v_cnt);
        IF v_has_proj THEN v_xmax := GREATEST(v_xmax, px1(2)); END IF;
        v_ymin := 0; v_ymax := 0;
        FOR i IN 1 .. v_cnt LOOP IF ys(i) > v_ymax THEN v_ymax := ys(i); END IF; END LOOP;
        IF v_proj_y IS NOT NULL AND v_proj_y > v_ymax THEN v_ymax := v_proj_y; END IF;
        -- keep the saturation line in view when the series is within reach of it
        IF v_ymax >= cpu_sat * 0.35 THEN v_ymax := GREATEST(v_ymax, cpu_sat); END IF;
        IF v_ymax < 1 THEN v_ymax := 1; END IF;
        v_ymax := v_ymax * 1.08;
        FOR a IN (SELECT ts, value, anomaly_modes, how_hours_flagged FROM capr_series_points
                  WHERE con_dbid = cd.con_dbid AND kind = 'CPU' AND series = 'DB_CPU_PCT' AND anomaly = 1) LOOP
          v_nanom := v_nanom + 1; ax(v_nanom) := a.ts - c_epoch; ay(v_nanom) := a.value;
          atip(v_nanom) := ring_tip(a.ts, TO_CHAR(a.value, 'FM990.0') || '% of host cores', a.anomaly_modes, a.how_hours_flagged);
        END LOOP;
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
           quality,
           anchor_value,
           slope_sig,
           hot_now,
           sev,
           gate
    FROM   capr_cpu_trend
    WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
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
        || '</th><th>Quality' || info_icon('OK = the slope is outside its own 95% range when cpu_quality_gate = 1 (default), else R2 at or above r2_gate (CAPR column: QUALITY)')
        || '</th><th class="num">Anchor' || info_icon('median of the last shift_days complete days, where projections and days to saturation start (CAPR column: ANCHOR_VALUE)')
        || '</th><th>Sig.' || info_icon('Y when the slope is outside its own 95% range (CAPR column: SLOPE_SIG)')
        || '</th><th>Hot now' || info_icon('BUSY_P95 / DB_CPU_P95 only: Y when the recent busy-hour median is at or above the saturation threshold (CAPR column: HOT_NOW)')
        || '</th><th>Severity' || info_icon('the severity CAPR_ALERTS raises for this metric: CPU_SAT / DBCPU_SAT on an OK trend inside the warning window, CPU_HOT / DBCPU_HOT when hot now; a grey tag says why a would-be CPU_SAT / DBCPU_SAT does not page (CAPR columns: SEV, GATE)')
        || '</th></tr></thead><tbody>');
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
      || '<td>' || quality_pill(r.quality) || '</td>'
      || '<td class="num">' || nz(r.anchor_value, 'FM99999990.00') || '</td>'
      || '<td>' || esc(r.slope_sig) || '</td>'
      || '<td>' || CASE r.hot_now WHEN 'Y' THEN '<span class="sev-crit">Y</span>'
                                  WHEN 'N' THEN 'N' ELSE '&ndash;' END || '</td>'
      || '<td>' || sev_pill(r.sev) || CASE WHEN r.gate IS NOT NULL THEN ' <span class="na">' || esc(r.gate) || '</span>' END || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="empty-note">No CPU trend rows found.</div>');
  END IF;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('4 (CPU trend)', SQLERRM);
  END;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 5: CPU anomalies
  ----------------------------------------------------------------------
  p('<section id="s5">');
  BEGIN
  p('<h2>5. Unusual CPU days <span style="font-weight:400;color:var(--muted);font-size:12px">'
      || 'vs trailing / same-weekday / hour-of-week baselines, last ' || anomaly_days || ' days</span></h2>');
  p('<p class="desc">Days and hours when the host, or a container''s DB CPU, was much busier (red) or quieter (blue) than usual. '
      || 'Each day is judged against the last ' || TO_CHAR(mad_window, 'FM9990') || ' days and against the same weekday over the last '
      || TO_CHAR(dow_wk, 'FM9990') || ' weeks; each hour against the same hour of the week over those weeks. '
      || 'Then the sustained level shifts a single-day test cannot see.</p>');

  SELECT MAX(day_dt) INTO v_win_hi FROM capd_cpu_daily
  WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con);
  v_strip_n := 0;
  IF v_win_hi IS NOT NULL THEN
    v_win_lo := v_win_hi - anomaly_days;
    v_xmin := v_win_lo - c_epoch; v_xmax := v_win_hi - c_epoch;
    FOR ln IN (
      SELECT con_dbid, db_pdb, metric, COUNT(DISTINCT grain || TO_CHAR(ts, 'YYYYMMDDHH24')) AS n_all,
             COUNT(DISTINCT CASE WHEN anomaly_flag = 'HIGH' THEN grain || TO_CHAR(ts, 'YYYYMMDDHH24') END) AS n_hi,
             COUNT(DISTINCT CASE WHEN anomaly_flag = 'LOW'  THEN grain || TO_CHAR(ts, 'YYYYMMDDHH24') END) AS n_lo,
             MAX(value_pct) AS max_busy
      FROM   capr_cpu_anomalies
      WHERE  days_ago < anomaly_days
        AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
      GROUP  BY con_dbid, db_pdb, metric
      ORDER  BY n_all DESC, con_dbid, metric
    ) LOOP
      v_strip_n := v_strip_n + 1;
      IF v_strip_n = 1 THEN p('<div class="strips">'); END IF;
      p('<div class="strip"><div class="sl"><b>' || CASE ln.metric WHEN 'BUSY_PCT' THEN 'Host CPU' ELSE 'DB CPU' END || '</b>'
        || CASE WHEN v_con_count > 1 OR ln.metric <> 'BUSY_PCT' THEN ' <span class="dim">' || esc(ln.db_pdb) || '</span>' END
        || '<span>' || CASE WHEN ln.n_hi > 0 THEN TO_CHAR(ln.n_hi, 'FM990') || ' busier' END
        || CASE WHEN ln.n_hi > 0 AND ln.n_lo > 0 THEN ' &middot; ' END
        || CASE WHEN ln.n_lo > 0 THEN TO_CHAR(ln.n_lo, 'FM990') || ' quieter' END
        || ' &middot; busiest ' || TO_CHAR(ln.max_busy, 'FM990') || '%</span></div>');
      strip_open(v_xmin, v_xmax);
      -- one dot per day or hour: the day baseline with the largest |z| sizes
      -- a day dot, the other is named in the tooltip
      FOR a IN (SELECT ts, ts_str, value_pct, median_pct, z, anomaly_flag, baseline_mode, n_modes
                FROM  (SELECT t.*,
                              ROW_NUMBER() OVER (PARTITION BY grain, ts ORDER BY ABS(z) DESC NULLS LAST, mode_rank) AS rn,
                              COUNT(*) OVER (PARTITION BY grain, ts) AS n_modes
                       FROM   capr_cpu_anomalies t
                       WHERE  con_dbid = ln.con_dbid AND metric = ln.metric AND days_ago < anomaly_days)
                WHERE rn = 1) LOOP
        v_tip := a.ts_str || ': ' || TO_CHAR(a.value_pct, 'FM990')
                 || CASE ln.metric WHEN 'BUSY_PCT' THEN '% busy' ELSE '% of host cores' END || ' vs the usual '
                 || TO_CHAR(a.median_pct, 'FM990') || '% ' || mode_phrase(a.baseline_mode, a.ts)
                 || ', robust z ' || TO_CHAR(a.z, 'FM99990.0')
                 || CASE WHEN a.n_modes > 1 THEN '; both day baselines flagged it' END;
        p('<circle class="' || CASE WHEN a.anomaly_flag = 'HIGH' THEN 'sd-hi' ELSE 'sd-lo' END
          || '" cx="' || fmt_px(lin(a.ts - c_epoch, v_xmin, v_xmax, 4, 896)) || '" cy="15" r="'
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
    SELECT db_pdb, metric, baseline_mode, ts_str, value_pct, median_pct, threshold_pct, z, pct_vs_med, anomaly_flag
    FROM   capr_cpu_anomalies
    WHERE  days_ago < anomaly_days
      AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
    ORDER  BY days_ago, con_dbid, metric, mode_rank, ts
  ) LOOP
    IF NOT any_rows THEN
      p('<details class="fold"><summary>The numbers behind every dot</summary><div class="fold-body">');
      p('<div class="tscroll">');
      p('<table class="tbl"><thead><tr>'
        || '<th>DB/PDB</th><th>Metric' || info_icon('BUSY_PCT = host busy percent, DB_CPU_PCT = the container''s DB CPU as a percent of host cores (CAPR column: METRIC)')
        || '</th><th>Baseline' || info_icon('what it was compared against: the last ' || TO_CHAR(mad_window, 'FM9990')
           || ' days or the same weekday (per day), or the same hour of the week (per hour) (CAPR column: BASELINE_MODE)')
        || '</th><th>When' || info_icon('the day, or for an hour row the day, weekday and END hour (CAPR column: TS_STR)')
        || '</th><th class="num">Value %' || info_icon('CAPR column: VALUE_PCT')
        || '</th><th class="num">Median %' || info_icon('the usual value on that baseline (CAPR column: MEDIAN_PCT)')
        || '</th><th class="num">Threshold %' || info_icon('how far from usual a day must be before it is flagged (CAPR column: THRESHOLD_PCT)')
        || '</th><th class="num">Robust z' || info_icon('how far outside its normal range this day was -- 3 or more is clearly unusual (CAPR column: Z)')
        || '</th><th class="num">vs median %' || info_icon('how much busier (+) or quieter (-) it was than usual on that baseline, in percent -- +25 means 25% more (CAPR column: PCT_VS_MED)')
        || '</th><th>Flag' || info_icon('CAPR column: ANOMALY_FLAG') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(r.db_pdb) || '</td><td>' || esc(r.metric) || '</td>'
      || '<td style="white-space:nowrap">' || mode_label(r.baseline_mode) || '</td>'
      || '<td style="white-space:nowrap">' || esc(r.ts_str) || '</td>'
      || '<td class="num">' || nz(r.value_pct, 'FM9990.00') || '</td>'
      || '<td class="num">' || nz(r.median_pct, 'FM9990.00') || '</td>'
      || '<td class="num">' || nz(r.threshold_pct, 'FM9990.00') || '</td>'
      || '<td class="num' || (CASE WHEN ABS(NVL(r.z,0)) >= 3 THEN ' z-hi' ELSE '' END) || '">'
         || nz(r.z, 'FM99990.0') || '</td>'
      || '<td class="num">' || nz(r.pct_vs_med, 'FMS999999999990') || '</td>'
      || '<td class="' || CASE WHEN r.anomaly_flag = 'HIGH' THEN 'sev-crit' ELSE 'sev-ok' END || '">' || esc(r.anomaly_flag) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div></div></details>');
  ELSE
    p('<div class="glance-ok">No unusual CPU days or hours in the last ' || TO_CHAR(anomaly_days, 'FM999990') || ' days.</div>');
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
    WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
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
  EXCEPTION
    WHEN OTHERS THEN sec_failed('5 (unusual CPU days)', SQLERRM);
  END;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 6: ESM vs REGR compare (dispatch identical to report.sql /
  -- 06_esm_compare.sql / 06_esm_skip.sql)
  ----------------------------------------------------------------------
  p('<section id="s6">');
  BEGIN
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
        || 'few weeks. OML ESM forecast models: ' || esm_ok || ' ok, ' || esm_failed || ' failed, ' || esm_stale || ' stale. '
        || 'The ESM value is the model&#39;s furthest step, at most +30 on 19c; when that is not +30 (short history) the '
        || 'step is shown beside it, and models older than esm_max_age_days are left out. The +90 / +180 / +365 '
        || 'numbers in section 2 are REGR-only. HOLT = EXSM_HOLT, ADDW = EXSM_ADDWINTERS with a 7-day season.</p>');

    any_rows := FALSE;
    FOR r IN (
      SELECT c.db_pdb, c.series_kind, c.series_key, c.con_dbid,
             CASE WHEN c.series_kind = 'TBSPC' THEN c.regr_gb   ELSE c.regr   END AS regr,
             CASE WHEN c.series_kind = 'TBSPC' THEN c.esm_gb    ELSE c.esm    END AS esm,
             CASE WHEN c.series_kind = 'TBSPC' THEN c.esm_lo_gb ELSE c.esm_lo END AS esm_lo,
             CASE WHEN c.series_kind = 'TBSPC' THEN c.esm_hi_gb ELSE c.esm_hi END AS esm_hi,
             c.esm_model, c.rank_report, c.esm_at, c.esm_age_days,
             b.regr_mape, b.esm_mape, b.better, b.esm_pick
      FROM   capr_esm_compare c
      LEFT   JOIN capr_backtest b
        ON   b.dbid = c.dbid AND b.con_dbid = c.con_dbid AND b.series_kind = c.series_kind AND b.series_key = c.series_key
      -- section 2's scoped rank, so the same tablespaces appear
      LEFT   JOIN (SELECT dbid, con_dbid, tablespace_name,
                          ROW_NUMBER() OVER (ORDER BY rank_report) AS s_rank
                   FROM   capr_tbspc_forecast
                   WHERE  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)) sr
        ON   c.series_kind = 'TBSPC'
       AND   sr.dbid = c.dbid AND sr.con_dbid = c.con_dbid AND sr.tablespace_name = c.series_key
      WHERE  c.horizon_days = 30
        AND  (s_dbid IS NULL OR c.dbid = s_dbid) AND (s_con IS NULL OR c.con_dbid = s_con)
        AND  (c.series_kind = 'CPU' OR (c.is_reportable = 'Y' AND sr.s_rank <= top_n))
        AND  (c.series_kind = 'TBSPC' OR c.series_key IN ('BUSY_PCT', 'BUSY_P95', 'DB_CPU_SEC', 'DB_CPU_PCT'))
      ORDER  BY CASE c.series_kind WHEN 'TBSPC' THEN 0 ELSE 1 END, NVL(sr.s_rank, 999), c.con_dbid, c.series_key
    ) LOOP
      IF NOT any_rows THEN
        p('<div class="tscroll">');
        p('<table class="tbl"><thead><tr>'
          || '<th>Series' || info_icon('tablespaces in GiB (the same ones as section 2), CPU metrics in their own unit (CAPR column: SERIES_KEY)')
          || '</th><th class="num">REGR +30' || info_icon('straight-line projection 30 days out (CAPR column: REGR_GB / REGR)')
          || '</th><th class="num">ESM +30' || info_icon('the Oracle ML forecast 30 days out, or at its furthest step when that is shorter, shown as at +N (CAPR columns: ESM_GB / ESM, ESM_AT)')
          || '</th><th class="num">ESM 95% band' || info_icon('CAPR columns: ESM_LO, ESM_HI')
          || '</th><th class="num">Gap' || info_icon('ESM minus REGR as a percent of REGR; a large gap means the two engines disagree about the near future')
          || '</th><th>ESM model' || info_icon('HOLT = trend only; ADDW = trend plus a 7-day season; the age is days between the model&#39;s last training day and the data&#39;s (CAPR columns: ESM_MODEL, ESM_AGE_DAYS)')
          || '</th><th class="num">Backtest MAPE, REGR / ESM' || info_icon('average percent miss of each engine over the held-out window before today; lower is better (CAPR columns: REGR_MAPE, ESM_MAPE)')
          || '</th><th>Right last month' || info_icon('which engine had the lower backtest error, and which ESM variant AUTO picked and why (CAPR columns: BETTER, ESM_PICK)')
          || '</th></tr></thead><tbody>');
        any_rows := TRUE;
      END IF;
      v_gap_pct := CASE WHEN r.regr IS NOT NULL AND r.esm IS NOT NULL AND r.regr <> 0 THEN 100 * (r.esm - r.regr) / ABS(r.regr) END;
      p('<tr><td><b>' || esc(r.series_key) || '</b>' || CASE WHEN v_con_count > 1 OR r.series_kind = 'CPU' THEN ' <span class="dim">' || esc(r.db_pdb) || '</span>' END || '</td>'
        || '<td class="num">' || nz(r.regr, CASE WHEN r.series_kind = 'TBSPC' THEN 'FM999999990.0' ELSE 'FM99999990.00' END) || '</td>'
        || '<td class="num">' || CASE WHEN r.esm IS NULL THEN '<span class="na">no model</span>'
                                      ELSE nz(r.esm, CASE WHEN r.series_kind = 'TBSPC' THEN 'FM999999990.0' ELSE 'FM99999990.00' END)
                                           || CASE WHEN r.esm_at IS NOT NULL THEN ' <span class="dim">at ' || esc(r.esm_at) || '</span>' END END || '</td>'
        || '<td class="num dim">' || CASE WHEN r.esm_lo IS NULL THEN '&ndash;'
                                          ELSE nz(r.esm_lo, CASE WHEN r.series_kind = 'TBSPC' THEN 'FM999999990.0' ELSE 'FM99999990.00' END)
                                               || ' &ndash; ' || nz(r.esm_hi, CASE WHEN r.series_kind = 'TBSPC' THEN 'FM999999990.0' ELSE 'FM99999990.00' END) END || '</td>'
        || '<td class="num' || CASE WHEN ABS(v_gap_pct) >= 10 THEN ' gap-hi' END || '">'
        || CASE WHEN v_gap_pct IS NULL THEN '&ndash;' ELSE CASE WHEN v_gap_pct >= 0 THEN '+' END || TO_CHAR(v_gap_pct, 'FM9990.0') || '%' END || '</td>'
        || '<td>' || NVL(esc(r.esm_model), '&ndash;')
        || CASE WHEN r.esm_age_days IS NOT NULL THEN ' <span class="dim">' || TO_CHAR(r.esm_age_days, 'FM9990') || 'd old</span>' END || '</td>'
        || '<td class="num">' || CASE WHEN r.regr_mape IS NULL THEN '&ndash;' ELSE nz(r.regr_mape, 'FM99990.00') END
        || ' / ' || CASE WHEN r.esm_mape IS NULL THEN '&ndash;' ELSE nz(r.esm_mape, 'FM99990.00') END || '</td>'
        || '<td class="nowrap">' || CASE WHEN r.better IS NULL THEN '&ndash;'
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
  EXCEPTION
    WHEN OTHERS THEN sec_failed('6 (ESM vs REGR)', SQLERRM);
  END;
  p('</section>');

  ----------------------------------------------------------------------
  -- Section 7: fixed-ceiling series (M11) -- processes / sessions / redo /
  -- total DB size. Deliberately minimal: one table straight off CAPR_SERIES,
  -- the same view report/sections/07_series.sql reads.
  ----------------------------------------------------------------------
  p('<section id="s7">');
  BEGIN
  p('<h2>7. Fixed-ceiling series '
      || info_icon('peak processes and sessions against the init parameters, redo written per day, total database size against the summed tablespace ceilings, ASM diskgroups, and TEMP / UNDO peaks')
      || '</h2>');
  p('<p class="desc">Series with a hard ceiling that is not a tablespace; a dash in Days to limit means no crossing at the current trend. '
      || 'PROCESSES / SESSIONS are the AWR peak-concurrency high-water marks against the '
      || 'init parameter (summed over RAC instances); DB_SIZE_GB is total permanent-tablespace '
      || 'usage against the sum of the same tablespaces&#39; ceilings; REDO_GB_DAY has no ceiling '
      || 'and is a sizing trend for the FRA / archive destination, with FRA days = how many days of '
      || 'redo db_recovery_file_dest_size holds at the current rate (an upper bound: the FRA also holds '
      || 'flashback logs and backups). ASM_DG:+&lt;group&gt; is a diskgroup&#39;s raw GiB used against '
      || 'its total; TEMP_PEAK / UNDO_PEAK are the highest sampled GiB used of a TEMP or UNDO '
      || 'tablespace that day against its maxsize. DAYS_LIM is the projected '
      || 'days until the series reaches SAT, and WORST/BEST bound it with the 95% CI on the slope.</p>');

  any_rows := FALSE;
  FOR r IN (
    -- LIVE: CAPR_SERIES. SNAPSHOT: the SERIES rows of CAPR_FIT_HISTORY for
    -- the last OK refresh run (no SAT value or FRA days there).
    SELECT db_pdb, series, unit, cur_val, cur_limit, sat_value, pct_of_limit,
           slope_per_day, r2, days_to_limit, limit_worst, limit_best, sev, quality,
           fra_days_at_cur
    FROM  (SELECT db_pdb, series, unit, cur_val, cur_limit, sat_value, pct_of_limit,
                  slope_per_day, r2, days_to_limit, limit_worst, limit_best, sev, quality,
                  fra_days_at_cur, rank_series AS s_ord
           FROM   capr_series
           WHERE  v_src = 'LIVE'
             AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
           UNION ALL
           SELECT h.db, h.series, h.unit, h.value, h.limit_value, CAST(NULL AS NUMBER), h.pct,
                  h.slope_per_day, h.r2, h.days_to_full, h.days_to_full_lo, h.days_to_full_hi, h.sev, h.quality,
                  CAST(NULL AS NUMBER),
                  ROW_NUMBER() OVER (ORDER BY h.days_to_full NULLS LAST, h.pct DESC NULLS LAST, h.con_dbid, h.series)
           FROM   capr_fit_history h
           WHERE  v_src = 'SNAPSHOT' AND h.run_id = v_snap_run AND h.kind = 'SERIES'
             AND  (s_dbid IS NULL OR h.dbid = s_dbid) AND (s_con IS NULL OR h.con_dbid = s_con))
    ORDER  BY s_ord
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl tight"><thead><tr>'
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
        || '</th><th>Quality' || info_icon('CAPR column: QUALITY')
        || '</th><th class="num">FRA days' || info_icon('REDO_GB_DAY only: days of redo db_recovery_file_dest_size holds at the current rate (CAPR column: FRA_DAYS_AT_CUR)')
        || '</th></tr></thead><tbody>');
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
      || '<td>' || quality_pill(r.quality) || '</td>'
      || '<td class="num">' || nz(r.fra_days_at_cur, 'FM9999990.0') || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="empty-note">No fixed-ceiling series yet (needs DBA_HIST_RESOURCE_LIMIT / '
      || 'DBA_HIST_SYSSTAT history, or tablespace history for DB_SIZE_GB).</div>');
  END IF;

  -- 7b: unusual days of the same series (CAPR_SERIES_ANOMALIES), the rows
  -- the SERIES_ANOM alerts point at
  p('<h3 style="font-size:13px;margin:16px 0 6px">Unusual series days <span style="font-weight:400;color:var(--muted)">(last '
      || anomaly_days || ' days)</span></h3>');
  p('<p class="desc">PROCESSES, SESSIONS and REDO_GB_DAY are judged on their daily level, DB_SIZE_GB on how much it grew that day. '
      || 'Each day is compared against the last ' || TO_CHAR(mad_window, 'FM9990') || ' days and against the same weekday over the last '
      || TO_CHAR(dow_wk, 'FM9990') || ' weeks; one row per baseline that flagged it.</p>');
  any_rows := FALSE;
  FOR r IN (
    SELECT db_pdb, series, unit, day_str, baseline_mode, value, expected, threshold, z, n_hist, pct_vs_med, anomaly_flag
    FROM   capr_series_anomalies
    WHERE  days_ago < anomaly_days
      AND  (s_dbid IS NULL OR dbid = s_dbid) AND (s_con IS NULL OR con_dbid = s_con)
    ORDER  BY days_ago, con_dbid, series, mode_rank
  ) LOOP
    IF NOT any_rows THEN
      p('<div class="tscroll">');
      p('<table class="tbl tight"><thead><tr>'
        || '<th>DB/PDB</th><th>Series' || info_icon('CAPR column: SERIES')
        || '</th><th>Day' || info_icon('CAPR column: DAY_STR')
        || '</th><th>Baseline' || info_icon('what the day was compared against (CAPR column: BASELINE_MODE)')
        || '</th><th class="num">Value' || info_icon('the level that day, or for DB_SIZE_GB the GiB grown per day (CAPR columns: VALUE, UNIT)')
        || '</th><th class="num">Median' || info_icon('the usual value on that baseline (CAPR column: EXPECTED)')
        || '</th><th class="num">Threshold' || info_icon('how far from usual a day must be before it is flagged (CAPR column: THRESHOLD)')
        || '</th><th class="num">Robust z' || info_icon('how far outside its normal range this day was -- 3 or more is clearly unusual (CAPR column: Z)')
        || '</th><th class="num">Baseline days' || info_icon('CAPR column: N_HIST')
        || '</th><th class="num">vs median %' || info_icon('CAPR column: PCT_VS_MED')
        || '</th><th>Flag' || info_icon('CAPR column: ANOMALY_FLAG') || '</th></tr></thead><tbody>');
      any_rows := TRUE;
    END IF;
    p('<tr><td>' || esc(r.db_pdb) || '</td><td><b>' || esc(r.series) || '</b></td>'
      || '<td style="white-space:nowrap">' || r.day_str || '</td>'
      || '<td style="white-space:nowrap">' || mode_label(r.baseline_mode) || '</td>'
      || '<td class="num">' || series_val(r.value, r.unit) || '</td>'
      || '<td class="num">' || series_val(r.expected, r.unit) || '</td>'
      || '<td class="num">' || series_val(r.threshold, r.unit) || '</td>'
      || '<td class="num' || (CASE WHEN ABS(NVL(r.z,0)) >= 3 THEN ' z-hi' ELSE '' END) || '">'
         || nz(r.z, 'FM99990.0') || '</td>'
      || '<td class="num">' || nz(r.n_hist, 'FM9990') || '</td>'
      || '<td class="num">' || nz(r.pct_vs_med, 'FMS999999999990') || '</td>'
      || '<td class="' || CASE WHEN r.anomaly_flag = 'HIGH' THEN 'sev-crit' ELSE 'sev-ok' END || '">' || esc(r.anomaly_flag) || '</td></tr>');
  END LOOP;
  IF any_rows THEN
    p('</tbody></table>');
    p('</div>');  -- .tscroll
  ELSE
    p('<div class="glance-ok">No unusual series days in the last ' || TO_CHAR(anomaly_days, 'FM999990') || ' days.</div>');
  END IF;
  EXCEPTION
    WHEN OTHERS THEN sec_failed('7 (fixed-ceiling series)', SQLERRM);
  END;
  p('</section>');

  ----------------------------------------------------------------------
  -- Footer + close document
  ----------------------------------------------------------------------
  p('<footer>End of report -- read-only run, no database objects created or modified. '
      || CASE WHEN v_failed = 0 THEN 'All sections rendered. '
              ELSE TO_CHAR(v_failed, 'FM990') || ' section(s) failed to render; see the red blocks above. ' END
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
UNDEFINE 4
UNDEFINE 5
UNDEFINE 6
PROMPT
PROMPT Report written to: &cap_path
PROMPT
