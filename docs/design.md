# Design — AWR Capacity Predictions

This document explains *why* each layer is shaped the way it is. For usage see
`README.md`; for change-safety notes see `CLAUDE.md`.

## Goals and constraints

- **In-database only.** Forecasting and anomaly detection run as SQL/PLSQL
  against AWR. No export, no external ML runtime.
- **Auditable.** Tier 1 forecasts are ordinary least squares (`REGR_*`); every
  anomaly flag exposes the exact arithmetic (value, median, MAD-sigma,
  threshold, robust z) so an operator can reproduce it by hand.
- **Portable.** Analytics are written once against a thin seam so the same SQL
  serves local AWR, a fleet warehouse, or test fixtures.
- **Read-only.** Nothing the report touches is ever modified; only the suite's
  own config/registry tables are written.
- **Idempotent, non-destructive re-install.** The two persisted tables
  (`CAP_CONFIG`, `CAP_ML_MODEL`) are created only if absent and MERGE-seeded for
  missing keys, and `00_drop` deliberately does *not* drop them — so an
  operator's config overrides and trained-model registry survive `@install.sql`.
  Full teardown is `@uninstall.sql`.
- **19c floor.** No 21c+ syntax (notably: no standalone `WINDOW` clause).

## Layer 1 — the seam (`CAPV_*`)

Seven views re-present the AWR dictionary in a stable shape. Everything
downstream depends only on these, so swapping `ddl/10_seam_local.sql` for `11`
(warehouse) or `12` (fixture) re-points the whole stack. Every view carries
`(dbid, con_dbid)`.

- `DBA_HIST_SNAPSHOT` has no `CON_DBID`, so `CAPV_SNAPSHOT` sets
  `con_dbid := dbid`. The tablespace / OS / time-model views expose the **real**
  `CON_DBID`, which is mandatory: `TABLESPACE_ID`/`TS#` restart at 0 per
  container, so `SYSTEM` in the root and in a PDB collide unless `con_dbid`
  disambiguates them.
- **Units are passed through, not normalized** (documented in the file header):
  tablespace sizes stay in DB **blocks**; OSSTAT `*_TIME` stays in
  **centiseconds**; time-model values stay in **microseconds**. Conversion is
  the daily layer's job.
- `block_size` rides on `CAPV_TABLESPACE` (from `DBA_HIST_TABLESPACE`), which is
  populated for every tablespace. `CAPV_DATAFILE` is kept only as a fallback:
  `DBA_HIST_DATAFILE` is missing `SYSTEM` on stock 19c, so relying on it alone
  silently drops that tablespace.
- `RTIME` on `TBSPC_SPACE_USAGE` is an NLS-fragile VARCHAR2 and is ignored;
  timestamps come from joining `snap_id` → `CAPV_SNAPSHOT`. Live
  `DBA_TABLESPACES` is never joined (loses dropped tablespaces; absent in
  warehouse mode).
- `CAPV_CONTAINER` (M7.2) is the naming dimension: one row per
  `(dbid, con_dbid)` with `db_name` + `con_name`. Local mode reads
  `DBA_HIST_PDB_INSTANCE` (which names every container including `CDB$ROOT`,
  whose `con_dbid` equals the CDB dbid — verified on 19c) with a
  `DBA_HIST_DATABASE_INSTANCE` fallback branch for non-CDBs; warehouse mode
  maps `db_name` to the Target's display name via `awrv_container`
  (`con_name` stays NULL — no PDB-name dim collected yet); fixture mode reads
  `CAP_FIXTURE_CONTAINER`. Historical dictionaries only, same as the rest of
  the seam — never live `V$` views.

## Layer 2 — daily series (`CAPD_*`)

Collapses irregular, per-instance, cumulative-counter snapshots into one clean
row per day.

- **`CAPD_TBSPC_DAILY`** — usage is a *level*, so per day we take the **last**
  sample (`KEEP (DENSE_RANK LAST ORDER BY end_interval_time)`) and convert
  blocks→bytes. `limit_bytes = maxsize*bs` when autoextend is on (`maxsize>0`),
  else `size*bs`. `UNDO`/`TEMPORARY` are excluded (their usage is transient).
  The usage table has no `instance_number`, so the day is derived by joining
  `snap_id` to the per-snap `MIN(end_interval_time)`.
- **`CAPD_TBSPC_DELTA`** — change since the previous *sampled* day. Exposes
  `day_gap` (calendar days since the last sample) and `used_rate_bpd =
  used_delta_bytes / day_gap`, so a multi-day AWR gap is not mistaken for a
  one-day spike downstream. Negative deltas (purge/shrink) are legitimate and
  kept.
- **`CAPD_CPU_DAILY`** — `BUSY_TIME`/`IDLE_TIME` are cumulative counters;
  consecutive snaps are differenced per `(dbid, con_dbid, instance)`, then any
  interval that spans an **instance restart** (`startup_time` changed) or shows
  a **negative delta** (counter reset) is dropped. Per day:
  `busy% = 100·Σbusy_d / Σ(busy_d+idle_d)` — centisecond units cancel in the
  ratio.
- **`CAPD_DBTIME_DAILY`** — same delta+guard pattern over the time model →
  `db_cpu_sec`, `db_time_sec`, `bg_cpu_sec` (÷1e6). `db_cpu_per_core` divides by
  the host core count summed across instances from OSSTAT (falling back to
  `NUM_CPUS`).

All `LAG`s use inline `OVER (...)` (19c has no `WINDOW` clause).

## Layer 3 — Tier 1 forecasts (`CAPF_*`)

Ordinary least squares via `REGR_*` over `day_n = day_dt − DATE '2020-01-01'`
(an integer day index off a fixed epoch → slopes are per-day and stable).

- Two fits per series: the primary over `train_days` (90) and a "recent" fit
  over `recent_days` (28); `accel_ratio = recent_slope / slope` (>1.5 in the
  report highlights accelerating growth).
- Projections are `intercept + slope·(last_day_n + h)` for h ∈ {30,90,180,365}.
- `days_to_full = FLOOR((limit − cur_used) / slope)` when `slope > 0`.
- **Prediction intervals (M9.1)**, classic OLS closed forms so everything stays
  hand-auditable: `SSE = SYY − SXY²/SXX`, `resid_se = √(SSE/(n−2))`, and each
  projection gets a 95% new-observation band `± t·resid_se·√(1 + 1/n +
  (x₀−x̄)²/SXX)` (`proj_*_lo/hi`). The slope's CI half-width
  (`t·resid_se/√SXX`, exposed as `slope_ci_bpd`) yields the
  `days_to_full_lo/hi` range: lo = worst case (fastest plausible growth),
  hi NULL = the slow edge of the CI is ≤ 0 ("might never fill"). There is no
  t-distribution in SQL, so `t ≈ 1.96 + 2.4/df` — within ~1% for df ≥ 10, and
  `min_train_days` guarantees df ≥ 12 before a forecast is trusted. The
  approximation is part of the contract (the fixture installer computes
  expectations with the same formula). A perfectly linear or flat series has
  SSE = 0, so its bands collapse onto the point projection.
- **Quality** (priority order): `INSUFFICIENT_HISTORY` (`REGR_COUNT <
  min_train_days`) → `FLAT` (`slope = 0`, or `R² IS NULL`) → `LOW_CONFIDENCE`
  (`R² < r2_gate`) → `OK`. Note the `FLAT` definition: Oracle's `REGR_R2`
  returns **1** for a zero-variance *y* (a truly flat series) and NULL only for
  zero-variance *x*, so flatness is detected by `slope = 0`, not by a NULL R².
- `CAPF_CPU_TREND` applies the same fit to `busy_pct` and `db_cpu_sec` (one row
  per `(dbid, con_dbid, metric)`), with `days_to_sat` for busy% only.

## Layer 4 — anomalies (`CAPA_*`)

Robust median + MAD (`MAD_sigma = MEDIAN(|x − median|)·1.4826`). Rolling MAD
can't be nested window-MEDIANs, so each view is a **trailing-window self-join**
in two passes (median, then MAD about that median), always **excluding the
current day** so a spike can't inflate its own baseline.

- **`CAPA_TBSPC_ANOM`** — on the per-day growth **rate** (`used_rate_bpd`) over
  a trailing `mad_window_days`, so an AWR gap can't masquerade as a spike.
  Threshold is `GREATEST(k·MAD, abs_floor_bytes)` (bytes/day) so a jump from an
  exactly-flat baseline (MAD=0) still flags, and sub-floor (≤100 MiB/day)
  wiggles never do. Flags require `n_hist ≥ tbspc_min_hist` (7). The raw
  `used_delta_bytes` and `day_gap` are carried through for the report's audit
  trail.
- **`CAPA_CPU_ANOM`** — baseline is the prior `dow_weeks` **same weekdays**
  (`day − 7·level`, generated with `CONNECT BY`), so weekly seasonality is
  handled deterministically. The MAD floor is `cpu_min_mad_pct` (3 points),
  which plays the flat-baseline-guard role that `abs_floor_bytes` plays for
  bytes.

Self-join cost is O(days·window) at daily grain — fine for ≤ ~400 days, and it
keeps every flag hand-recomputable.

## Layer 5 — Tier 2 OML ESM

`ml/cap_forecast_ml` trains one exponential-smoothing model per series (19c has
no partitioned ESM) via `DBMS_DATA_MINING.CREATE_MODEL2(mining_function =>
'TIME_SERIES')`, registered in `CAP_ML_MODEL`.

- Tablespaces use `EXSM_HOLT` (additive trend, no seasonality); CPU series use
  `EXSM_ADDWINTERS` with weekly seasonality (7). `data_query` is built as
  literal-embedded per-series text (it can't bind); series keys are Oracle
  identifiers so quote-doubling is injection-safe.
- **Horizon cap**: Oracle 19c rejects `EXSM_PREDICTION_STEP` above a HARD 30 at
  any series length (verified 30 valid / 31 invalid at 121, 300 and 600 rows;
  `ORA-40206`). `build_model` caps at `LEAST(30, cfg_step, FLOOR(rows/4))`, so no
  train ever fails on the horizon and ESM forecasts only ever reach +30 days.
- Predictions live in the dynamic `DM$VP<model>` view
  (`CASE_ID, VALUE, PREDICTION, LOWER, UPPER`). Because the name is only known
  at runtime, the package exposes `get_forecast(model) PIPELINED`, and
  `CAPF_ESM_FORECAST` lateral-joins it over the registry.
- `CAPF_COMPARE` unions Tier 1 point projections (REGR, +30/90/180/365) with
  Tier 2 predictions + 95% bounds (ESM, **+30 only** — the 19c hard cap). ESM
  rows are also gated on **freshness**: a model must be trained through the
  series' current last day, so a model left behind by a later top-N retrain
  (stale `trained_through`) is never compared against a current-dated REGR
  point. Model names hash `(dbid | con_dbid | series_key)` so a cross-database
  `con_dbid` collision cannot overwrite another database's model.
- **Backtest (M9.4)**: `train_backtest` builds `purpose = 'BACKTEST'` twin
  models (CBT* name prefixes) whose training data stops
  `backtest_holdout_days` (28) before each series' last day, so their forecast
  rows land inside the holdout where real values exist. `CAPF_ESM_FORECAST` /
  `CAPF_COMPARE` filter `purpose = 'FORECAST'`, so the twins never leak into
  the report's forecasts. `CAPF_BACKTEST` then scores both engines over the
  holdout — REGR is re-fit in pure SQL on the same truncated window (works
  with zero models trained) — as `mape_pct` / `bias_pct` per series per
  engine, surfaced as report section 6c ("which engine was right"). ESM may
  cover fewer than holdout_days days (30-step cap + the rows/4 floor);
  `n_days` records actual coverage. This feeds ESM model-type selection
  (M10.4).

### Retraining (shipped commented-out for v1 minimalism)

```sql
-- BEGIN
--   DBMS_SCHEDULER.CREATE_JOB(
--     job_name        => 'CAP_ESM_WEEKLY',
--     job_type        => 'PLSQL_BLOCK',
--     job_action      => 'BEGIN cap_forecast_ml.train_all(20); END;',
--     repeat_interval => 'FREQ=WEEKLY;BYDAY=SUN;BYHOUR=2',
--     enabled         => TRUE);
-- END;
-- /
```

## Layer 6 — integration (`CAPR_*`, M7.2/M8.1)

Two seam-agnostic views for consumers outside the bundled reports:

- `CAPR_CONTAINER` wraps `CAPV_CONTAINER` and computes `db_pdb`, the one
  display label every report section prints instead of a raw `con_dbid`
  (root/non-CDB → db name alone; PDB → `DBNAME/PDBNAME`; unnamed → the raw
  `con_dbid` as text). Defining the label once keeps text and HTML from
  drifting.
- `CAPR_ALERTS` is the pollable alert surface: one row per current issue with
  `severity` (CRIT/WARN/INFO + numeric `sev_rank`), `kind` (`TBSPC_FULL`,
  `TBSPC_NEARFULL`, `TBSPC_ANOM`, `CPU_SAT`, `CPU_ANOM`), keys, `value` vs
  `threshold` (+ `unit`), and a ready-to-page `message`. The forecast kinds
  gate on `quality = 'OK'`; `TBSPC_NEARFULL` deliberately does **not** (M7.1:
  a 97%-full tablespace with an unfittable series must still surface — that's
  a fact about *today*, not a forecast). Anomaly kinds use the
  `anomaly_report_days` knob as their window (the reports' `anomaly_days`
  DEFINE is presentation-only). Both reports' at-a-glance blocks read this
  view, so paging and reporting can never disagree.

## Report

`report/report.sql` spools a read-only text report (7 sections: an
at-a-glance alert roll-up from `CAPR_ALERTS`, then the six detail sections) to
`reports/cap_report_<db>_<ts>.txt`. Identity comes from `SYS_CONTEXT` (no `V$`
or catalog privileges needed, so any monitoring schema can run it). Sections
consume only `CAPF_*`/`CAPA_*`/`CAPR_*`. `show_esm` = `AUTO`/`Y`/`N` controls
the Tier 2 section (AUTO prints a hint when no models are trained). Section 1
ranks days-to-full across **all** fit qualities (marker column says how much
to trust each row) and adds a near-full-now ranking by `pct_used` (M7.1).

## Testing philosophy

The fixture seam is the correctness gate: since we can't `INSERT` into
`DBA_HIST_*`, `CAPV_*` are pointed at `CAP_FIXTURE_*` tables filled with exact,
anchored, deterministic series. Every asserted number is a closed form recorded
in `CAP_FIXTURE_META` (so `run_test.sql` reads expectations rather than
re-deriving dates). `run_test.sql` prints PASS/FAIL and exits non-zero on any
failure (CI-able); `run_test_ml.sql` adds the ESM assertion behind the
`CREATE MINING MODEL` privilege.

## Roadmap

- **Milestone W / M6 — done.** `awr-fleet-warehouse` now carries
  `awrw_tbspc_stat` / `awrw_osstat` / `awrw_time_model` facts + `awrw_tablespace`
  / `awrw_datafile` dims and their `AWRV_*` seam views, collected by the fleet
  collector (three fact pulls + two dim loads). `ddl/11_seam_warehouse.sql`
  re-maps CAPV_* onto those AWRV_* views, so warehouse mode is a working seam,
  byte-identical downstream to local mode. Install as the warehouse owner. The
  five capacity tables are the only warehouse objects keyed on `(dbid, con_dbid)`
  (TS# restarts per container); shipped for existing warehouses as
  `migrate/002_capacity_facts.sql`.
- **v2** — memory forecasting; cross-DBID series stitching (non-CDB → PDB
  migrations) keyed on a stable warehouse `target_id`.
