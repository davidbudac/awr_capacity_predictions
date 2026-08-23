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
- [ ] **M7.4 Bound sections 2 and 6.** Apply `top_n` / "growing or ≥ X GB"
      filter so a 500-tablespace DB doesn't print 500 + 2000 rows. New knob
      `report_min_gb`.
- [ ] **M7.5 Drill-down script** `report/drill_tbspc.sql <tablespace>` (and a
      CPU twin): daily series, fit line, residuals, anomaly arithmetic for one
      series.
- [ ] **M7.6 Positional report args.** `@report/report.sql [top_n] [anomaly_days] [show_esm]`
      with `defaults.sql` as fallback (COLUMN NEW_VALUE default trick for
      unset `&1..&3`); no more editing `defaults.sql`.
- [ ] **M7.7 Cleanups.** ~~Remove the dead `CAP_CONFIG.anomaly_report_days`~~
      (no longer dead: M8.1's `CAPR_ALERTS` uses it as the alert window; the
      report `anomaly_days` DEFINE stays presentation-only — both kept, docs
      say which is which); `TO_CHAR(..,'FM')` the header knobs
      (`WARN<=        90`); label GiB consistently; cap/NULL `accel_ratio`
      when `|slope|` is below a floor.

## M8 — Integration surface

- [x] **M8.1 `CAPR_ALERTS` view.** Done (`ddl/45_report_views.sql`): one row
      per issue — `severity/sev_rank, kind (TBSPC_FULL | TBSPC_NEARFULL |
      TBSPC_ANOM | CPU_SAT | CPU_ANOM), dbid, con_dbid, db_pdb, series_key,
      day_dt, value, threshold, unit, message`. Anomaly kinds window on the
      `anomaly_report_days` knob. Read-only; fixture-asserted.
- [ ] **M8.2 `CAPR_*` report views.** Move every section's SELECT into a view
      so `report.sql` and `report_html.sql` only *format* — removes the
      duplicated-SQL drift risk README admits for the HTML driver.
- [ ] **M8.3 Jobs.** `install_jobs.sql` (opt-in): weekly `cap_forecast_ml.train_all`
      retrain + a spool-the-report job; both `DBMS_SCHEDULER`, disabled by
      default.
- [ ] **M8.4 `doctor.sql` preflight.** Checks pack access
      (`CONTROL_MANAGEMENT_PACK_ACCESS`), direct `DBA_HIST_*` grants,
      `CREATE MINING MODEL`, AWR retention/interval, days of history available
      per source → says up front why forecasts will be `INSUFFICIENT_HISTORY`.

## M9 — Forecast quality (Tier 1)

- [ ] **M9.1 Prediction intervals.** From `REGR_SXX/SXY/SYY` → residual SE →
      95% bands on `+30/90/180/365` and a **range on `days_to_full`**
      ("120 days, worst case 80"). Stays hand-auditable. Expose as
      `proj_*_lo/hi`, `days_to_full_lo/hi`; report shows the range.
- [ ] **M9.2 Robust slope.** Theil–Sen (pairwise slopes via self-join +
      `MEDIAN`, O(n²) ≈ 4k pairs at 90 days) alongside OLS; knob
      `slope_method = OLS | THEILSEN`. Fixture: `FIX_SPIKE`/a purge series must
      give a sane slope.
- [ ] **M9.3 Change-point reset.** Restart the training window after the most
      recent large negative delta (LOW anomaly / `|delta| > x·MAD`) so a
      post-purge series isn't fit across the cliff. Knob `reset_on_shrink`.
- [ ] **M9.4 Backtest / holdout accuracy.** `CAPF_BACKTEST`: fit on
      `last_day - holdout_days`, compare to actual last `holdout_days` → MAPE /
      bias per series per engine (REGR and ESM). Surface in section 6 as
      "which engine was right last month"; use it to pick ESM model type
      (M10.1).
- [ ] **M9.5 Tablespace limit overrides / exclusions.** `CAP_TBSPC_OVERRIDE
      (dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag)`: autoextend
      `maxsize` is not real headroom when the filesystem / ASM DG is smaller;
      also silences staging/scratch tablespaces.

## M10 — CPU / capacity analysis

- [ ] **M10.1 Peak, not average.** From per-snapshot OSSTAT deltas derive daily
      `busy_p95`, `busy_max`, and busy% inside a configurable peak window
      (`peak_hour_from/to`); forecast those for days-to-saturation. Same for DB
      CPU.
- [ ] **M10.2 DB CPU as % of core capacity.** `db_cpu_sec / (cores·86400)·100`
      (already have `db_cpu_per_core`) → same REGR fit and `days_to_sat` as
      busy%; per-PDB share of host CPU.
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
