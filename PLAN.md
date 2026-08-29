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
- [ ] **M9.2 Robust slope.** Theil–Sen (pairwise slopes via self-join +
      `MEDIAN`, O(n²) ≈ 4k pairs at 90 days) alongside OLS; knob
      `slope_method = OLS | THEILSEN`. Fixture: `FIX_SPIKE`/a purge series must
      give a sane slope.
- [ ] **M9.3 Change-point reset.** Restart the training window after the most
      recent large negative delta (LOW anomaly / `|delta| > x·MAD`) so a
      post-purge series isn't fit across the cliff. Knob `reset_on_shrink`.
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
- [ ] **M10.3 Level-shift detection.** A sustained +15% that never crosses
      k·MAD on any single day: flag when N of the last M days exceed
      median+σ, or recent-window median vs baseline median > threshold. Knobs
      `shift_days`, `shift_min_pct`.
- [ ] **M10.4 ESM tuning.** Try `EXSM_ADDWINTERS(7)` for tablespaces (batch
      weekly patterns) vs `EXSM_HOLT`, select by M9.4 backtest; require
      `quality IN ('OK','LOW_CONFIDENCE')` when picking top-N series to train.
- [ ] **M10.5 CPU gap handling.** Mirror `day_gap` for busy% (currently a
      multi-day average is attributed to the ending day); exclude gap-spanning
      days from the anomaly baseline.

## M11 — New series with fixed ceilings (cheap, high value)

- [ ] **M11.1 Processes / sessions** from `DBA_HIST_RESOURCE_LIMIT` vs
      `limit_value` → days-to-saturation with the existing REGR machinery.
- [ ] **M11.2 Redo GB/day** (`DBA_HIST_SYSSTAT 'redo size'`) — FRA / archive
      sizing trend.
- [ ] **M11.3 Total DB size** (sum of tablespaces) as its own series.
      Each needs a seam view (all three modes), a `CAPD_*` daily view, a fixture
      + assertion, and a report section / alert kind.

## v2 (unchanged)

- [ ] Memory forecasting (SGA/PGA from `DBA_HIST_MEM_DYNAMIC_COMPONENTS` /
      `DBA_HIST_PGASTAT`).
- [ ] Cross-DBID series stitching (non-CDB → PDB migrations) keyed on a stable
      warehouse `target_id`.

---

Suggested order: M7.1–M7.3 + M8.1 (immediate user value) → M9.1 + M9.4 →
M10.1/M10.2 → M8.2 → rest.
