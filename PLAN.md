# PLAN.md — roadmap / milestones

Status legend: `[ ]` todo · `[~]` in progress · `[x]` done.
Done milestones (M1–M6 / W: seam, daily, Tier 1, anomalies, Tier 2 ESM, HTML
report, warehouse seam) are described in `docs/design.md`; this file tracks
what is **next**. Each milestone is scoped so it can ship alone.

Ground rules for every item: read-only against AWR, everything via the
`CAPV_*` seam, knobs in `CAP_CONFIG`, 19c syntax floor, fixture assertion for
every new number (see `test/run_test.sql`).

---

## M7 — Report usability (text + HTML)

- [x] **M7.1 Don't hide near-full tablespaces.** Done: `pct_used` added to
      `CAPF_TBSPC_FORECAST`; section 1a ranks days-to-full across all
      qualities with a QUALITY marker; new 1b "near-full now" ranking by
      `PCT_USED` (knobs `nearfull_warn_pct`/`nearfull_crit_pct`, 90/97);
      mirrored in `report_html.sql` (banner items, glance cards, section 1
      tables). Fixtures `FIX_NEARFULL`/`FIX_FILLING` assert it.
- [x] **M7.2 Container / database names instead of raw `con_dbid`.** Done:
      `CAPV_CONTAINER` in all three seams (local: `DBA_HIST_PDB_INSTANCE` —
      which names CDB$ROOT too — + `DBA_HIST_DATABASE_INSTANCE` fallback;
      warehouse: new `awrv_container` over `awrw_dbid`/`awrw_target`, con_name
      NULL until a PDB-name dim exists; fixture: `CAP_FIXTURE_CONTAINER`).
      `CAPR_CONTAINER.db_pdb` computes the label once; every text/HTML section
      prints `DB/PDB`.
- [x] **M7.3 At-a-glance block for the text report.** Done: section 0 in
      `report.sql` (counts + alert list) built from `CAPR_ALERTS`, same view
      the HTML banner reads.
- [x] **M7.4 Bound sections 2 and 6.** Done: `CAPR_TBSPC_FORECAST` computes
      `is_reportable` (growing OR near-full OR `cur_used >= report_min_gb` GiB
      — near-full is in the disjunction so M7.1's rule still holds) and
      `rank_report` (reportable first, growing first, then biggest);
      `CAPR_ESM_COMPARE` inherits both (CPU rows always `'Y'` / rank 0). Text
      and HTML apply the identical `WHERE is_reportable='Y' AND rank_report <=
      top_n` and print the bound in the section header. New knob
      `report_min_gb` (1). Fixture: FIX_FLAT is the one `'N'`.
- [x] **M7.5 Drill-down script.** Done: `report/drill_tbspc.sql <tablespace>
      [con_dbid]` and its CPU twin `report/drill_cpu.sql [metric] [con_dbid]`
      (metric = `BUSY_PCT` default | `BUSY_P95` | `BUSY_PEAK` | `DB_CPU_SEC` |
      `DB_CPU_PCT` | `DB_CPU_P95`) print + spool one series end-to-end: fit
      header (slope/intercept/R2/slope CI/days-to-full|sat with WORST/BEST),
      the daily series over `train_days` with `fit`, `residual`, delta, gap and
      the CAPA_* baseline per day, a residual footer proving `SUM(resid)=0` and
      re-deriving `resid_se` + `slope_ci` from scratch, and one spelled-out
      arithmetic line per flagged day. Optional args via the COLUMN NEW_VALUE
      zero-row trick (never prompts) and `UNDEFINE`d at the end.
- [x] **M7.6 Positional report args.** Done: `@report/report.sql [top_n]
      [anomaly_days] [show_esm]` and the same for `report_html.sql`, with
      `report/defaults.sql` still the fallback source of truth. Unset `&1..&3`
      are defined-as-empty by the zero-row `COLUMN 1 NEW_VALUE 1` trick (a
      passed argument survives it), so neither form ever prompts; both scripts
      `UNDEFINE 1 2 3` at the end. Verified non-interactively on 19c with 0, 1
      and 3 arguments.
- [x] **M7.7 Cleanups.** Done: `anomaly_report_days` KEPT (it is
      `CAPR_ALERTS`' window; the report's `anomaly_days` DEFINE stays
      presentation-only) and README / `docs/reference.html` now say which
      window is which; every header knob goes through
      `TO_CHAR(..,'FM9999990')`, so the text report prints
      `WARN<=90 CRIT<=30 ; CPU saturation 80%` and `reaches 80%`; GiB / MiB
      labels unified across text + HTML wherever the number is `/1073741824`
      (`/1048576`); `accel_ratio` is NULL when
      `|slope| < accel_slope_floor_bpd` (new knob, 1 MiB/day), so a near-flat
      series can no longer show a 500x acceleration.

## M8 — Integration surface

- [x] **M8.1 `CAPR_ALERTS` view.** Done (`ddl/45_report_views.sql`): one row
      per issue — `severity/sev_rank, kind (TBSPC_FULL | TBSPC_NEARFULL |
      TBSPC_ANOM | CPU_SAT | CPU_ANOM), dbid, con_dbid, db_pdb, series_key,
      day_dt, value, threshold, unit, message`. Anomaly kinds window on the
      `anomaly_report_days` knob. Read-only; fixture-asserted.
- [x] **M8.2 `CAPR_*` report views.** Done: one view per report section —
      `CAPR_TBSPC_DAYS_TO_FULL` (1a/1b, with `sev_dtf`/`sev_nearfull` and
      `rank_dtf`/`rank_nearfull` so a driver applies `top_n` with a WHERE),
      `CAPR_TBSPC_ANOMALIES` / `CAPR_CPU_ANOMALIES` (flagged rows + `days_ago`
      so the window is a WHERE too), `CAPR_CPU_TREND` in
      `ddl/45_report_views.sql`; `CAPR_TBSPC_FORECAST`, `CAPR_ESM_COMPARE`
      and `CAPR_BACKTEST` in the new `ddl/55_report_views_ml.sql` (loaded
      after `50_ml`, because they read `CAPF_COMPARE`/`CAPF_BACKTEST`). Every
      GiB/MiB conversion, severity marker and `db_pdb` label is computed once
      in the view; `report/sections/0[1-6]*.sql` and `report_html.sql` now
      only format, so the two drivers cannot drift. Text and HTML output are
      byte-identical to before on the fixture.
- [x] **M8.3 Jobs.** Done: `install_jobs.sql` / `uninstall_jobs.sql` (opt-in,
      repo root, not in `install.sql`) create `CAP_ML_RETRAIN` (weekly
      `cap_forecast_ml.train_all`) and `CAP_REPORT_SPOOL_JOB` (daily
      `cap_report_spool(p_dir)` → `UTL_FILE` snapshot of `CAPR_ALERTS` into a
      `report_dir` DEFINE, default `CAP_REPORTS`), both DISABLED and
      idempotent; jobs share the schema namespace with procedures, hence the
      `_JOB` suffix (ORA-27477).
- [x] **M8.4 `doctor.sql` preflight.** Done: read-only PASS/WARN/FAIL checklist
      in one exception-wrapped anonymous block — pack access, direct
      `DBA_HIST_*` reads, `SESSION_PRIVS`, AWR retention/interval per dbid,
      days of history per source vs `min_train_days`, invalid `CAP*` objects +
      detected seam mode, then a plain-English "why `INSUFFICIENT_HISTORY`".

## M9 — Forecast quality (Tier 1)

- [x] **M9.1 Prediction intervals.** Done: `REGR_SXX/SXY/SYY/AVGX` → residual
      SE → 95% bands (`proj_*_lo/hi`) + `days_to_full_lo/hi` /
      `days_to_sat_lo/hi` ranges on both CAPF views (t approximated as
      `1.96 + 2.4/df`, part of the contract). Reports show the range (1a/4
      WORST/BEST columns, section 2 +180 band, HTML RANGE columns + worst-case
      card line). `FIX_ZIGZAG` fixture asserts the closed forms; `FIX_LINEAR`
      asserts bands collapse at zero residuals.
- [x] **M9.2 Robust slope.** Done: Theil–Sen (median of the pairwise slopes
      `(y_j−y_i)/(x_j−x_i)` via a self-join on the training window, O(n²) ≈ 4k
      pairs at 90 days) computed alongside OLS in **both** `CAPF_TBSPC_FORECAST`
      and `CAPF_CPU_TREND`. Knob `slope_method` (CAP_CONFIG is numeric: `0` =
      OLS default, `1` = THEILSEN); both estimators are always exposed
      (`ols_slope_bpd` / `ts_slope_bpd`, `ols_slope_per_day` /
      `ts_slope_per_day`, plus `ts_icept`) and `slope_method` says which one the
      row used. When THEILSEN is selected it drives `slope_bpd`, `icept`, every
      `proj_*`, `days_to_full`/`days_to_sat`, both halves of `accel_ratio` and
      the `slope = 0` FLAT test; `r2` and the M9.1 bands (`proj_*_lo/hi`,
      `slope_ci_bpd`, `days_to_full_lo/hi`) stay OLS residual quantities drawn
      around the chosen line — there is no closed-form Theil–Sen interval in
      SQL. Fixtures: `FIX_LINEAR` (TS = 10 MiB/day exactly), `FIX_ZIGZAG` (TS =
      the median of all 4005 pairwise slopes, enumerated and sorted in the
      installer), `FIX_SPIKE` (TS within 1% of the true 5 MiB/day while OLS is
      3.9× off), plus a knob-flip test that switches to THEILSEN mid-run and
      back.
- [x] **M9.3 Change-point reset.** Done: knobs `reset_on_shrink` (1) and
      `shrink_mad_k` (6). `CAPF_TBSPC_FORECAST` restarts the training window at
      the most recent day whose day-over-day delta is below
      `−GREATEST(shrink_mad_k·MAD_sigma(window deltas), abs_floor_bytes)` (MAD
      computed inline, two passes like ddl/40 but per series over the one
      window), so a post-purge series is fit only on post-purge data. The cliff
      day itself is day 1 of the new window (its `used_bytes` is already the
      post-purge level); new columns `train_start` / `reset_day` (NULL = no
      reset) make it visible, and a window left shorter than `min_train_days`
      honestly reads `INSUFFICIENT_HISTORY`. Fixture `FIX_PURGE` (10 MiB/day,
      −600 MiB at day 90, 10 MiB/day again) asserts `reset_day` = the cliff,
      `train_n` = 31, slope = 10 MiB/day exactly and days-to-full off the
      post-purge line; `FIX_SPIKE` (positive step), `FIX_LINEAR` and
      `FIX_ZIGZAG` assert `reset_day IS NULL`. Not applied to `CAPF_CPU_TREND`:
      a "shrink" is a tablespace event, and a CPU level shift is M10.3's job.
- [x] **M9.4 Backtest / holdout accuracy.** Done: `CAPF_BACKTEST` (in
      `ddl/50_ml.sql`) scores each engine against the held-out last
      `backtest_holdout_days` (knob, 28): REGR recomputed in pure SQL (always
      available), ESM via `cap_forecast_ml.train_backtest` — purpose=BACKTEST
      twin models (CBT* names, new `CAP_ML_MODEL.purpose` column, exposed via
      `CAPF_ESM_BACKTEST`, never leak into `CAPF_ESM_FORECAST`/`CAPF_COMPARE`).
      Section 6c (text + HTML) shows MAPE/bias per engine + BETTER verdict.
      Feeds ESM model-type selection in M10.4.
- [x] **M9.5 Tablespace limit overrides / exclusions.** Done:
      `CAP_TBSPC_OVERRIDE (dbid, con_dbid, tablespace_name, limit_bytes,
      exclude_flag, note)` — the THIRD persisted table (created idempotently in
      `ddl/05_config.sql`, preserved by `00_drop`, dropped only by
      `uninstall.sql`). Autoextend `maxsize` is not real headroom when the
      filesystem / ASM DG is smaller, so a row replaces the computed limit;
      `exclude_flag='Y'` silences staging/scratch tablespaces entirely.
      Applied once in `CAPD_TBSPC_DAILY` (an `ores` CTE resolves the most
      specific of the matching rows — `dbid`/`con_dbid` `0` are wildcards — so
      the LEFT JOIN cannot fan out), which means forecasts, anomalies,
      `CAPR_ALERTS` and both reports honour it with no further code. New
      `limit_source` (`OVERRIDE`/`AUTOEXTEND`/`ALLOCATED`) rides through
      `CAPF_TBSPC_FORECAST`. Fixtures `FIX_OVERRIDE` (FIX_LINEAR's twin capped
      at 2 GiB: 4990 days-to-full becomes 74) and `FIX_EXCLUDED` (99% full,
      excluded via the wildcard row, must appear nowhere) assert it.

## M10 — CPU / capacity analysis

- [x] **M10.1 Peak, not average.** Done: `CAPD_CPU_DAILY` adds `busy_p95`,
      `busy_max`, `busy_peak_pct` (+ `peak_intervals`, `host_busy_sec`) from
      the per-snapshot OSSTAT deltas; peak window = intervals ending in
      `(peak_hour_from, peak_hour_to]` (knobs, default 8/18). `CAPF_CPU_TREND`
      fits `BUSY_P95` / `BUSY_PEAK` with `days_to_sat`; `CPU_SAT` alerts key
      off `BUSY_P95` unless `cpu_sat_on_p95 = 0`. Fixture now has two
      snapshots/day (06:00 night, 18:00 peak) with closed-form assertions.
- [x] **M10.2 DB CPU as % of core capacity.** Done: `CAPD_DBTIME_DAILY` adds
      `db_cpu_pct`, `db_cpu_p95_pct`, `db_cpu_max_pct`, `db_cpu_peak_pct`,
      `host_share_pct` (per-PDB share of host busy seconds); `CAPF_CPU_TREND`
      metrics `DB_CPU_PCT` / `DB_CPU_P95` with `days_to_sat`; new alert kind
      `DBCPU_SAT`.
- [x] **M10.3 Level-shift detection.** Done: `CAPA_CPU_SHIFT`
      (`ddl/40_anomaly_views.sql`) — per (dbid, con_dbid, metric ∈ `BUSY_PCT` /
      `BUSY_P95` / `DB_CPU_PCT`) the median of the last `shift_days` (7) days
      vs the median of the `shift_baseline_days` (28) before it,
      `shift_pct = recent_med - base_med` in percentage POINTS. `UP` needs
      `shift_pct > shift_min_pct` (15) AND a full recent window AND enough
      baseline AND the N-of-M rule (`n_above >= shift_days`: every recent day
      above `base_med + max(base_mad_sigma, cpu_min_mad_pct)`) — which is what
      stops one loud day from dragging a 7-day median into a "shift". `DOWN` is
      the mirror (INFO, not WARN). One row per series (current state) with every
      input exposed. New alert kind `CPU_SHIFT`, new `CAPR_CPU_SHIFTS` view,
      report section 5b (text + HTML). Gap days (M10.5) are excluded from both
      windows. Fixture: a SECOND container (FIXPDB1, con_dbid 42424243, time-
      model rows only) whose DB CPU is a 7-day 34..46% sawtooth — so both
      medians are exact closed forms — stepping +18 points for the last 7 days.
- [x] **M10.4 ESM tuning.** Done: `train_tablespaces` now picks the ESM model
      type per series. With `esm_tbspc_model = 2` (AUTO) and
      `esm_select_by_backtest = 1` (both new knobs, both defaults) it builds
      BOTH candidate M9.4 twins — `EXSM_HOLT` and `EXSM_ADDWINTERS(7)`, names
      now hashing the model type too — scores them in the new
      `CAPF_ESM_CANDIDATE` (one row per series per candidate) and trains
      production with the lower-MAPE one (ties / no evidence → HOLT). The
      decision rides on `CAP_ML_MODEL.model_type` / `chosen_by` / `mape_holt` /
      `mape_addw` and surfaces as `CAPR_ESM_COMPARE.esm_model` (6a/6b column
      `ESM_MODEL`) and `CAPR_BACKTEST.esm_pick` (6c column `ESM_PICK`, e.g.
      `ADDW H=2.90 W=1.20`). `esm_tbspc_model = 0|1` pins a type and skips the
      twins. Quality gate: tablespaces (`CAPF_TBSPC_FORECAST`) and CPU
      (`CAPF_CPU_TREND`) are trained only at `quality IN
      ('OK','LOW_CONFIDENCE')`, so FIX_FLAT / FIX_NEARFULL get no model.
      `CAPF_COMPARE` / `CAPF_BACKTEST` stay backward compatible (a `model_type`
      column added; `CAPF_BACKTEST`'s ESM row is the SELECTED candidate, so it
      is still one row per series per engine). Stale twins are purged per
      series on retrain and `drop_all` gained an orphan sweep over the six
      `<prefix>_<16 hex>` model names.
- [x] **M10.5 CPU gap handling.** Done: `CAPD_CPU_DAILY` and
      `CAPD_DBTIME_DAILY` now expose `max_interval_hours`, `gap_flag` (`'Y'`
      when any interval of the day is longer than the new `cpu_gap_hours` knob,
      default 12) and `day_gap`, mirroring `CAPD_TBSPC_DELTA`. The day is KEPT
      in the series, but `busy_p95` / `busy_max` / `busy_peak_pct` (and the
      `db_cpu_*` twins) are computed only from intervals `<= cpu_gap_hours`, so
      a 36 h average can never pose as a peak hour; `CAPA_CPU_ANOM` neither
      scores a gap day nor lets it into a same-weekday baseline, and
      `CAPA_CPU_SHIFT` skips them too. Default is 12 h rather than something
      tighter because the flag SUPPRESSES scoring — an over-sensitive value
      would silence the CPU anomaly layer wherever snapshot intervals are wide.
      Fixture: a pure AWR gap (a Sunday in day 70..80 whose two snapshots carry
      no OSSTAT/time-model rows) makes the next 06:00 interval span 36 h; that
      day reads 30% busy against a 40% Monday baseline (10 points over a
      9-point threshold) and must stay unflagged purely because of the guard.

## M11 — New series with fixed ceilings (cheap, high value)

All three landed as ONE generic pair of views keyed by a `series` name --
`CAPD_SERIES_DAILY (dbid, con_dbid, series, day_dt, value, limit_value, unit,
n_samples)` in the new `ddl/25_series_daily.sql` and `CAPF_SERIES_FORECAST` in
the new `ddl/35_series_forecast.sql` -- so a fourth series costs a UNION ALL
branch and nothing else. Shared plumbing: new knob `series_sat_pct` (90), new
alert kinds `SERIES_LIMIT` / `SERIES_NEARLIMIT`, new `CAPR_SERIES` report view,
new report section 7 (text + HTML), new fixture tables
`CAP_FIXTURE_RESOURCE_LIMIT` / `CAP_FIXTURE_SYSSTAT`.

- [x] **M11.1 Processes / sessions.** Done: `CAPV_RESOURCE_LIMIT` in all three
      seams over `DBA_HIST_RESOURCE_LIMIT` filtered to `processes`/`sessions`
      (verified on 19c: that view DOES carry `CON_DBID`; `LIMIT_VALUE` is a
      `VARCHAR2(10)` that can read `UNLIMITED`, converted to NUMBER in the seam,
      non-numeric → NULL = no ceiling). Daily value = the day's
      `MAX(max_utilization)` per instance, SUMMED across instances, against the
      summed per-instance limits (NULL if any instance is UNLIMITED).
      `days_to_limit = FLOOR((limit·series_sat_pct/100 − cur)/slope)`, with the
      M9.1 lo/hi range. Fixture `SESSIONS` 200+2·i of 500 → 5 days → a
      `SERIES_LIMIT` CRIT; `PROCESSES` constant 150 of 300 → FLAT, silent.
      **Warehouse TODO:** the sibling `awr-fleet-warehouse` has no
      `awrw_resource_limit` fact / `awrv_resource_limit` view yet, so
      `ddl/11_seam_warehouse.sql` emits the column contract with `WHERE 1 = 0`
      (zero rows, everything downstream stays valid). Add the collector pull +
      fact + AWRV view there, then swap the stub for a pass-through.
- [x] **M11.2 Redo GB/day.** Done: `CAPV_SYSSTAT` (local: `DBA_HIST_SYSSTAT`
      filtered to `redo size`; warehouse: `awrv_sysstat`, which the collector
      already gathers whole, with `con_dbid := dbid` — right for redo, one
      stream per database). Same diff-and-restart-guard as `CAPD_CPU_DAILY`,
      summed per day, /2^30. No ceiling, so `days_to_limit` is NULL and it can
      never alert — it is a trend for FRA / archive sizing. Fixture: +1 GiB per
      12 h interval, reset at the same restart as the CPU counters → exactly
      2.0 GiB/day, restart day dropped.
- [x] **M11.3 Total DB size.** Done: `SUM(used_bytes)` vs `SUM(limit_bytes)`
      over `CAPD_TBSPC_DAILY` per (dbid, con_dbid, day) — so it needs no new
      seam, and it inherits that view's rules (UNDO/TEMPORARY excluded, M9.5
      overrides + exclusions applied). Fixture asserts the identity against a
      re-derived sum plus a positive, fittable slope.

## v2 (unchanged)

- [ ] Memory forecasting (SGA/PGA from `DBA_HIST_MEM_DYNAMIC_COMPONENTS` /
      `DBA_HIST_PGASTAT`).
- [ ] Cross-DBID series stitching (non-CDB → PDB migrations) keyed on a stable
      warehouse `target_id`.

---

Suggested order: M7.1–M7.3 + M8.1 (immediate user value) → M9.1 + M9.4 →
M10.1/M10.2 → M8.2 → rest.
