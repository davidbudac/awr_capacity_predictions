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
- **Idempotent, non-destructive re-install.** The three persisted tables
  (`CAP_CONFIG`, `CAP_TBSPC_OVERRIDE`, `CAP_ML_MODEL`) are created only if
  absent and MERGE-seeded for missing keys, and `00_drop` deliberately does
  *not* drop them — so an operator's config overrides, hand-set tablespace
  limits and trained-model registry survive `@install.sql`.
  Full teardown is `@uninstall.sql`.
- **19c floor.** No 21c+ syntax (notably: no standalone `WINDOW` clause).

## Layer 1 — the seam (`CAPV_*`)

Nine views re-present the AWR dictionary in a stable shape. Everything
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
- `CAPV_RESOURCE_LIMIT` / `CAPV_SYSSTAT` (M11) are the two newest seam views.
  `DBA_HIST_RESOURCE_LIMIT` (filtered to `processes` / `sessions`) **does**
  carry `CON_DBID` on 19c — verified — so PDBs stay separable; its
  `LIMIT_VALUE` is a `VARCHAR2(10)` that can read `UNLIMITED`, converted here
  to a NUMBER (non-numeric → NULL = "no ceiling"). `CAPV_SYSSTAT` is filtered
  to `redo size`, a cumulative byte counter. The warehouse collects SYSSTAT
  whole (`awrv_sysstat`, `con_dbid := dbid` — right for redo, which is one
  stream per database) but has **no** resource-limit fact yet, so
  `ddl/11_seam_warehouse.sql` emits `CAPV_RESOURCE_LIMIT` with the exact
  column contract and `WHERE 1 = 0`: the stack stays valid in warehouse mode
  and the `PROCESSES` / `SESSIONS` series simply have no rows there.

## Layer 2 — daily series (`CAPD_*`)

Collapses irregular, per-instance, cumulative-counter snapshots into one clean
row per day.

- **`CAPD_TBSPC_DAILY`** — usage is a *level*, so per day we take the **last**
  sample (`KEEP (DENSE_RANK LAST ORDER BY end_interval_time)`) and convert
  blocks→bytes. `limit_bytes = maxsize*bs` when autoextend is on (`maxsize>0`),
  else `size*bs`. `UNDO`/`TEMPORARY` are excluded (their usage is transient).
  The usage table has no `instance_number`, so the day is derived by joining
  `snap_id` to the per-snap `MIN(end_interval_time)`.
  **Limit overrides and exclusions (M9.5):** the autoextend `maxsize` AWR
  records is only a promise the *storage* may not be able to keep — a 32 GiB
  maxsize on a 10 GiB filesystem or ASM diskgroup is not 32 GiB of headroom,
  and a days-to-full computed against it is a comfortable lie. So this view
  left-joins `CAP_TBSPC_OVERRIDE` (the third persisted table): a matching row's
  `limit_bytes` replaces the computed limit, and `exclude_flag='Y'` drops the
  tablespace from the series entirely — the way a staging / scratch / import
  tablespace stops generating noise. Matching is on the exact
  `tablespace_name`, with `dbid = 0` and/or `con_dbid = 0` acting as wildcards
  meaning "any", so one row can be a fleet-wide rule; when several rows match,
  an `ores` CTE ranks them (real `dbid` beats the wildcard first, then real
  `con_dbid`) and keeps only the most specific, so the join can never fan out.
  A new `limit_source` column (`OVERRIDE` | `AUTOEXTEND` | `ALLOCATED`) says
  which rule produced `limit_bytes` and rides through `CAPF_TBSPC_FORECAST`
  to the report. Applying all of this at the single entry point to the daily
  series means every downstream layer — delta, forecast, anomaly, `CAPR_ALERTS`
  — honours it with no further code.
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
  ratio. **Peak, not just average (M10.1):** the same per-interval deltas also
  give `busy_p95` (`PERCENTILE_CONT(0.95)` of the day's per-snapshot busy%),
  `busy_max`, and `busy_peak_pct` — the time-weighted busy% over only the
  intervals whose `end_interval_time` hour falls in `(peak_hour_from,
  peak_hour_to]` (default `(8,18]`, i.e. hourly snapshots ending 09:00–18:00;
  `peak_intervals` counts them, NULL when none). With hourly AWR, p95 ≈ "the
  busy hour" — what actually saturates while a 40% daily average hides it.
  `host_busy_sec` (Σbusy_d/100) is the denominator for a container's share of
  host CPU.
- **`CAPD_DBTIME_DAILY`** — same delta+guard pattern over the time model →
  `db_cpu_sec`, `db_time_sec`, `bg_cpu_sec` (÷1e6). `db_cpu_per_core` divides by
  the host core count summed across instances from OSSTAT (falling back to
  `NUM_CPUS`). **DB CPU as % of core capacity (M10.2):** `db_cpu_pct =
  100·db_cpu_sec / (total_cores·86400)`, plus per-interval `db_cpu_p95_pct` /
  `db_cpu_max_pct` / `db_cpu_peak_pct` (DB CPU seconds over the interval's
  elapsed core-seconds, same peak-window rule). `host_share_pct =
  100·db_cpu_sec / host busy seconds` (host busy summed over the `dbid`, since
  OSSTAT records under the CDB's `con_dbid`) is the per-PDB share of what the
  host was actually doing.

**AWR gaps in the CPU series (M10.5).** A missing stretch of snapshots does not
leave a hole in a counter series — the next snapshot simply differences against
a much older one, and that *one* long interval is attributed to the day it ends
on. A 36 h interval's average is not a day, and it is certainly not a "peak
hour". So both CPU daily views mirror `CAPD_TBSPC_DELTA.day_gap` and expose
`max_interval_hours` (longest interval ending that day), `gap_flag` (`'Y'` when
that exceeds the `cpu_gap_hours` knob, default 12) and `day_gap` (calendar days
since the previous day that *has* a row). The day is deliberately **kept** in
the series — it is still data, and the forecast layer wants it — but:

- `busy_p95` / `busy_max` / `busy_peak_pct` (and their `db_cpu_*` twins) are
  computed only from intervals `≤ cpu_gap_hours`, so a multi-day average can
  never masquerade as a peak hour; NULL if the day has no short interval at all.
- the daily time-weighted averages (`busy_pct`, `db_cpu_pct`) still use **every**
  valid interval, so they stay honest about the counters that were actually
  recorded — on a gap day `db_cpu_pct` legitimately reads high, and `gap_flag`
  is the column that says "this day carries more than a day".
- `CAPA_CPU_ANOM` and `CAPA_CPU_SHIFT` (Layer 4) drop gap days from their
  baselines and never flag one.

Why 12 hours and not something tighter: `gap_flag` *suppresses* anomaly
scoring, so an over-sensitive default would silence the whole CPU anomaly layer
on any site whose snapshot interval is wide. Half a day is comfortably above
every realistic AWR interval and still catches real outages.

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
- **Robust slope (M9.2)** — knob `slope_method` (`CAP_CONFIG` is numeric:
  **0 = OLS**, the default, **1 = THEILSEN**). OLS minimises *squared* error, so
  a single step — a bulk load, an import, a partition drop — drags the whole
  slope with it: the `FIX_SPIKE` fixture grows at 5 MiB/day yet reads ~20 MiB/day
  in OLS because of one +2 GiB day. The **Theil–Sen** estimator is the `MEDIAN`
  of the pairwise slopes `(y_j − y_i)/(x_j − x_i)` over every `i < j` in the
  training window (a self-join, O(n²) ≈ 4k pairs at 90 days); its 29% breakdown
  point means a minority of stepped pairs cannot move it. The intercept is the
  companion `MEDIAN(y − slope·x)`. **Both** estimators are always computed and
  exposed (`ols_slope_bpd` / `ts_slope_bpd`, `ols_slope_per_day` /
  `ts_slope_per_day`, `ts_icept`), and the `slope_method` column reports which
  one the row actually used — it falls back to OLS if Theil–Sen could not be
  computed. When THEILSEN is selected the chosen line drives `slope_bpd`,
  `icept`, every `proj_*`, `days_to_full` / `days_to_sat`, **both** halves of
  `accel_ratio` (mixing estimators would manufacture acceleration) and the
  `slope = 0` FLAT test. `r2`, `resid_se`, `slope_ci_bpd` and the M9.1
  half-widths stay **OLS** quantities: there is no closed-form Theil–Sen
  prediction interval in SQL, so the bands are OLS residual bands drawn *around
  the chosen line*, and `days_to_full_lo/hi` remain the OLS slope-CI range.
  Acceptable for v1 and explicitly documented; with the default
  `slope_method = 0` the output is byte-identical to before. Applies to
  `CAPF_CPU_TREND` as well.
- **Change-point reset (M9.3)** — knobs `reset_on_shrink` (1) and
  `shrink_mad_k` (6), tablespaces only. After a purge or archive job the history
  has a *cliff* in it, and a line fitted across the cliff is a fiction: it
  under-states the slope and over-states the headroom. The training window
  therefore **restarts** at the most recent day whose day-over-day delta is a
  large negative step, `delta < −GREATEST(shrink_mad_k·MAD_σ(deltas),
  abs_floor_bytes)`, where `MAD_σ = MEDIAN(|delta − MEDIAN(delta)|)·1.4826` over
  the deltas of the full `train_days` window (two passes, as in Layer 4, but per
  series over one window rather than rolling — so a plain `GROUP BY` suffices).
  `abs_floor_bytes` stops an exactly-flat series (MAD = 0) from calling every
  wiggle a cliff; `shrink_mad_k = 6` (vs `mad_k = 3` for anomalies) keeps this to
  real cliffs, because it *restarts a fit* rather than merely raising a flag.
  The reset day **itself is day 1 of the new window** — its `used_bytes` is
  already the post-purge level, so including it costs nothing and buys a point.
  `train_start` and `reset_day` (NULL = no reset) are exposed. If fewer than
  `min_train_days` rows survive, quality is `INSUFFICIENT_HISTORY` — the honest
  answer, because we genuinely do not yet know the post-purge growth rate. Note
  that the purge day still shows up as a `LOW` `CAPA_TBSPC_ANOM`; the reset is
  about the *fit*, not about hiding the event. The M9.4 backtest fits its own
  window and is deliberately left alone.
- **Quality** (priority order): `INSUFFICIENT_HISTORY` (`train_n <
  min_train_days`) → `FLAT` (chosen `slope = 0`, or `R² IS NULL`) → `LOW_CONFIDENCE`
  (`R² < r2_gate`) → `OK`. Note the `FLAT` definition: Oracle's `REGR_R2`
  returns **1** for a zero-variance *y* (a truly flat series) and NULL only for
  zero-variance *x*, so flatness is detected by `slope = 0`, not by a NULL R².
- `CAPF_CPU_TREND` applies the same fit per `(dbid, con_dbid, metric)` to
  `BUSY_PCT` (daily average), `BUSY_P95`, `BUSY_PEAK` (M10.1), `DB_CPU_SEC`,
  `DB_CPU_PCT` and `DB_CPU_P95` (M10.2). Every percent-of-capacity metric gets
  `days_to_sat` (+ `_lo/_hi`) against `cpu_sat_pct`; `DB_CPU_SEC` has no
  ceiling, so its `days_to_sat` is NULL. `CAPR_ALERTS.CPU_SAT` keys off
  `BUSY_P95` by default (`cpu_sat_on_p95 = 1`; set 0 for the daily average),
  and `DBCPU_SAT` fires per container off `DB_CPU_PCT`.

## Layer 2b / 3b — fixed-ceiling series (M11)

Three more series share one property with tablespaces: a value approaching a
**hard ceiling that is not a byte count**. Rather than a view per series they
land in one generic pair keyed by a `series` name, so the report, the alert
view and any future series need no extra code.

`CAPD_SERIES_DAILY (dbid, con_dbid, series, day_dt, value, limit_value, unit,
n_samples)` — `ddl/25_series_daily.sql`, a UNION ALL of:

| series | value | limit_value | unit |
| --- | --- | --- | --- |
| `PROCESSES` / `SESSIONS` | daily `MAX(max_utilization)` per instance, **summed** across instances | the `processes` / `sessions` parameter, summed across instances | `COUNT` |
| `REDO_GB_DAY` | `SUM('redo size' deltas)/2³⁰` for the day | NULL — no ceiling | `GIB_PER_DAY` |
| `DB_SIZE_GB` | `SUM(used_bytes)/2³⁰` over `CAPD_TBSPC_DAILY` | `SUM(limit_bytes)/2³⁰` | `GIB` |

- `MAX_UTILIZATION` is a **high-water mark since instance startup**, so within
  one startup epoch it is monotone and the daily MAX is the end-of-day HWM —
  exactly the number a DBA compares against `processes`. A restart resets it,
  which reads as a level shift (degrading R², not lying).
- RAC: limits are per instance, so both the utilization and the ceiling are
  summed. If **any** instance's limit is non-numeric (`UNLIMITED`) the day's
  `limit_value` is NULL rather than an understated sum.
- `REDO_GB_DAY` uses the identical diff-and-restart-guard as `CAPD_CPU_DAILY`
  (LAG per `(dbid, con_dbid, instance)` by `snap_id`; drop the first snap of a
  partition, negative deltas, and restart-spanning intervals). The delta is
  attributed to the day the interval **ends** on.
- `DB_SIZE_GB` inherits everything `CAPD_TBSPC_DAILY` already decided: **UNDO
  and TEMPORARY are excluded**, and M9.5 overrides / exclusions are applied. So
  "total DB size" means permanent-tablespace bytes actually used.

`CAPF_SERIES_FORECAST` — `ddl/35_series_forecast.sql`, the same REGR fit, the
same M9.1 prediction bands (`t ≈ 1.96 + 2.4/df`) and the same quality ladder as
`CAPF_CPU_TREND`, but aimed at a per-series ceiling instead of a global percent:

```
sat_value     = limit_value · series_sat_pct/100        (knob, default 90)
days_to_limit = FLOOR((sat_value − cur_val) / slope)    NULL if no limit or slope <= 0
```

`days_to_limit_lo/_hi` bound it with the 95% CI on the slope (lo = worst case);
`pct_of_limit` is the how-close-now number, independent of the fit. The
arithmetic is **copied**, not shared, on purpose: `CAPF_TBSPC_FORECAST` and
`CAPF_CPU_TREND` grow robust slopes and change-point resets on their own
schedule, while this view stays a plain, hand-auditable OLS fit.

Two alert kinds and one report view ride on it: `SERIES_LIMIT` (quality `OK`,
`days_to_limit <= dtf_warn`), `SERIES_NEARLIMIT` (`pct_of_limit >=
nearfull_warn_pct` now, at **any** quality — the M7.1 rule again) and
`CAPR_SERIES` (report section 7).

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
  bytes. **M10.5**: a day carrying `gap_flag = 'Y'` is neither scored nor used
  as a baseline observation — an AWR outage is an instrumentation event, not a
  CPU event, and a 36 h average has no business dragging a same-weekday median
  around. `gap_flag` and `day_gap` ride through so the report can say *why* a
  visibly odd day is unflagged.
- **`CAPA_CPU_SHIFT` (M10.3)** — the failure mode the two views above are
  structurally blind to: a **sustained step**. A new release adds +18 points
  and stays there; every individual day sits inside `k·MAD` of its own weekday
  baseline, so nothing ever flags, and the trend fit is too noisy (low `R²`) to
  say anything either — yet the machine now runs materially hotter than it did
  a month ago. So this view compares **windows, not days**, per
  `(dbid, con_dbid, metric ∈ {BUSY_PCT, BUSY_P95, DB_CPU_PCT})`:
  `recent_med` over the last `shift_days` (7) against `base_med` over the
  `shift_baseline_days` (28) immediately before it, with
  `shift_pct = recent_med − base_med` in percentage **points**. `UP` requires
  all four of: `shift_pct > shift_min_pct` (15); a full recent window
  (`n_recent ≥ shift_days` — gap days are excluded from the source, so a window
  with a gap in it cannot flag); enough baseline (`n_base ≥ shift_days`); and
  the **N-of-M confirmation** `n_above ≥ shift_days`, i.e. *every* day of the
  recent window sits above `base_med + max(base_mad_sigma, cpu_min_mad_pct)`.
  That last clause is what separates a genuine step from one loud day dragging
  a 7-day median: a single spike moves the median but cannot put all seven days
  over the line. `DOWN` is the mirror image (workload left, a container was
  moved off) and alerts as INFO, not WARN. One row per series — the **current
  state**, not a per-day series — so a poller reads it unconditionally, and
  every input (`recent_med`, `base_med`, `base_mad_sigma`, `n_recent`,
  `n_base`, `n_above`, `n_below`, both thresholds) is exposed so a flag is
  re-derivable by hand. `BUSY_PEAK` is deliberately not covered: it is already
  a same-window average of `BUSY_PCT`'s busiest hours, so it shifts with them
  and would only duplicate the alert.

Self-join cost is O(days·window) at daily grain — fine for ≤ ~400 days, and it
keeps every flag hand-recomputable.

## Layer 5 — Tier 2 OML ESM

`ml/cap_forecast_ml` trains one exponential-smoothing model per series (19c has
no partitioned ESM) via `DBMS_DATA_MINING.CREATE_MODEL2(mining_function =>
'TIME_SERIES')`, registered in `CAP_ML_MODEL`.

- CPU series use `EXSM_ADDWINTERS` with weekly seasonality (7). Tablespaces
  **choose** between `EXSM_HOLT` (additive trend, no seasonality) and the same
  `EXSM_ADDWINTERS(7)` — see "Model-type selection" below. `data_query` is built
  as literal-embedded per-series text (it can't bind); series keys are Oracle
  identifiers so quote-doubling is injection-safe.
- **Quality gate (M10.4)**: only series whose Tier 1 fit is `OK` or
  `LOW_CONFIDENCE` are trainable — `FLAT` and `INSUFFICIENT_HISTORY` series have
  no trend for ESM to learn, and letting them into the top-N would burn model
  builds on noise. Tablespaces are gated on `CAPF_TBSPC_FORECAST.quality`, the
  two CPU series on `CAPF_CPU_TREND.quality`.
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
  `n_days` records actual coverage.
- **Model-type selection (M10.4)**: with `esm_tbspc_model = 2` (AUTO) and
  `esm_select_by_backtest = 1` — both defaults — `train_tablespaces` first
  builds **two** backtest twins per tablespace series, one per candidate
  (`EXSM_HOLT` and `EXSM_ADDWINTERS(7)`), then trains the production model with
  whichever scored the lower holdout MAPE in the new `CAPF_ESM_CANDIDATE` view
  (one row per *(series, model_type)*). Ties, and "no evidence" (a candidate
  that failed to train), go to `EXSM_HOLT` — the historical default and the
  cheaper model. The decision and its evidence are written back onto the
  production row: `CAP_ML_MODEL.model_type` / `chosen_by` (`AUTO_BACKTEST` |
  `CONFIG` | `DEFAULT`) / `mape_holt` / `mape_addw`, which is what lets report
  section 6c print *"ADDW H=2.90 W=1.20"* instead of an unexplained pick.
  `esm_tbspc_model = 0 | 1` pins a type and skips the twins entirely;
  `esm_select_by_backtest = 0` makes AUTO fall back to `EXSM_HOLT`.
  The twins' names hash *(dbid | con_dbid | series_key | model_type)* so the two
  candidates cannot collide, and `train_backtest` purges any twin of a series
  that is no longer in the candidate set (which is how a pre-M10.4 twin, hashed
  without the model type, gets cleaned up).
  `CAPF_BACKTEST` keeps its one-row-per-*(series, engine)* shape: its ESM row is
  the **selected** candidate (matched on the production model's `model_type`,
  else the lowest MAPE, else Holt) and the new `model_type` column names it.
  Per-candidate detail stays in `CAPF_ESM_CANDIDATE`.

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

## Layer 6 — integration + report views (`CAPR_*`, M7.2/M8.1/M8.2)

Seam-agnostic views for consumers outside the bundled reports — and, since
M8.2, for the bundled reports themselves:

- `CAPR_CONTAINER` wraps `CAPV_CONTAINER` and computes `db_pdb`, the one
  display label every report section prints instead of a raw `con_dbid`
  (root/non-CDB → db name alone; PDB → `DBNAME/PDBNAME`; unnamed → the raw
  `con_dbid` as text). Defining the label once keeps text and HTML from
  drifting.
- `CAPR_ALERTS` is the pollable alert surface: one row per current issue with
  `severity` (CRIT/WARN/INFO + numeric `sev_rank`), `kind` (`TBSPC_FULL`,
  `TBSPC_NEARFULL`, `TBSPC_ANOM`, `CPU_SAT`, `DBCPU_SAT`, `CPU_ANOM`,
  `CPU_SHIFT`), keys, `value` vs
  `threshold` (+ `unit`), and a ready-to-page `message`. The forecast kinds
  gate on `quality = 'OK'`; `TBSPC_NEARFULL` deliberately does **not** (M7.1:
  a 97%-full tablespace with an unfittable series must still surface — that's
  a fact about *today*, not a forecast). Anomaly kinds use the
  `anomaly_report_days` knob as their window (the reports' `anomaly_days`
  DEFINE is presentation-only). Both reports' at-a-glance blocks read this
  view, so paging and reporting can never disagree.

**M8.2 — one view per report section.** Every section's SELECT now lives in a
`CAPR_*` view, so `report/report.sql` (via `report/sections/*.sql`) and
`report/report_html.sql` only *format*: no analytic SQL is duplicated between
the two drivers, and they cannot drift.

| view | section | notes |
| --- | --- | --- |
| `CAPR_TBSPC_DAYS_TO_FULL` | 1a + 1b | `pct_used`, GiB/MiB numeric columns, `sev_dtf` (days) and `sev_nearfull` (percent) markers, the M9.1 `dtf_worst`/`dtf_best` range, plus `rank_dtf` / `rank_nearfull` (`ROW_NUMBER`) so a driver applies `top_n` with `WHERE rank_* <= n` instead of its own `ORDER BY … FETCH FIRST` |
| `CAPR_TBSPC_FORECAST` | 2 | GiB projections + the +180 band, `train_n`, `r2`, `quality`, the Tier 2 `esm30`/`esm30_lo`/`esm30_hi` point, raw byte columns and `rank_chart` for the HTML chart grid, plus the M7.4 bound `is_reportable` / `rank_report` |
| `CAPR_TBSPC_ANOMALIES` | 3 | flagged rows only, MiB conversions, `day_str`, and `days_ago` = `MAX(day_dt)` over `CAPD_TBSPC_DAILY` minus the row's day, so the report window is `WHERE days_ago < anomaly_days` |
| `CAPR_CPU_TREND` | 4 | per (container, metric) trend with `sat_worst`/`sat_best` |
| `CAPR_CPU_ANOMALIES` | 5a | same contract as the tablespace anomaly view |
| `CAPR_CPU_SHIFTS` | 5b | the M10.3 level shifts: flagged rows only, both medians, both window lengths and the N-of-M counts, ranked by `|shift_pct|` via `rank_shift` |
| `CAPR_ESM_COMPARE` | 6a/6b | REGR vs ESM pivoted per (container, series, horizon), in raw units *and* GiB; filter on `series_kind`. Inherits `is_reportable` / `rank_report` from `CAPR_TBSPC_FORECAST` (CPU rows: always `'Y'`, rank 0) so 6a shows exactly section 2's tablespaces |
| `CAPR_BACKTEST` | 6c | the M9.4 holdout scorecard pivoted per series, incl. the `better` verdict |

All of them resolve `db_pdb` through `CAPR_CONTAINER` themselves. The last
three read `CAPF_COMPARE` / `CAPF_BACKTEST`, which `ddl/50_ml.sql` creates
*after* `ddl/45_report_views.sql`, so they live in `ddl/55_report_views_ml.sql`
(loaded last by `install.sql`). What is still computed inside
`report_html.sql` is only chart *geometry*: raw `CAPD_*` history points, the
anomaly-dot / timeline placements, and the whole-database `cur_hero`
regression that has no section of its own.

## Report

`report/report.sql` spools a read-only text report (7 sections: an
at-a-glance alert roll-up from `CAPR_ALERTS`, then the six detail sections) to
`reports/cap_report_<db>_<ts>.txt`. Identity comes from `SYS_CONTEXT` (no `V$`
or catalog privileges needed, so any monitoring schema can run it). Since M8.2
the sections consume **only** `CAPR_*` — they are `SELECT` + `COLUMN` formats
and nothing else. `show_esm` = `AUTO`/`Y`/`N` controls
the Tier 2 section (AUTO prints a hint when no models are trained). Section 1
ranks days-to-full across **all** fit qualities (marker column says how much
to trust each row) and adds a near-full-now ranking by `pct_used` (M7.1).

**M7.4 — sections 2 and 6a are bounded.** A 500-tablespace database used to
print 500 forecast rows and 2000 compare rows. The views now decide, once:
`is_reportable` = growing **or** near-full **or** at least `report_min_gb` GiB
used (near-full is in the disjunction on purpose — M7.1's rule that a nearly
full tablespace never disappears outranks a size cutoff), and `rank_report`
orders reportable first, then growing, then biggest. Both drivers apply the
identical `WHERE is_reportable = 'Y' AND rank_report <= top_n` and print the
resulting bound in the section header ("Showing 7 of 8 tablespace(s) …"); the
views keep every row for other consumers.

**M7.6 — positional arguments.** `@report/report.sql [top_n] [anomaly_days]
[show_esm]` and the same for `report_html.sql`. `report/defaults.sql` stays the
fallback source of truth: both drivers load it, then override each value with
its argument if one was passed. Unset `&1..&3` cannot prompt (a prompt would
hang a non-interactive run and swallow the next heredoc line) because a
`COLUMN 1 NEW_VALUE 1` whose query returns **no rows** defines the variable as
empty, while an argument that *was* passed survives — SQL*Plus only reassigns a
`NEW_VALUE` on a fetched row. Both scripts `UNDEFINE 1 2 3` at the end, so a
second script in the same session does not inherit the first one's arguments.

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
