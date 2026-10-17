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
- **One config access path.** Every threshold is a `CAP_CONFIG` row, and views
  read knobs only through the one-row view `CAP_CFG` (one NUMBER column per
  knob, named after it), joined as `CROSS JOIN cap_cfg cfg`. No view pivots
  `CAP_CONFIG` itself, and no default is inlined in `CAP_CFG`: the shipped
  values live only in the MERGE in `ddl/05_config.sql`. A deleted key reads
  NULL, and a NULL knob makes a predicate such as
  `day_dt > last_day - cfg.train_days` silently false. So `CAP_CFG_CHECK`
  reports each knob as `OK`, `MISSING` or `BAD` (a broken range rule such as
  `recent_days > train_days`). `cfg_default` holds the shipped value: the MERGE
  inserts a missing key with `cfg_value = cfg_default`, and on a re-install
  refreshes only `cfg_default` and `cfg_desc`. The reset is
  `UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = '...'`.
- **19c floor.** No 21c+ syntax (notably: no standalone `WINDOW` clause).

## Layer 1 — the seam (`CAPV_*`)

Nine views re-present the AWR dictionary in a stable shape. Everything
downstream depends only on these, so swapping `ddl/10_seam_local.sql` for `11`
(warehouse) or `12` (fixture) re-points the whole stack. Every view carries
`(dbid, con_dbid)`. A tenth view, `CAPV_CONTRACT`, describes what the other
nine present (see the last bullet).

- `DBA_HIST_SNAPSHOT` has no `CON_DBID`, so `CAPV_SNAPSHOT` sets
  `con_dbid := dbid`. The tablespace / OS / time-model views expose the **real**
  `CON_DBID`, which is mandatory: `TABLESPACE_ID`/`TS#` restart at 0 per
  container, so `SYSTEM` in the root and in a PDB collide unless `con_dbid`
  disambiguates them.
- **Per-container sources.** In `CDB$ROOT` (with the default
  `AWR_PDB_AUTOFLUSH_ENABLED = FALSE`) only some AWR views have a row per
  container: `DBA_HIST_TBSPC_SPACE_USAGE`, `DBA_HIST_CON_SYS_TIME_MODEL` and
  `DBA_HIST_CON_SYSSTAT`. `DBA_HIST_SYS_TIME_MODEL` and `DBA_HIST_SYSSTAT`
  have one row per snapshot, under the root's `con_dbid`, and that row is the
  CDB-wide total. Verified on 19c: root + seed + PDB1 DB CPU in the `CON_`
  view summed to the `SYS_` row within 0.3%.
  So `CAPV_TIME_MODEL` and `CAPV_SYSSTAT` read the `CON_` views. Their root
  row is `CDB$ROOT` alone, and the CDB total is the sum over containers.
  `PDB$SEED` is dropped with `CON_ID <> 2` (the seed is always container 2;
  it runs nothing). A snapshot with no `CON_` row at all (a non-CDB, or AWR
  imported from one) falls back to the `SYS_` view, where `con_dbid = dbid`.
  The three remaining sources are root-only by nature: `DBA_HIST_OSSTAT`
  (host level), `DBA_HIST_RESOURCE_LIMIT` (instance level) and
  `DBA_HIST_SNAPSHOT`. Reading the `SYS_` views gave local mode one DB CPU
  and redo series per CDB, labelled as the root, so per-PDB `DB_CPU_PCT`,
  `DBCPU_SAT`, the PDB level shift and `host_share_pct` only ever worked on
  fixture data. The warehouse collector still gathers the `SYS_` views, so in
  warehouse mode those two series stay CDB-level (header of
  `ddl/11_seam_warehouse.sql`; a collector change in the sibling repo).
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
- `CAPV_RESOURCE_LIMIT` / `CAPV_SYSSTAT` (M11).
  `DBA_HIST_RESOURCE_LIMIT` (filtered to `processes` / `sessions`) has a
  `CON_DBID` column, but in `CDB$ROOT` its rows are root-only (verified on
  19c): the limits are instance-wide, so `PROCESSES` / `SESSIONS` are CDB-wide
  series. Its `LIMIT_VALUE` is a `VARCHAR2(10)` that can read `UNLIMITED`,
  converted here to a NUMBER (non-numeric → NULL = "no ceiling").
  `CAPV_SYSSTAT` is filtered to `redo size`, a cumulative byte counter, per
  container (see above). The warehouse collects SYSSTAT whole
  (`awrv_sysstat`, no `CON_DBID`, so `con_dbid := dbid`: one CDB-level redo
  series) but has **no** resource-limit fact yet, so
  `ddl/11_seam_warehouse.sql` emits `CAPV_RESOURCE_LIMIT` with the exact
  column contract and `WHERE 1 = 0`: the stack stays valid in warehouse mode
  and the `PROCESSES` / `SESSIONS` series simply have no rows there.
- `CAPV_CONTRACT` is a diagnostic over the seam itself, the same body in all
  three seam files: one row per fact source (`SNAPSHOT`, `TBSPC_USAGE`,
  `OSSTAT`, `TIME_MODEL`, `SYSSTAT`, `RESOURCE_LIMIT`) with `n_rows`,
  `n_con_dbid`, `min_snap_id` / `max_snap_id`, `max_end_time` and
  `per_container_expected` (`Y` for tablespace usage, time model and sysstat,
  `N` for the host, instance and spine sources). `n_con_dbid = 1` against a
  `Y` says the per-PDB series are missing, which is what a warehouse with the
  old collector shows. It full-scans every source, so no analytic view reads
  it. It is meant for `doctor.sql`.

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
- **`CAPD_COUNTER_DELTA`** differences every cumulative counter once: the
  OSSTAT `*_TIME` counters, the three time-model counters and `CAPV_SYSSTAT`.
  One row per `(dbid, con_dbid, instance, source, stat_name, interval)` with
  `end_time`, `prev_end_time`, `ivl_sec`, `delta`, `startup_time` and
  `is_restart`. `is_restart = 'Y'` when the interval spans an **instance
  restart** (`startup_time` differs from the previous snapshot's) or shows a
  **negative delta** (counter reset). The startup test is
  `DECODE(startup_time, prev_startup, ...)`, which treats two NULLs as equal:
  a source that never fills `startup_time` keeps its series, where the old
  `startup_time = prev_startup` test silently emptied it. The first snapshot
  of each partition has no row. The CPU, DB time and redo views pivot these
  rows per interval (grouping by `prev_end_time` too, so two counters pair up
  only when they difference the same two snapshots) and keep `is_restart =
  'N'`. Before this view the LAG and the guard were pasted three times.
- **`CAPD_CPU_DAILY`** — `BUSY_TIME`/`IDLE_TIME` deltas from
  `CAPD_COUNTER_DELTA`, restart intervals dropped. Per day:
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
- **`CAPD_DBTIME_DAILY`** — the time-model deltas, same restart rule, per
  container → `db_cpu_sec`, `db_time_sec`, `bg_cpu_sec` (÷1e6). In local mode
  the root row is `CDB$ROOT` alone; the CDB's DB CPU is the sum over its rows.
  `db_cpu_per_core` divides by the host core count summed across instances
  from OSSTAT (falling back to `NUM_CPUS`). **DB CPU as % of logical-CPU
  capacity (M10.2):** `db_cpu_pct = 100·db_cpu_sec / Σ(num_cpus·ivl_sec)` over
  the day's valid intervals, plus per-interval `db_cpu_p95_pct` /
  `db_cpu_max_pct` / `db_cpu_peak_pct` (DB CPU seconds over the interval's
  `num_cpus·ivl_sec`, same peak-window rule). The denominator is logical CPUs
  (`NUM_CPUS`, else `NUM_CPU_CORES`) because Oracle accrues CPU time per
  logical CPU, OSSTAT `BUSY_TIME`/`IDLE_TIME` are summed over `NUM_CPUS`, and
  the AWR report's own %Total CPU divides by `NUM_CPUS`. Dividing by cores read
  2× on a 2-way SMT host (4–8× on POWER / SPARC) and fired `DBCPU_SAT` at half
  load. Now `db_cpu_pct = busy_pct · host_share_pct / 100`, the same scale as
  host busy%. `num_cpus` is read per interval at its end snapshot (OSSTAT is
  host level, so it is matched on `(dbid, instance, snap_id)` and serves every
  container; a snapshot without an OSSTAT row uses the instance's last earlier
  value), so a host resize no longer rewrites history. `num_cpus` /
  `num_cpu_cores` are exposed per day (MAX per instance, summed across
  instances). `host_share_pct = 100·db_cpu_sec / host busy seconds` (host busy
  summed over the `dbid`, since OSSTAT records under the CDB's `con_dbid`) is
  the per-PDB share of what the host was actually doing.

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
  recorded. Both divide by the time covered, so neither reads high on a gap
  day; the daily totals (`db_cpu_sec`, `host_busy_sec`, `REDO_GB_DAY`) do
  carry more than a day, and `gap_flag` is the column that says so.
- `CAPA_CPU_ANOM` and `CAPA_CPU_SHIFT` (Layer 4) drop gap days from their
  baselines and never flag one.

Why 12 hours and not something tighter: `gap_flag` *suppresses* anomaly
scoring, so an over-sensitive default would silence the whole CPU anomaly layer
on any site whose snapshot interval is wide. Half a day is comfortably above
every realistic AWR interval and still catches real outages.

**Day coverage.** A gap is one kind of incomplete day. Three others never
raise `gap_flag`: the first day of AWR history, today (a row exists as soon as
the first snapshot after midnight lands), and a restart or outage day, whose
restart-spanning interval is dropped *before* `max_interval_hours` is taken.
On such a day the flow totals (`db_cpu_sec`, `host_busy_sec`, `REDO_GB_DAY`)
read low. So `CAPD_CPU_DAILY`, `CAPD_DBTIME_DAILY` and the `REDO_GB_DAY` rows
of `CAPD_SERIES_DAILY` expose:

- `covered_sec`: the seconds of valid (non-restart) intervals ending that
  day, per instance (summed, then divided by the instances that reported).
  86400 for a full day, 43200 for a day with one 12 h interval, more than
  86400 on a gap day.
- `is_complete`: `'Y'` when `covered_sec >= complete_day_pct/100 · 86400`
  (knob, default 80), else `'N'`.

`gap_flag` keeps its meaning. The level series of `CAPD_SERIES_DAILY`
(`PROCESSES`, `SESSIONS`, `DB_SIZE_GB`) read one sample a day and carry
`covered_sec` NULL and `is_complete = 'Y'`. The forecast and anomaly layers do
not filter on `is_complete` yet; until they do, a partial day still enters fits
and baselines with its low totals.

All `LAG`s use inline `OVER (...)` (19c has no `WINDOW` clause).

## Layer 3 — Tier 1 forecasts (`CAPF_*`)

Ordinary least squares via `REGR_*` over `day_n = day_dt − DATE '2020-01-01'`
(an integer day index off a fixed epoch → slopes are per-day and stable).

- Two fits per series: the primary over `train_days` (90) and a "recent" fit
  over `recent_days` (28); `accel_ratio = recent_slope / slope` (>1.5 in the
  report highlights accelerating growth).
- **Anchored at today.** Projections are `cur_used + slope·h` for
  h ∈ {30,90,180,365}: the fit supplies the slope, the current value supplies
  the starting point. `days_to_full = GREATEST(0, FLOOR((limit − cur_used) /
  slope))` when `slope > 0` starts from the same point, so the +30 column and
  the countdown describe one line (before this they could disagree by the last
  day's residual, e.g. a stepped series whose fitted line sat far below its
  current value). `icept` is still the fitted intercept, so residuals stay
  `y − (icept + slope·day_n)`. A series whose last point sits on its fitted
  line projects exactly as before (the `FIX_LINEAR` fixture asserts it).
- **Clamp and flag.** `days_to_full`, `_lo` and `_hi` are clamped at 0: a
  ceiling already below the current usage (an override under the used size)
  reads 0, not a negative count. `limit_below_used = 'Y'` marks those rows
  (`limit_bytes < cur_used`, so `pct_used` is over 100). A flat series has no
  countdown at all (`days_to_full` NULL) whatever its ceiling.
- **Staleness.** `newest_day` is the newest day of the view's daily source for
  the same dbid, and `is_current = 'Y'` when `last_day >= newest_day −
  stale_days` (knob, default 3). A dropped tablespace or a series that stopped
  arriving keeps its last forecast until AWR purges it; `is_current = 'N'` says
  so. The test uses the data only (no `SYSDATE`). The CAPR_ views pass the flag
  through; nothing filters on it yet.
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
  expectations with the same formula). The half-widths are centred on the
  fit's own x̄ as before, but the band is drawn around the anchored projection:
  `proj_h ± half_h`. A perfectly linear or flat series has SSE = 0, so its
  bands collapse onto the point projection.
- **Robust slope (M9.2)** — knob `slope_method` (`CAP_CONFIG` is numeric:
  **0 = OLS**, the default, **1 = THEILSEN**, **2 = DRIFT**, next bullet). OLS minimises *squared* error, so
  a single step — a bulk load, an import, a partition drop — drags the whole
  slope with it: the `FIX_SPIKE` fixture grows at 5 MiB/day yet reads ~20 MiB/day
  in OLS because of one +2 GiB day. The **Theil–Sen** estimator is the `MEDIAN`
  of the pairwise slopes `(y_j − y_i)/(x_j − x_i)` over every `i < j` in the
  training window (a self-join, O(n²) ≈ 4k pairs at 90 days); its 29% breakdown
  point means a minority of stepped pairs cannot move it. The intercept is the
  companion `MEDIAN(y − slope·x)`. Theil–Sen is computed **only when asked**:
  the pair self-joins read an input that is empty unless `slope_method = 1`,
  so the default pays nothing for them (the fixture's `CAPF_TBSPC_FORECAST`
  runs in roughly a quarter of the time) and `ts_slope_bpd` / `ts_slope_per_day` /
  `ts_icept` are NULL. `ols_slope_bpd` / `ols_slope_per_day` are always there,
  and the `slope_method` column reports which estimator the row actually used:
  OLS when Theil–Sen was not computed or could not be. When THEILSEN is
  selected the chosen slope drives `slope_bpd`, `icept`, every `proj_*`,
  `days_to_full` / `days_to_sat`, **both** halves of `accel_ratio` (mixing
  estimators would manufacture acceleration) and the `slope = 0` FLAT test.
  `r2`, `resid_se`, `slope_ci_bpd` and the M9.1 half-widths stay **OLS**
  quantities: there is no closed-form Theil–Sen prediction interval in SQL, so
  the bands are OLS residual bands drawn around the anchored projection, and
  `days_to_full_lo/hi` remain the OLS slope-CI range (so under THEILSEN the
  point `days_to_full` can fall outside its own range). Applies to
  `CAPF_CPU_TREND` as well.
- **DRIFT estimator**: `slope_method = 2`. `used_bytes` is a cumulative
  level, so the residuals of a line through it are autocorrelated: in a
  simulation of random walks with drift (n = 90) the OLS 95% slope CI covered
  the true drift about 14% of the time, and a driftless walk graded `OK` with a
  positive slope in about 18% of windows. DRIFT works on the day-over-day
  rates of the (reset-aware) training window instead:

  ```
  rate_i   = (y_i − y_prev) / (day_n_i − day_n_prev)    inside the window
  slope    = MEDIAN(rate)                               robust to a one-off step
  sd       = STDDEV_SAMP(rate)     se = sd / √n_rates
  t        = 1.96 + 2.4 / (n_rates − 1)                 the M9.1 approximation
  slope CI = t · se
  half_h   = t · (sd·√h + h·se)
  ```

  `half_h` adds the random-walk fan (`sd·√h`) and the rate uncertainty carried
  `h` days (`h·se`) as a plain sum, which is wider than the root of the sum of
  squares: a conservative band. The first day of the window has no rate, so a
  reset day's cliff never enters. Projections stay anchored at `cur_used`, so
  no intercept is fitted; `icept` is reported as `cur_used − slope·last_day_n`,
  the line the projections lie on. `days_to_full_lo/hi` come from `slope ± CI`.
  Quality has no R² gate: `FLAT` when the slope is 0, `LOW_CONFIDENCE` when the
  CI includes 0, else `OK` (`r2` stays the OLS R², for reference). Fixture
  readings: `FIX_LINEAR` 10 MiB/day with sd 0 (bands collapse, 4990 days);
  `FIX_SPIKE` 5 MiB/day, the +2 GiB day being one rate of 89, but its sd
  (2 GiB/√89) puts the CI at ±45.7 MiB/day, so `LOW_CONFIDENCE`; `FIX_PURGE`
  10 MiB/day after the reset. The median of a strictly alternating series is
  one of its two rates: `FIX_ZIGZAG` (+50 / −30 MiB, mean 10) reads 50 MiB/day.
  `drift_slope_bpd` / `drift_sd_bpd` are exposed under every `slope_method`.
  The same estimator applies to `CAPF_CPU_TREND` (rates of the fit input) and
  `CAPF_SERIES_FORECAST`.
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
  window and is deliberately left alone. Its REGR replay is anchored like the
  live projections: `pred = actual(cutoff) + slope·(day_n − cutoff_n)`, the
  anchor being the last training day's actual value. The replay's slope
  follows `slope_method` (OLS, Theil–Sen over the window's pairs, or DRIFT),
  and `CAPF_BACKTEST.slope_method` names it, so flipping the knob compares the
  estimators on the same holdout.
- **CYCLIC grade**: knob `cyclic_min_cliffs` (2; 0 = off). A rolling-retention
  tablespace (fill for a month, purge, repeat) has a cliff in every cycle. The
  M9.3 reset restarts at the most recent one only, so the post-purge leg reads
  as fast growth that never fills: the demo's `SESSION_STORE` (20 → 92.5 GiB in
  a 300 GiB tablespace) read `112 − k` days to full on cycle day k and fell
  through `dtf_warn` 8 days a month; a weekly purge would never collect
  `min_train_days` rows. So the cliffs of the **full** `train_days` window are
  counted with the M9.3 rule (`cycle_n`, on every row). With `cycle_n ≥
  cyclic_min_cliffs` no reset applies and quality is `CYCLIC`, judged on the
  peaks: `cycle_days` (median spacing of the cliffs), `cycle_peak_bytes` /
  `cycle_peak_pct` (the window's maximum, against `limit_bytes`),
  `peak_slope_bpd` (OLS through the per-cycle maxima, the maximum of each
  segment that ends at a cliff, when there are at least 3, else NULL) and
  `days_to_full` = days until the peak line, anchored at the last cycle
  maximum, reaches the limit, NULL unless `peak_slope_bpd > 0`.
  `days_to_full_lo/hi` and `accel_ratio` are NULL; the cycle columns other than
  `cycle_n` are NULL on non-`CYCLIC` rows. `CAPR_ALERTS.TBSPC_FULL` needs
  quality `OK`, so a `CYCLIC` row never pages on its countdown. The count does
  not depend on `reset_on_shrink`. Fixture: `FIX_CYCLIC` (flat peaks, no
  countdown) and `FIX_CYCLIC_UP` (peaks +1 GiB a cycle, `peak_slope_bpd` =
  1 GiB/30 d); with the grade off `FIX_CYCLIC` raises the old false page.
- **Quality** (priority order): `INSUFFICIENT_HISTORY` (`train_n <
  min_train_days`) → `CYCLIC` (tablespaces, above) → `FLAT` (chosen `slope =
  0`, or `R² IS NULL` outside DRIFT) → `LOW_CONFIDENCE` (`R² < r2_gate`; for
  DRIFT, and for CPU under `cpu_quality_gate = 1`, the slope CI includes 0) →
  `OK`. Note the `FLAT` definition: Oracle's `REGR_R2`
  returns **1** for a zero-variance *y* (a truly flat series) and NULL only for
  zero-variance *x*, so flatness is detected by `slope = 0`, not by a NULL R².
- `CAPF_CPU_TREND` applies the same fit per `(dbid, con_dbid, metric)` to
  `BUSY_PCT` (daily average), `BUSY_P95`, `BUSY_PEAK` (M10.1), `DB_CPU_SEC`,
  `DB_CPU_PCT` and `DB_CPU_P95` (M10.2). It fits **complete days only**
  (`is_complete = 'Y'` in `CAPD_CPU_DAILY` / `CAPD_DBTIME_DAILY`): a partial,
  restart or outage day averages over less than `complete_day_pct` of the day
  and would pull the line. `last_day`, `train_start`, `cur_val` and the anchor
  all come from complete days; `newest_day` counts every day with a value, so
  today's partial day does not make a series stale. Every percent-of-capacity
  metric gets `days_to_sat` (+ `_lo/_hi`) against `cpu_sat_pct`; `DB_CPU_SEC`
  has no ceiling, so its `days_to_sat` is NULL. `CAPR_ALERTS.CPU_SAT` keys off
  `BUSY_P95` by default (`cpu_sat_on_p95 = 1`; set 0 for the daily average),
  and `DBCPU_SAT` fires per container off `DB_CPU_PCT`.
  - **Weekday / weekend deseasoning**: knob `cpu_deseason` (1). A host at 60%
    on weekdays and 20% at weekends keeps most of its variance in the weekly
    pattern: with a true +10 point trend over 90 days, R² passed the 0.60 gate
    in 0% of simulated windows, so `CPU_SAT` / `DBCPU_SAT` could never fire
    (on dbmint, 6 of 6 real CPU metrics read `LOW_CONFIDENCE`). With 1 the fit
    input is `fval = val − AVG(val of the same day type) + AVG(val)` over the
    window, day type = weekday or Saturday/Sunday; a perfectly periodic weekly
    pattern drops out and a ramp survives. Slope, `icept`, `r2`, the bands,
    Theil–Sen and the DRIFT rates are all computed on `fval`; `deseasoned`
    (`'Y'/'N'`) says which input the row used.
  - **Quality gate**: knob `cpu_quality_gate` (1). 1 = slope significance:
    `OK` when `|slope| > slope_ci_per_day`, else `LOW_CONFIDENCE` (`FLAT` when
    the slope is 0); 0 = the legacy `R² ≥ r2_gate`. `slope_sig` (`'Y'/'N'`)
    reports the significance test under either gate, `r2` is still reported.
    Both knobs default to 1, a deliberate change of the CPU grades; setting
    both to 0 reproduces the old fit. Tablespace and series fits keep their
    gates.
  - **Anchor**: `anchor_value` = `MEDIAN(val)` over the complete days in the
    last `shift_days` days (raw values). Projections and `days_to_sat` start
    there: anchoring at `cur_val` swung the +30 with the weekday of the last
    day (the fixture's `BUSY_PCT` ends on a 20% weekend day against a 40%
    weekday level). Tablespaces keep `cur_used`, a level rather than a noisy
    sample. `cur_val` is still the raw last complete day.
  - **Hot now**: for `BUSY_P95` and `DB_CPU_P95`, `recent_p95_med` is that
    same median and `hot_now = 'Y'` when it is at or above `cpu_sat_pct`:
    saturated in the busy hour now, whatever the trend says (tablespaces and
    series have `NEARFULL` / `NEARLIMIT` for this). A column only; no alert
    reads it yet.

## Layer 2b / 3b — fixed-ceiling series (M11)

Three more series share one property with tablespaces: a value approaching a
**hard ceiling that is not a byte count**. Rather than a view per series they
land in one generic pair keyed by a `series` name, so the report, the alert
view and any future series need no extra code.

`CAPD_SERIES_DAILY (dbid, con_dbid, series, day_dt, value, limit_value, unit,
n_samples, covered_sec, is_complete)` — `ddl/25_series_daily.sql`, a UNION ALL of:

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
- `REDO_GB_DAY` sums the `redo size` rows of `CAPD_COUNTER_DELTA` with
  `is_restart = 'N'`, the same rule as `CAPD_CPU_DAILY`. The delta is
  attributed to the day the interval **ends** on. It is the one flow series
  here, so it carries `covered_sec` / `is_complete` (Layer 2, day coverage);
  the level series carry NULL / `'Y'`. In local mode it is per container (the
  CDB's redo is the sum); in warehouse mode it is one CDB-level series.
- `PROCESSES` / `SESSIONS` are CDB-wide: `DBA_HIST_RESOURCE_LIMIT` is
  root-only in `CDB$ROOT`.
- `DB_SIZE_GB` inherits everything `CAPD_TBSPC_DAILY` already decided: **UNDO
  and TEMPORARY are excluded**, and M9.5 overrides / exclusions are applied. So
  "total DB size" means permanent-tablespace bytes actually used.

`CAPF_SERIES_FORECAST` — `ddl/35_series_forecast.sql`, the same REGR fit, the
same M9.1 prediction bands (`t ≈ 1.96 + 2.4/df`) and the same quality ladder as
`CAPF_CPU_TREND`, but aimed at a per-series ceiling instead of a global percent:

```
sat_value     = limit_value · series_sat_pct/100        (knob, default 90)
days_to_limit = FLOOR((sat_value − cur_val) / slope)    NULL if no limit or slope <= 0
proj_h        = cur_val + slope · h                     anchored at today, as in Layer 3
```

`days_to_limit_lo/_hi` bound it with the 95% CI on the slope (lo = worst case);
`slope_method = 2` switches it to the DRIFT estimator of Layer 3 (Theil–Sen is
never computed here, so 1 reads as OLS, and the `slope_method` column says
which was used);
`pct_of_limit` is the how-close-now number, independent of the fit. The fit
reads complete days only (`is_complete = 'Y'`): the flow series `REDO_GB_DAY`
drops its partial, restart and outage days, and the level series carry `'Y'`
on every day. `newest_day` / `is_current` work as in Layer 3. The
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
  trail. `pct_vs_median` and `pct_vs_avg` restate the deviation as a
  percentage ("grew 25% more than usual") of the baseline median and of
  `avg_rate_bpd`, the **mean** rate `SUM(delta)/SUM(gap)` over the trailing
  `train_days` (90) days, current day excluded (`avg_days` = the days that sum
  covers) — the same window length the trend is fitted on, and a mean rather
  than a median because the question is "more than its long-term average".
  Both are NULL when their baseline is not positive.
- **`CAPA_CPU_ANOM`** — baseline is the prior `dow_weeks` **same weekdays**
  (`day − 7·level`, generated with `CONNECT BY`), so weekly seasonality is
  handled deterministically. The MAD floor is `cpu_min_mad_pct` (3 points),
  which plays the flat-baseline-guard role that `abs_floor_bytes` plays for
  bytes. **M10.5**: a day carrying `gap_flag = 'Y'` is neither scored nor used
  as a baseline observation — an AWR outage is an instrumentation event, not a
  CPU event, and a 36 h average has no business dragging a same-weekday median
  around. `gap_flag` and `day_gap` ride through so the report can say *why* a
  visibly odd day is unflagged. `pct_vs_median` states the deviation as a
  percentage of the same-weekday median (NULL when that median is not
  positive).
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

The percentages flow downstream unchanged: `CAPR_TBSPC_ANOMALIES` /
`CAPR_CPU_ANOMALIES` carry them as `pct_vs_med` / `pct_vs_avg` (plus `avg_mb`,
`avg_days`), the `TBSPC_ANOM` / `CPU_ANOM` alert messages end with
"+N% vs 90-day avg rate" / "(+N% vs median)", and `CAPR_ANOMALIES` appends
`pct_vs_expected` / `pct_vs_avg` at the end of its select list.

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
  The `rows/4` floor bites on short history: 90 days of AWR gives a 22-step
  model, 118 days a 29-step one.
- Predictions live in the dynamic `DM$VP<model>` view
  (`CASE_ID, VALUE, PREDICTION, LOWER, UPPER`). Because the name is only known
  at runtime, the package exposes `get_forecast(model) PIPELINED`, and
  `CAPF_ESM_FORECAST` lateral-joins it over the registry. It adds `step_days`
  (days after `trained_through` on forecast rows) and `esm_horizon_days` (the
  model's furthest step); `CAPF_ESM_BACKTEST` carries the same two columns.
- `CAPF_COMPARE` unions Tier 1 point projections (REGR, +30/90/180/365) with
  Tier 2 predictions + 95% bounds (ESM, **30-day bucket only**, the 19c hard
  cap). The ESM value is the model's **furthest** step, not exactly +30, so a
  22-step model still shows up; `esm_horizon_days` says which step it is.
  ESM rows are gated on **age**, not exact-day freshness: `model_age_days`
  (series last day minus `trained_through`) must be `<= esm_max_age_days`
  (default 7). The old exact-day rule hid ESM six days out of seven under a
  weekly retrain. A model left behind by a later top-N retrain still drops out
  once it is older than the limit. The ESM value is dated `trained_through +
  esm_horizon_days`; `CAPR_FORECAST_POINTS` turns that into a horizon from the
  series' last day (`esm_horizon_days - model_age_days`), and section 6 prints
  the step as `+22` when it is not 30, plus the model age. Model names hash
  `(dbid | con_dbid | series_key)` so a cross-database `con_dbid` collision
  cannot overwrite another database's model.
- **Build safety and health**: `build_model` builds under `<name>_N`, and only
  after `CREATE_MODEL2` succeeds drops the old model and renames the new one
  (`DBMS_DATA_MINING.RENAME_MODEL`, which also renames the `DM$VP` view; it
  refuses an existing target, hence drop-then-rename). A failed build leaves
  the old model and the registry row's description of it alone and sets
  `status = 'FAILED'`, `last_error` (message plus backtrace) and `failed_at`.
  `CAPF_ESM_FORECAST` keeps reading a FAILED row's surviving model until the
  age gate drops it. An empty training query also fails: `CREATE_MODEL2`
  accepts one and builds a model with no forecast. The public `train_*`
  procedures finish every series, then raise ORA-20060 if any FORECAST build
  failed, so a scheduler run ends FAILED instead of SUCCEEDED. `CAPF_ESM_HEALTH`
  lists every registry row with `status`, `model_age_days`, `stale_flag` (age
  over `esm_max_age_days`) and `last_error`; for a BACKTEST twin the age is
  measured against today's holdout cutoff. `CAPF_ESM_HEALTH_SUMMARY` counts
  FORECAST models per container (`n_ok`, `n_failed`, `n_stale`), which is the
  report header's Tier 2 line ("10 ok, 0 failed, 0 stale"). Twins are left out
  of those counts. `train_tablespace(name)` retrains one series, e.g. after a
  failure.
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
  `n_days` records actual coverage. `train_all(p_top_n, p_backtest => TRUE)`
  refreshes the twins of every series it trains, the CPU ones included, so
  the ESM row is scored on the same cutoff as the REGR row. That costs 3
  builds per tablespace and 2 per CPU series; `p_backtest => FALSE` skips the
  CPU twins (and the tablespace twins unless AUTO needs them).
  `CAPR_BACKTEST.esm_cutoff_day` shows the twin's own cutoff.
- **Model-type selection (M10.4)**: with `esm_tbspc_model = 2` (AUTO) and
  `esm_select_by_backtest = 1` — both defaults — `train_tablespaces` first
  builds **two** backtest twins per tablespace series, one per candidate
  (`EXSM_HOLT` and `EXSM_ADDWINTERS(7)`), then trains the production model with
  whichever scored the lower holdout MAPE in the new `CAPF_ESM_CANDIDATE` view
  (one row per *(series, model_type)*). MAPEs closer than `esm_auto_tie_pct`
  points (default 0.25) tie, and "no evidence" (a candidate that failed to
  train) also goes to `EXSM_HOLT`, the historical default and the cheaper
  model. Without the margin a 0.06 vs 0.07 MAPE picked ADDW and could flip on
  the next run. The decision and its evidence are written back onto the
  production row: `CAP_ML_MODEL.model_type` / `chosen_by` (`AUTO_BACKTEST` |
  `AUTO_TIE` | `CONFIG` | `DEFAULT`) / `mape_holt` / `mape_addw`, which is what
  lets report section 6c print *"ADDW H=2.90 W=1.20"* or *"HOLT tie H=0.07
  W=0.06"* instead of an unexplained pick.
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

### Retraining (M8.3 — opt-in, never part of `install.sql`)

`@install_jobs.sql` at the repo root creates two `DBMS_SCHEDULER` jobs, both
**DISABLED**, idempotently: `CAP_ML_RETRAIN` (daily 02:00 by default,
`cap_forecast_ml.train_all`; `DEFINE retrain_interval` overrides the calendar
string) and `CAP_REPORT_SPOOL_JOB` (daily 03:00), which
calls the `cap_report_spool(p_dir)` procedure the same script creates. That
procedure writes a pollable `<dir>/cap_alerts.txt` snapshot of `CAPR_ALERTS`
through `UTL_FILE` — *not* the formatted report, because SQL\*Plus spooling
cannot happen inside a scheduler job; keep driving `report/report.sql` from
cron for that. The directory object is not created for you: the script checks
`ALL_DIRECTORIES` and prints the exact `CREATE DIRECTORY` / `GRANT READ, WRITE`
DDL if it is missing (`DEFINE report_dir` overrides the default `CAP_REPORTS`).
The `_JOB` suffix on the second job is not decoration: jobs share the schema
namespace with procedures, so `CAP_REPORT_SPOOL` for both would be ORA-27477.
`@uninstall_jobs.sql` drops both jobs and the procedure. The retrain used to
be weekly. It is daily now because of the age gate: a weekly model sits up to
7 days behind the data, right at `esm_max_age_days`, and its ESM value is
dated up to a week before the REGR value it is compared with.

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
  `CPU_SHIFT`, `SERIES_LIMIT`, `SERIES_NEARLIMIT`), keys, `value` vs
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
| `CAPR_SERIES` | 7 | the M11 fixed-ceiling series: `cur_val` / `cur_limit` / `sat_value` in the series' own `unit`, `pct_of_limit`, `days_to_limit` with its `limit_worst` / `limit_best` range, `quality`, a `sev` marker and `rank_series` (soonest to hit its limit first) |

All of them resolve `db_pdb` through `CAPR_CONTAINER` themselves. The last
three read `CAPF_COMPARE` / `CAPF_BACKTEST`, which `ddl/50_ml.sql` creates
*after* `ddl/45_report_views.sql`, so they live in `ddl/55_report_views_ml.sql`
(loaded last by `install.sql`). What is still computed inside
`report_html.sql` is only chart *geometry*: raw `CAPD_*` history points, the
anomaly-dot / timeline placements, and the whole-database `cur_hero`
regression that has no section of its own.

## Report

`report/report.sql` spools a read-only text report (8 sections: an
at-a-glance alert roll-up from `CAPR_ALERTS`, then the seven detail sections —
days-to-full, tablespace forecast, tablespace anomalies, CPU trend, CPU
anomalies + level shifts, ESM/backtest compare, and the M11 fixed-ceiling
series) to
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

**M7.5 — drill-down.** `report/drill_tbspc.sql <tablespace> [con_dbid]` and its
CPU twin `report/drill_cpu.sql [metric] [con_dbid]` answer the question a
summary report cannot: *why does this row say that?* Each prints and spools one
series end to end — the fit header (slope / intercept / R² / slope CI /
days-to-full or -saturation with the WORST/BEST range), the daily series over
`train_days` with `fit`, `residual`, delta, gap and that day's `CAPA_*`
baseline, a residual footer that re-derives `SUM(resid) = 0`, `resid_se` and
`slope_ci` from scratch next to the values the view publishes, and one
spelled-out arithmetic line per flagged day. That is the auditability goal made
operational: the M9.1 bands can be checked with a calculator. Both arguments are
optional and, like the report drivers, never prompt.

**M8.4 — `doctor.sql`.** A read-only PASS/WARN/FAIL preflight, in one
exception-wrapped anonymous block so a missing privilege prints one WARN line
instead of aborting: pack access, direct `DBA_HIST_*` reads, `SESSION_PRIVS`,
AWR retention and interval per dbid, days of history per source versus
`min_train_days`, invalid `CAP*` objects and the detected seam mode — closing
with a plain-English explanation of why forecasts would read
`INSUFFICIENT_HISTORY`. It queries `ALL_*` filtered on
`SYS_CONTEXT('USERENV','CURRENT_SCHEMA')` rather than `USER_OBJECTS`, because
the latter follows the *session* user and would report nothing useful when
testing as SYSDBA with `CURRENT_SCHEMA` set elsewhere.

## Testing philosophy

The fixture seam is the correctness gate: since we can't `INSERT` into
`DBA_HIST_*`, `CAPV_*` are pointed at `CAP_FIXTURE_*` tables filled with exact,
anchored, deterministic series. Every asserted number is a closed form recorded
in `CAP_FIXTURE_META` (so `run_test.sql` reads expectations rather than
re-deriving dates). `run_test.sql` prints PASS/FAIL over **226** assertions and
exits non-zero on any failure (CI-able); `run_test_ml.sql` adds **14** more
behind the `CREATE MINING MODEL` privilege. The harness needs
`CREATE TABLE/VIEW/TYPE/PROCEDURE` (+ `CREATE MINING MODEL` for Tier 2) and no
`V$` access at all — report identity comes from `SYS_CONTEXT`.

Two properties of the fixture are load-bearing enough to state as contracts:

- **The M9.1 multiplier is computed twice, identically.** The installer works
  out its expected bands with the same `t ≈ 1.96 + 2.4/df` approximation
  `ddl/30_forecast_views.sql` uses. That is deliberate — it makes the
  approximation part of the contract rather than an implementation detail — and
  it means the view and the installer must change together, or the
  `FIX_ZIGZAG` assertions break.
- **Every failure mode gets its own series, and negative results are asserted
  too.** `FIX_EXCLUDED` is 99% full and must appear *nowhere*; the day after
  the CPU gap is 10 points off its baseline against a 9-point threshold and
  must stay *unflagged*; `PROCESSES` sits at 50% of its limit and must raise
  *no* alert of either kind. A test suite that only asserts what should appear
  cannot catch a layer that has stopped filtering.

**What fixtures cannot prove** is that the toolkit reads a *live* database
sensibly — an idle test instance has no growth, no seasonality and nothing to
detect. `bench/` (optional, never installed by `install.sql`) is a swingbench
harness that drives a shaped daily load — OLTP growth in `SOETBS`, DSS CPU with
flat storage, a weekday/weekend contrast for the `dow_weeks` baseline, and an
injectable anomaly burst — so the same views can be exercised against genuine
AWR history. See `bench/README.md`.

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
