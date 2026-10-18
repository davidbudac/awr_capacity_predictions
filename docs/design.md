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
- **Read-only.** Nothing the report touches is ever modified. The suite
  writes only to `CAP_*` tables it owns, never to AWR: the config and
  override tables (operator), the model registry (`cap_forecast_ml`) and the
  results tables (`CAP_RESULTS`, Layer 7).
- **Idempotent, non-destructive re-install.** The persisted tables are
  created only if absent (the config seed MERGE adds missing keys), and
  `00_drop` deliberately does *not* drop them: operator tables
  (`CAP_CONFIG`, `CAP_TBSPC_OVERRIDE`) and derived ones (`CAP_ML_MODEL`, and
  the results layer's `CAP_RUN`, `CAP_FIT_HIST`, `CAP_ALERT_STATE`,
  `CAP_ALERT_EVENT`) all survive `@install.sql`. Operator tables are state
  nobody can recompute; derived tables are a cache the live views never
  need. Full teardown is `@uninstall.sql`.
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

Twelve views re-present the AWR dictionary in a stable shape. Everything
downstream depends only on these, so swapping `ddl/10_seam_local.sql` for `11`
(warehouse) or `12` (fixture) re-points the whole stack. Every view carries
`(dbid, con_dbid)`. A thirteenth view, `CAPV_CONTRACT`, describes what the
other twelve present (see the last bullet).

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
- `CAPV_PARAMETER` / `CAPV_ASM_DISKGROUP`. `CAPV_PARAMETER` reads
  `DBA_HIST_PARAMETER` for nine names (`cpu_count`, `processes`, `sessions`,
  `db_recovery_file_dest_size`, `sga_target`, `sga_max_size`,
  `pga_aggregate_target`, `pga_aggregate_limit`, `memory_target`), one row
  per snapshot, instance and name, `value_num` converted from the `VARCHAR2`
  `VALUE` with the `REGEXP_LIKE` guard (sizes are in bytes). Parameters are
  instance level, so `con_dbid := dbid`. In `CDB$ROOT` the source also holds
  rows under a PDB's `con_dbid` for parameters set at PDB level (verified on
  19.27: `sga_target` for the root, the seed and PDB1 in one snapshot); only
  the root row is kept. `CAPV_ASM_DISKGROUP` joins
  `DBA_HIST_ASM_DISKGROUP_STAT` (`TOTAL_MB`, `FREE_MB` per snapshot) to
  `DBA_HIST_ASM_DISKGROUP` (the `NAME`, no leading `+`) on
  `(dbid, group_number, con_dbid)`. The 19c view has no `USABLE_FILE_MB`
  (verified), so `usable_file_mb` is NULL; sizes are raw MB, before
  mirroring. A database without ASM has no rows. Neither source is collected
  by the warehouse yet: `ddl/11` emits both as `WHERE 1 = 0` contract stubs
  (sibling-repo TODO in its header). The fixture seam reads
  `CAP_FIXTURE_PARAMETER` / `CAP_FIXTURE_ASM_DISKGROUP` and falls back to the
  same stubs when a table is missing, because `test/demo_fixture.sql` does
  not build them.
- `CAPV_SEG_STAT` (M21) reads `DBA_HIST_SEG_STAT` joined to
  `DBA_HIST_SEG_STAT_OBJ` on `(dbid, con_dbid, ts#, obj#, dataobj#)`: one
  row per snapshot, instance and segment with `tablespace_id` (`TS#`),
  `tablespace_name`, `owner`, `object_name`, `subobject_name`, `object_type`
  and the byte deltas `space_used_delta` / `space_allocated_delta`. Verified
  on 19.27 in `CDB$ROOT`: both views carry `CON_DBID`, with rows for the
  root and every PDB, and a dropped object keeps its row named
  `** MISSING **`. AWR keeps only the top segments of each snapshot, so the
  deltas cover the busiest segments, not all of them. The warehouse seam is a
  `WHERE 1 = 0` stub until the collector gathers both views; the fixture
  reads `CAP_FIXTURE_SEG_STAT`, with the same fallback stub.
- `CAPV_CONTRACT` is a diagnostic over the seam itself, the same body in all
  three seam files: one row per fact source (`SNAPSHOT`, `TBSPC_USAGE`,
  `OSSTAT`, `TIME_MODEL`, `SYSSTAT`, `RESOURCE_LIMIT`, `PARAMETER`,
  `ASM_DISKGROUP`, `SEG_STAT`) with `n_rows`, `n_con_dbid`, `min_snap_id` /
  `max_snap_id`, `max_end_time` and `per_container_expected` (`Y` for
  tablespace usage, time model, sysstat and segment stats, `N` for the host,
  instance and spine sources). `doctor.sql` section 10 prints every row and
  warns when a `Y` source shows a single `con_dbid` on a CDB. `n_con_dbid = 1` against a
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
  left-joins `CAP_TBSPC_OVERRIDE` (an operator table, persisted like `CAP_CONFIG`): a matching row's
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
  — honours it with no further code. The same row can also carry the
  tablespace's own alert thresholds (`dtf_warn`, `dtf_crit`,
  `nearfull_warn_pct`, `nearfull_crit_pct`, NULL = the knob): they ride along
  as `ovr_*` columns through `CAPF_TBSPC_FORECAST` and `CAPR_SEVERITY` applies
  them (Layer 6). A fixed-size tablespace meant to run at 95% gets
  `nearfull_warn_pct = 98` instead of an exclusion from every layer.
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
- **`CAPD_CPU_INTERVAL` / `CAPD_DBTIME_INTERVAL` (M15)** pivot those rows to
  one row per **valid** interval (both counters present, no restart), per
  instance and, for the time model, per container. The restart and
  first-snapshot guards live here only, so the day grain and the hour grain
  cannot disagree on which intervals count. Each row carries `day_dt =
  TRUNC(end_time)` (an interval belongs to the day it ends on),
  `hour_ts = TRUNC(end_time − 5/1440, 'HH24') + 1/24` (the END-hour bucket;
  the 5 minutes absorb AWR flush jitter, so 09:59:58 and 10:00:03 both land
  in 10:00), `ivl_hours`, `typ_ivl_hours` (the instance's median interval,
  its AWR cadence), `is_long` (longer than `cpu_gap_hours`), `is_gap_hour`
  (below), the per-interval percentages and `in_peak`. The two daily views
  below are GROUP BYs over them, byte-identical to their pre-M15 output.
- **`CAPD_CPU_DAILY`** — `BUSY_TIME`/`IDLE_TIME` deltas from
  `CAPD_CPU_INTERVAL`, restart intervals dropped. Per day:
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
  **cpu_count ceiling.** The denominator is really
  `cpu_ceiling = LEAST(num_cpus, cpu_count)`, with `cpu_count` from
  `CAPV_PARAMETER`, read at the interval's end snapshot in
  `CAPD_DBTIME_INTERVAL` (a NULL on either side leaves the other), which
  also exposes `cpu_count` / `cpu_ceiling` per interval and builds `cap_sec`
  from the ceiling. It is not carried forward like `num_cpus`: AWR records
  the parameters at every snapshot, and carrying a second column through the
  windowed `ncpu` step made the optimizer push the interval join into it
  (minutes per query on the 150-day demo). With a Resource
  Manager plan active, `cpu_count` cages the instance, so an instance at
  `cpu_count` 4 on a 16-CPU host saturates at 4 CPUs and `db_cpu_pct` and its
  p95 / max / peak twins read against 4. Without a plan the cage is not
  enforced and `db_cpu_pct` can pass 100. `cpu_count` defaults to the logical
  CPU count, so on most systems `cpu_ceiling = num_cpus` and nothing moves;
  the identity with `busy_pct · host_share_pct / 100` holds only then. Per
  day the view exposes `cpu_count` and `cpu_ceiling` (MAX per instance,
  summed across instances). Only the root's `cpu_count` is read: a PDB-level
  `CPU_COUNT` is in `DBA_HIST_PARAMETER` under the PDB's `con_dbid` but is not
  used. The fixture keeps `cpu_count = NUM_CPUS = 8`; `run_test.sql` sets it
  to 4 on the probe day and asserts that day's `db_cpu_pct` doubles.
- **`CAPD_CPU_HOURLY` (M15)** has one row per `(dbid, con_dbid, metric,
  hour_ts)`: host `BUSY_PCT` (OSSTAT, so only under the CDB `con_dbid`) and
  per-container `DB_CPU_PCT` (CPU-ceiling denominator, as in
  `CAPD_DBTIME_DAILY`) per END-hour bucket, with `n_intervals`, `ivl_hours`
  and `gap_flag`. `day_dt` is carried from the interval views, not
  `TRUNC(hour_ts)`: a bucket labelled 00:00 that holds an interval ending
  23:58 belongs to the previous day, exactly as the daily views count it.
  With hourly AWR each bucket holds one interval; with sparser snapshots only
  the buckets an interval ends in exist. It is the HOUR_OF_WEEK source.
  An interval is a gap at hour grain (`is_gap_hour`) when it is 0 h or
  shorter (a DST fall-back or clock step) or longer than
  `LEAST(cpu_gap_hours, hour_gap_ratio · typ_ivl_hours)`. Times are the DB
  wall clock; every exporter labels them `Z` and the dashboards run in UTC,
  so a chart shows the clock the DBA reads in AWR.

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
- `CAPA_ANOM` (in every mode) and `CAPA_CPU_SHIFT` (Layer 4) drop gap days
  from their baselines and never flag one.

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
`covered_sec` NULL and `is_complete = 'Y'`. The CPU and series fits read
complete days only (Layer 3), and the anomaly layer neither scores an
incomplete day nor lets it into a baseline (Layer 4).

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
  so. The test uses the data only (no `SYSDATE`). The forecast alert kinds
  require `is_current = 'Y'` (`CAPR_SEVERITY` gates the rest as `NOT
  CURRENT`); a whole database that stopped sending AWR is `DATA_STALE`'s job.
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
- **Sizing ask** (`CAPF_TBSPC_FORECAST`): `need_gib_h = GREATEST(0,
  proj_h_hi − limit_bytes) / 2³⁰` for h ∈ {30, 90, 180}, the space to add so
  the **upper** edge of the 95% band stays under the ceiling through day h,
  and `add_by_day = last_day + days_to_full_lo`, the worst-case fill date.
  `need_gib_h` is 0 when the band stays under, NULL when the band is NULL or
  the row is CYCLIC (its band follows the sawtooth, not the peaks), and at
  least the overage when the ceiling is already under the usage.
  `add_by_day` is NULL when `days_to_full_lo` is. `CAPR_TBSPC_DAYS_TO_FULL`
  and `CAPR_FIT` pass the four columns; section 1a prints `NEED_90_GIB` and
  `ADD_BY`, and the HTML report says "add X GiB by <date>". Fixture:
  `FIX_FILLING` (zero residuals) needs `(cur + h · 10 MiB − limit) / 2³⁰` and
  is added by `last_day + days_to_full_lo` (20, or 19 when a rounding
  epsilon floors it), `FIX_LINEAR` needs 0 at every horizon, `FIX_OVERFULL`
  needs its 0.5 GiB overage at every horizon with no date.
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
  that the purge day still shows up as a `LOW` tablespace row in `CAPA_ANOM`; the reset is
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
  `cycle_n` are NULL on non-`CYCLIC` rows. A `CYCLIC` row pages
  (`TBSPC_FULL`) only when its peak line reaches the limit inside the warn
  window, and the message names the cycle; otherwise `CAPR_SEVERITY` gates it
  as `QUALITY CYCLIC`. The count does not depend on `reset_on_shrink`. Fixture: `FIX_CYCLIC` (flat peaks, no
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

More series share one property with tablespaces: a value approaching a
**hard ceiling that is not a tablespace's own**. Rather than a view per series
they land in one generic pair keyed by a `series` name, so the report, the
alert view, the point feeds and any future series need no extra code.

`CAPD_SERIES_DAILY (dbid, con_dbid, series, day_dt, value, limit_value, unit,
n_samples, covered_sec, is_complete, day_gap, max_interval_hours, gap_flag)` — `ddl/25_series_daily.sql`, a UNION ALL of:

| series | value | limit_value | unit |
| --- | --- | --- | --- |
| `PROCESSES` / `SESSIONS` | daily `MAX(max_utilization)` per instance, **summed** across instances | the `processes` / `sessions` parameter, summed across instances | `COUNT` |
| `REDO_GB_DAY` | `SUM('redo size' deltas)/2³⁰` for the day | NULL — no ceiling | `GIB_PER_DAY` |
| `DB_SIZE_GB` | `SUM(used_bytes)/2³⁰` over `CAPD_TBSPC_DAILY` | `SUM(limit_bytes)/2³⁰` | `GIB` |
| `ASM_DG:+<group>` | `(total_mb − free_mb)/1024` at the day's **last** sample (`CAPV_ASM_DISKGROUP`) | `total_mb/1024` | `GIB` |
| `TEMP_PEAK:<ts>` / `UNDO_PEAK:<ts>` | the day's **MAX** of used blocks · block size / 2³⁰ for a `TEMPORARY` / `UNDO` tablespace | the day's MAX of (maxsize when autoextend, else size) · block size / 2³⁰ | `GIB` |

- `MAX_UTILIZATION` is a **high-water mark since instance startup**, so within
  one startup epoch it is monotone and the daily MAX is the end-of-day HWM —
  exactly the number a DBA compares against `processes`. A restart resets it,
  which reads as a level shift (degrading R², not lying).
- RAC: limits are per instance, so both the utilization and the ceiling are
  summed. If **any** instance's limit is non-numeric (`UNLIMITED`) the day's
  `limit_value` is NULL rather than an understated sum. The sum hides one
  exhausted node (two nodes at 990/1000 and 10/1000 read 50%), so
  `PROCESSES` / `SESSIONS` days also carry `worst_inst_pct` (the highest
  per-instance `100 · max_utilization / limit`) and `worst_inst` (that
  instance_number; NULL on every other series). There is still one fleet row
  per series, no `instance_number` downstream. `CAPF_SERIES_FORECAST` carries
  the last day's pair (`worst_inst_pct` at 1 decimal) and `SERIES_NEARLIMIT`
  judges the larger of `pct_of_limit` and `worst_inst_pct`; the message names
  the instance when it is the one over the line, and `CAPR_SEVERITY.value`
  is then the instance's percent (`sev_reason` starts `worst_inst_pct`). On a
  single instance the two percents are equal and nothing changes.
- `REDO_GB_DAY` sums the `redo size` rows of `CAPD_COUNTER_DELTA` with
  `is_restart = 'N'`, the same rule as `CAPD_CPU_DAILY`. The delta is
  attributed to the day the interval **ends** on. It is the one flow series
  here, so it carries `covered_sec` / `is_complete` (Layer 2, day coverage);
  the level series carry NULL / `'Y'`. In local mode it is per container (the
  CDB's redo is the sum); in warehouse mode it is one CDB-level series.
- `PROCESSES` / `SESSIONS` are CDB-wide: `DBA_HIST_RESOURCE_LIMIT` is
  root-only in `CDB$ROOT`.
- The M15 gap columns feed the anomaly layer: `day_gap` (days since the
  series' previous row), `max_interval_hours` (`REDO_GB_DAY` only) and
  `gap_flag` (`REDO_GB_DAY` over `cpu_gap_hours`; `DB_SIZE_GB` when
  `n_samples` changed, see Layer 4).
- `DB_SIZE_GB` inherits everything `CAPD_TBSPC_DAILY` already decided: **UNDO
  and TEMPORARY are excluded**, and M9.5 overrides / exclusions are applied. So
  "total DB size" means permanent-tablespace bytes actually used.
- `ASM_DG:+<group>`: autoextend `maxsize` is often fiction (on 19c every
  autoextend smallfile datafile reports 4,194,302 blocks, the 32 GiB cap), so
  the diskgroup under the datafiles is the real ceiling. Raw MB before
  mirroring: the percent is right for any redundancy, the GiB are raw. AWR
  stores the name without the `+`; the series name adds it. A dismounted
  group (`total_mb = 0`) is skipped.
- `TEMP_PEAK:<ts>` / `UNDO_PEAK:<ts>`: `CAPD_TBSPC_DAILY` drops these
  contents because their level is not growth, and it still does. But running
  out of them is an outage (ORA-01652, ORA-30036), so this branch reads
  `CAPV_TBSPC_USAGE` + `CAPV_TABLESPACE` directly and keeps the day's peak. A
  peak is the highest **sampled** value: usage between two snapshots is not
  seen. `CAP_TBSPC_OVERRIDE` does not apply to them.
- All three are level series (`covered_sec` NULL, `is_complete` `'Y'`), and
  their names are unique per container, so `CAPF_SERIES_FORECAST`,
  `SERIES_LIMIT` / `SERIES_NEARLIMIT`, `CAPR_SERIES`, section 7 and the
  point feeds handle them with no code of their own. A TEMP peak at 97% of
  its size raises `SERIES_NEARLIMIT` CRIT whatever its (usually FLAT or
  noisy) forecast says. They are not in the anomaly engine's series registry
  (`sreg` in `CAPA_OBS`), so they produce no `SERIES_ANOM` rows: a TEMP or
  UNDO peak jumps by construction, and an ASM fill is a forecast question.

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

**FRA days.** `REDO_GB_DAY` rows also carry `fra_size_gb`
(`db_recovery_file_dest_size / 2³⁰` at the dbid's newest snapshot, from
`CAPV_PARAMETER`, NULL when unset or 0) and `fra_days_at_cur = fra_size_gb /
the dbid's current redo rate`, the days of redo the FRA holds at today's
rate. The log stream is shared, so the rate is the sum of `cur_val` over the
dbid's current `REDO_GB_DAY` rows (one per container in local mode), and
every REDO row of the dbid carries the same number. It is an upper bound:
the FRA also holds flashback logs and backups. NULL on every other series.
Fixture: 100 GiB / 2.0 GiB/day = 50.

Two alert kinds and one report view ride on it: `SERIES_LIMIT` (quality `OK`,
`days_to_limit <= dtf_warn`), `SERIES_NEARLIMIT` (`pct_of_limit`, or on RAC the worst instance's
`worst_inst_pct` when higher, `>= nearfull_warn_pct` now, at **any**
quality — the M7.1 rule again) and
`CAPR_SERIES` (report section 7, which prints `FRA_DAYS` on the REDO row).

## Layer 4 — anomalies (`CAPA_*`)

Robust median + MAD (`MAD_sigma = MEDIAN(|x − median|)·1.4826`), scored by one
engine against several **baseline modes**. Each mode answers a different
question about the same point:

- **TRAILING**: is this unusual compared with how the series has been going
  lately? The right question for tablespace growth, where a bulk load is a
  break from the recent run.
- **SAME_DOW**: is this unusual for this weekday? The right question for CPU,
  where a quiet Sunday is normal and the same load on a Monday is not.
- **HOUR_OF_WEEK**: is this unusual for this weekday at this hour? A day whose
  average is normal but whose profile is inverted (busy at night, idle at
  noon) is invisible to both day modes.

Before M15 there were two views, `CAPA_TBSPC_ANOM` (trailing) and
`CAPA_CPU_ANOM` (same weekday), each with its own copy of the median, MAD,
floor and flag logic. Scoring DB CPU per container and the M11 series would
have meant two more copies, and a second baseline per series would have meant
four. So the layer is now a registry of what is scored (`CAPA_OBS`), one
engine that scores every observation against every mode of its grain
(`CAPA_ANOM`), and a rollup to one row per observation (`CAPA_ANOM_DAY`). A
mode is only a selector of the reference set. Floors, thresholds, z-scores and
flags are the same arithmetic for every mode and every series.

### The registry: `CAPA_OBS`

One row per scorable observation, key `(dbid, con_dbid, kind, series, grain,
ts)`. Each branch states what is scored, in which unit, and with which floor:

| kind / series | grain | scored `value` | `raw_value` | unit | threshold floor | `anomaly_kind` → alert kind |
| --- | --- | --- | --- | --- | --- | --- |
| `TBSPC` / tablespace | DAY | `used_rate_bpd` (delta ÷ `day_gap`) | `used_delta_bytes` | `BYTES_PER_DAY` | `abs_floor_bytes` | `TBSPC_GROWTH` → `TBSPC_ANOM` |
| `CPU` / `BUSY_PCT` | DAY | `CAPD_CPU_DAILY.busy_pct` | same | `PCT` | `mad_k · cpu_min_mad_pct` | `CPU_BUSY` → `CPU_ANOM` |
| `CPU` / `DB_CPU_PCT` | DAY | `CAPD_DBTIME_DAILY.db_cpu_pct`, per container | same | `PCT` | `mad_k · cpu_min_mad_pct` | `DBCPU_BUSY` → `DBCPU_ANOM` |
| `CPU` / `BUSY_PCT`, `DB_CPU_PCT` | HOUR | `CAPD_CPU_HOURLY.value` | same | `PCT` | `mad_k · cpu_min_mad_pct_hour` | `CPU_BUSY` / `DBCPU_BUSY` → `CPU_ANOM` / `DBCPU_ANOM` |
| `SERIES` / `PROCESSES`, `SESSIONS` | DAY | the level | same | `COUNT` | `series_floor_count` | `SERIES_LEVEL` → `SERIES_ANOM` |
| `SERIES` / `REDO_GB_DAY` | DAY | the level (GiB/day) | same | `GIB_PER_DAY` | `series_floor_gib` | `SERIES_LEVEL` → `SERIES_ANOM` |
| `SERIES` / `DB_SIZE_GB` | DAY | growth, GiB moved ÷ `day_gap` | GiB moved | `GIB_PER_DAY` | `series_floor_gib` | `SERIES_GROWTH` → `SERIES_ANOM` |

The M11 rows come from an inline `sreg` registry (series, LEVEL or RATE basis,
unit, anomaly kind), so scoring a fifth M11 series is one row there. The floors
come from one inline `ufloor (unit, grain)` table and are expressed as
**threshold** floors in value units. `CAPA_OBS` also carries `gap_flag`,
`is_complete`, `day_gap`, `ivl_hours`, the family's `alert_modes` bitmask and
`headline_bit` (below). `CAPA_CPU_SHIFT` is not in the registry: it compares
windows, not points. `anomaly_hour_grain = 0` drops the HOUR branch: no
hourly scoring, alerts or ring tooltips, and every reader skips the hour
history. The day verdicts do not change (the test flips it and counts them).

### Modes select the reference set

| mode | grain | bit | reference set for the point at `ts` | min history |
| --- | --- | --- | --- | --- |
| `TRAILING` | DAY | 1 | every day in `[ts − mad_window_days, ts − 1]` | `trailing_min_hist` (7) |
| `SAME_DOW` | DAY | 2 | `ts − 7k`, `k = 1..dow_weeks` | `weekly_min_hist` (3) |
| `HOUR_OF_WEEK` | HOUR | 4 | `ts − 7k`, `k = 1..dow_weeks` (same weekday and clock hour) | `weekly_min_hist` (3) |

The modes join observations on grain, so the grain decides which modes apply:
a day row gets TRAILING and SAME_DOW, a CPU hour row gets HOUR_OF_WEEK, and
`CAPA_ANOM` has exactly `2 × DAY obs + HOUR obs` rows. Two generators build
every reference set. TRAILING is a range self-join on `ts`. The weekly modes
join a `CONNECT BY LEVEL <= dow_weeks` lag list at exact equality,
`h.ts = c.ts − 7·k`, so the hour grain costs `dow_weeks` lookups per point and
needs no weekday arithmetic. `ts` is a DB-local `DATE`, so `ts − 7k` is
NLS-proof and follows the local clock across a DST change, as workload does.
Every baseline **excludes the point itself** (a spike cannot inflate its own
baseline) and every row with `gap_flag = 'Y'` or `is_complete = 'N'`.

The weekly lags reuse `dow_weeks`; there is no separate hour-of-week depth
knob. TRAILING does not exist at hour grain: "the last 28 days of hours" mixes
night and noon, so every busy hour would read as an outlier.

### One flag rule for every mode

Rolling MAD cannot be a nested window `MEDIAN` on 19c, so the engine runs two
passes over the reference set: the median first, then the MAD about it. Then:

```
expected     = MEDIAN(reference set)
mad_sigma    = MEDIAN(|h − expected|) · 1.4826
eff_sigma    = GREATEST(mad_sigma, thr_floor / mad_k)     sigma_floored = which side won
threshold    = mad_k · eff_sigma                          a DEVIATION; the bound is expected ± threshold
robust_z     = (value − expected) / eff_sigma             so |robust_z| > mad_k  <=>  flagged
anomaly_flag = HIGH when value − expected >  threshold
               LOW  when expected − value >  threshold
               NULL when gap_flag = 'Y', is_complete = 'N' or n_hist < min_hist
```

`pct_vs_expected` restates the move as a percentage of the baseline median.
`avg_value` / `avg_days` / `pct_vs_avg` compare against the long-run mean over
`train_days`, `SUM(raw_value) / SUM(span_days)` over non-gap complete day rows,
current day excluded. For tablespaces that is the gap-weighted mean growth
rate, a mean rather than a median because the question is "more than its
long-term average". It is mode-independent and NULL on hour rows.

**The floor rule is the old rule, restated once.** The legacy tablespace view
flagged on `|dev| > GREATEST(k·mad_sigma, abs_floor_bytes)`. With
`thr_floor = abs_floor_bytes`,
`k · GREATEST(mad_sigma, abs_floor_bytes / k) = GREATEST(k · mad_sigma, abs_floor_bytes)`,
so the threshold, and every flag, is identical. The legacy CPU view used
`k · GREATEST(mad_sigma, cpu_min_mad_pct)`. With
`thr_floor = k · cpu_min_mad_pct` the same identity holds. The one visible
change is the tablespace `robust_z`: it used to divide by the raw
`mad_sigma`, which is 0 on a flat baseline. It now divides by `eff_sigma`, so
it is finite and `|z| > k` means flagged everywhere. The parity gate run before
the legacy views were deleted confirmed exactly that (see Testing philosophy).

**Floors are per unit and per grain**, because "a real jump" depends on both.
100 MiB/day is noise for a tablespace and a disaster for redo. An hourly CPU
value is noisier than a daily average, so the hour floor (`cpu_min_mad_pct_hour`,
5 points of sigma, a 15-point threshold) sits above the day floor (3 points,
a 9-point threshold).

### Gaps and incomplete days, at both grains

A gap row is never scored and never enters a baseline, in any mode.

- **CPU days**: `gap_flag` from the daily views (an interval longer than
  `cpu_gap_hours`, M10.5). `is_complete = 'N'` days (the first day, today, a
  restart or outage day) are treated the same way.
- **CPU hours**: `CAPD_CPU_HOURLY.gap_flag` is `'Y'` when any interval in the
  bucket is non-positive (a DST fall-back or clock step) or longer than
  `LEAST(cpu_gap_hours, hour_gap_ratio × the instance's median interval)`.
  With hourly AWR that is anything over 1.5 h. With the fixture's 12 h
  snapshots only intervals over 12 h gap, so the hour rule is never more
  lenient than the day rule.
- **Tablespaces**: no gap flag. The rate (delta ÷ `day_gap`) already
  normalises a multi-day gap.
- **`REDO_GB_DAY`**: a day carrying an interval longer than `cpu_gap_hours`
  holds more than a day of redo, so it is a gap day; partial days are
  `is_complete = 'N'`.
- **`DB_SIZE_GB`**: a day whose `n_samples` (the number of tablespaces summed)
  differs from the previous row's is a gap day. A tablespace that enters,
  leaves, or misses an AWR sample moves the total by its whole size, which
  is a change of membership, not growth. In the fixture that is the day
  `FIX_DROPPED` stops reporting and `FIX_GAP`'s days 100 and 103.
- **`PROCESSES` / `SESSIONS`**: level series, never gapped.

### Where the mode lives

The mode is part of the key wherever a row is a verdict, and absent wherever a
row is an observation:

| object | one row per | mode |
| --- | --- | --- |
| `CAPA_ANOM` | observation × mode | `baseline_mode`, in the key |
| `CAPA_ANOM_DAY` | day observation | rolled up: `anomaly` (any day mode flagged), `anomaly_modes`, the headline mode's numbers |
| `CAPR_ANOMALIES` | flagged observation × mode (+ one per `CAPA_CPU_SHIFT`) | `baseline_mode` (NULL for `CPU_SHIFT`), inside `doc_key` |
| `CAPR_ALERTS` | anomaly kind × series × episode (run of consecutive flagged days) × enabled mode | `baseline_mode`, inside `alert_key` |
| `CAPR_TBSPC_ANOMALIES` / `CAPR_CPU_ANOMALIES` / `CAPR_SERIES_ANOMALIES` | flagged observation × mode | `baseline_mode`, `mode_short`, `mode_rank` |
| `CAPR_SERIES_POINTS` | `CAPD_*` row (1:1) | none; headline numbers, `anomaly_modes`, `how_hours_flagged` |
| `CAPR_HOURLY_POINTS` | `CAPD_CPU_HOURLY` row (1:1) | none; HOUR_OF_WEEK is the only hour mode |

Joining `CAPA_ANOM` on the observation key alone fans out two rows per day, so
the rule is: filter `baseline_mode`, GROUP BY the observation key, or join
`CAPA_ANOM_DAY`. `test/lint_anom_joins.sh` fails any `capa_anom` reference
outside ddl/40, ddl/45, test/, bench/ and the drill scripts, and any drill
reference without a `baseline_mode =` predicate.

**The headline mode** keeps the 1:1 feeds stable. `CAPA_OBS.headline_bit` is
the lowest DAY bit set in the family's alert bitmask (TRAILING if none is set),
so with the shipped bitmasks the headline is TRAILING for tablespaces and M11
series and SAME_DOW for CPU: the numbers that alert, and for tablespaces and
host busy% the same numbers the feeds carried before M15.

### Alerting: one bitmask per family

`alerting_mode = BITAND(alert_modes, mode_bit) > 0`, with `alert_modes_tbspc`,
`alert_modes_cpu` and `alert_modes_series` holding the sum of the enabled bits.
`CAPR_ANOMALIES.alerting` adds the window: the day must lie within
`anomaly_report_days` of the kind's last collected day. Scoring and paging are
separate decisions on purpose. Every mode is always computed and visible in
`CAPR_ANOMALIES` and the report; the bitmask decides only which of them pages.
The shipped values (tablespaces 1, CPU 2, series 1) keep the pre-M15 paging
for tablespaces and host busy%, and page the new kinds (`DBCPU_ANOM`,
`SERIES_ANOM`) on the same footing. HOUR_OF_WEEK pages only when you add bit 4.
When it does, each flagged day of a (series, mode) carries its worst hour
(largest `|z|`, earliest on a tie), with "N hours flagged that day" appended
to the message.

Two alert policies sit on top, both inside `CAPR_ALERTS`' one anomaly branch:

- **Episodes.** Consecutive flagged days of one (kind, series, mode) are one
  row (gaps and islands: `obs_day` minus its row number is constant along a
  run). `day_dt`, `value`, `threshold` and `alert_key` are the last day's;
  `first_day`, `n_days` and `max_z` (the robust z of the most extreme day,
  NULL = off-scale) are appended columns; the severity is the worst day's.
  The message gains a prefix: "7 consecutive days, latest 2026-10-17, peak
  robust z +6.0: ". A burst that flags three days running used to page three
  times, and a step change fourteen times.
- **Shift suppression.** While `CAPA_CPU_SHIFT` reports UP or DOWN for a CPU
  series, that series' flagged days inside the shift's recent window are
  INFO and the message ends " (level shift active)". The step days are the
  shift, seen one day at a time: `CPU_SHIFT` is the one WARN for them. The
  shift windows come from the `CPU_SHIFT` rows of the same `CAPR_ANOMALIES`
  read, so the branch still reads the anomaly engine once.

### `CAPA_CPU_SHIFT` (M10.3)

The per-point modes see a **sustained step** only briefly. A new release adds
+18 points and stays there. SAME_DOW flags the first step days, then the step
becomes its own baseline: once most of the reference set lies after the step,
nothing flags. TRAILING does the same sooner, and a step smaller than the
threshold never flags at all. The trend fit is too noisy (low `R²`) to say
anything either, yet the machine now runs materially hotter than it did a
month ago. So this view compares **windows, not days**, per
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

### Downstream

The percentages flow through unchanged: `CAPR_TBSPC_ANOMALIES` carries
`pct_vs_med` / `pct_vs_avg` (plus `avg_mb`, `avg_days`), `CAPR_CPU_ANOMALIES`
and `CAPR_SERIES_ANOMALIES` carry `pct_vs_med`, the anomaly messages end with
"(+N% vs median)" and, for tablespaces, "+N% vs 90-day avg rate", and
`CAPR_ANOMALIES` carries `pct_vs_expected` / `pct_vs_avg`. Each message names
its baseline: "over the last 28 days", "for that weekday" or "for Tue 06:00".

Self-join cost is O(points · window) for TRAILING at day grain (fine for
≤ ~400 days) and O(points · `dow_weeks`) for the weekly modes. `CAPA_ANOM`
reads `CAPA_OBS` through one CTE that Oracle materializes. Joined directly,
the optimizer pushed the history join into `CAPA_OBS` and recomputed the daily
sources per scored point. No hints are used.

The two medians are where the time goes. Inside a large plan (`CAPR_ALERTS`,
`CAPR_SERIES_POINTS`) every sort gets a small work area, and the median sorts
over ~150 000 history rows (the demo story) went 70-plus passes to temp. The
engine therefore reads the history rows once: `med` takes the median as an
analytic `MEDIAN() OVER (PARTITION BY pid)`, `madc` the MAD about it with one
`GROUP BY pid`, and both sorts carry only `(pid, value)`. `pid` numbers the
scored point, `obs_id × 8 + mode_bit`, with `obs_id` a `ROW_NUMBER()` over the
`CAPA_OBS` key, so it is deterministic. On the demo story this took
`CAPR_ALERTS` from 26 s to 12 s and `CAPR_SERIES_POINTS` from 27 s to 8 s on
the test VM; the results are identical (a `MINUS` both ways over every column
returned no rows). `kind_last_day` (the newest DAY `ts` of the kind) rides
along, so `CAPR_ANOMALIES` and `CAPR_CPU_ANOMALIES` need no second `CAPA_OBS`
read for their windows.

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

`@install_jobs.sql` at the repo root creates three `DBMS_SCHEDULER` jobs, all
**DISABLED**, idempotently: `CAP_REFRESH_JOB` (daily 01:30,
`cap_results.refresh`, `DEFINE refresh_interval`; Layer 7),
`CAP_ML_RETRAIN` (daily 02:00 by default,
`cap_forecast_ml.train_all`; `DEFINE retrain_interval` overrides the calendar
string) and `CAP_REPORT_SPOOL_JOB` (daily 03:00), which
calls the `cap_report_spool(p_dir)` procedure the same script creates. That
procedure writes a pollable `<dir>/cap_alerts.txt` snapshot of `CAPR_ALERTS`
through `UTL_FILE` — *not* the formatted report, because SQL\*Plus spooling
cannot happen inside a scheduler job; keep driving `report/report.sql` from
cron for that. The file's header has one "data through" line per dbid (newest snapshot and
its age, from `CAPR_FRESHNESS`) and `DATA_STALE` rows come first, so a
stalled AWR cannot pass for a quiet system. Once a refresh run exists the
file lists the OPEN, not acked alerts of `CAPR_ALERTS_LATEST` and the last
run's events, with a header line naming the run, its age and a STALE REFRESH
mark when the job stopped (Layer 7). The directory object is not
created for you: the script checks
`ALL_DIRECTORIES` and prints the exact `CREATE DIRECTORY` / `GRANT READ, WRITE`
DDL if it is missing (`DEFINE report_dir` overrides the default `CAP_REPORTS`).
The `_JOB` suffix on the second job is not decoration: jobs share the schema
namespace with procedures, so `CAP_REPORT_SPOOL` for both would be ORA-27477.
`@uninstall_jobs.sql` drops the jobs and the procedure. The retrain used to
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
- `CAPR_SEVERITY` is the **single home of the forecast-type severities**:
  one row per (kind, dbid, con_dbid, series_key) for `TBSPC_FULL`,
  `TBSPC_NEARFULL`, `CPU_SAT`, `DBCPU_SAT`, `CPU_HOT`, `DBCPU_HOT`,
  `SERIES_LIMIT` and `SERIES_NEARLIMIT`, alerting or not. It carries the
  judged `value` and `unit`, `direction`, the effective `warn_threshold` /
  `crit_threshold` (a tablespace's `CAP_TBSPC_OVERRIDE` columns where set,
  `thr_source = OVERRIDE`, else the knobs), `raw_sev` (thresholds alone),
  `sev` / `sev_rank`, `gated_by` (with a short `gate`), a `sev_reason` such as
  `days_to_full 17 <= dtf_crit 30` and the alert `message`. The gates, first
  match wins: `NOT CURRENT` (`is_current = 'N'`, on every row of a stale
  series), `QUALITY CYCLIC` (a CYCLIC tablespace whose peak line stays outside
  the warn window), `LIMIT BELOW USED` (a would-be `TBSPC_FULL` whose ceiling
  is already under the usage; `TBSPC_NEARFULL` pages it) and `QUALITY
  <grade>` (a would-be countdown alert on a fit that is not OK). The level
  kinds gate on currency only: `TBSPC_NEARFULL` deliberately ignores fit
  quality (M7.1: a 97%-full tablespace with an unfittable series must still
  surface; that's a fact about *today*, not a forecast), and so do
  `SERIES_NEARLIMIT` and the HOT kinds. `CAPR_TBSPC_DAYS_TO_FULL`,
  `CAPR_CPU_TREND`, `CAPR_SERIES`, `CAPR_FIT` and `CAPR_ALERTS` all take their
  severity from it, so section 1a/1b, section 4, section 7, the HTML report,
  the point feeds and the pollers show the same CRIT / WARN / OK (upper case
  everywhere). Each `CAPF_` view is read once: a small kind list is joined to
  its rows rather than one `UNION` branch per kind.
- `CAPR_FRESHNESS` is one row per dbid with the end time of its newest
  `CAPV_SNAPSHOT` row, its age in hours against `SYSDATE` and `is_stale`
  (`age_hours >= stale_hours`, knob 36). This is the **one deliberate
  `SYSDATE`** in the analytics: every other staleness test compares the data
  with itself, so when AWR stops arriving every series stays "current" and
  every forecast freezes without a word. The fixtures are anchored to
  `TRUNC(SYSDATE)` (newest snapshot today 18:00), so they never trip it.
- `CAPR_ALERTS` (in `ddl/55`, because `MODEL_HEALTH` reads the Tier 2 health
  view) is the pollable alert surface: one row per current issue with
  `severity` (CRIT/WARN/INFO + numeric `sev_rank`), `kind`, keys, `value` vs
  `threshold` (+ `unit`), a ready-to-page `message`, `baseline_mode` (anomaly
  kinds only), `alert_key` and, appended, `state_key`, `direction`,
  `alarm_threshold` and `is_current`. The kinds: the eight forecast kinds
  above (every non-OK `CAPR_SEVERITY` row), `CPU_SHIFT` (UP = WARN, DOWN =
  INFO), `DATA_STALE` (one WARN per dbid from `CAPR_FRESHNESS`, except a
  dbid `data_stale_max_days` (14) or more old: that one is retired, an
  imported or decommissioned DBID, and shows in `CAPR_COVERAGE` instead of
  paging forever),
  `MODEL_HEALTH` (per container from `CAPF_ESM_HEALTH_SUMMARY`: WARN when a
  forecast model failed its last build, INFO when none failed but some are
  stale; no registry rows, no row, so a Tier 1 install stays silent; the
  message carries the counts and the newest `last_error`), and the four
  anomaly kinds `TBSPC_ANOM`, `CPU_ANOM`, `DBCPU_ANOM`, `SERIES_ANOM` (the
  alerting `CAPR_ANOMALIES` rows, one row per episode with `first_day`,
  `n_days` and `max_z`, see Layer 4; they use the `anomaly_report_days` knob
  as their window, the reports' `anomaly_days` DEFINE is presentation-only).
  `CPU_HOT` / `DBCPU_HOT` page a saturated CPU even without a trend: the
  busy-hour p95 (`BUSY_P95` on the host, `DB_CPU_P95` per container) has a
  recent median (`recent_p95_med`, the last `shift_days` complete days) at or
  above `cpu_sat_pct`, at any fit quality. Two keys: `alert_key`
  (`dbid|con_dbid|kind|series_key|YYYY-MM-DD|mode`, `-` for no mode) is
  unique per row and changes with `day_dt`; `state_key`
  (`kind|dbid|con_dbid|series_key|mode`) is stable from day to day, the key to
  follow one issue across polls. `threshold` keeps its old meaning (on a
  forecast kind the CRIT threshold on a CRIT row and the WARN one otherwise,
  on an anomaly the bound crossed); `alarm_threshold` is the WARN level, the
  same on every severity; `direction` says how `value` relates to it on an
  alert: `LE` (the countdowns), `GE` (levels, HIGH anomalies, `DATA_STALE`,
  `MODEL_HEALTH`), `ABS` (`CPU_SHIFT`, `|value| > alarm_threshold`), and `LE`
  on a LOW anomaly. `is_current` is `'Y'` on every row today. So a poller can
  key, de-duplicate and alarm without parsing `message`. Both reports'
  at-a-glance blocks read this view (DATA_STALE first), and the section
  severities come from the same `CAPR_SEVERITY` rows, so paging and reporting
  cannot disagree.
- `CAPR_ANOMALIES` is every flagged anomaly event: one row per (observation,
  baseline mode) from `CAPA_ANOM`, plus one per flagged `CAPA_CPU_SHIFT`.
  It is the **single home of anomaly severity, message and alert
  eligibility** (`alerting`, Layer 4), and `CAPR_ALERTS` reads its four
  anomaly kinds from it in one branch, never the reverse. So the report, the
  pollers and the dashboards cannot disagree on what an anomaly says or
  whether it pages. `anomaly_kind` is one of `TBSPC_GROWTH`, `CPU_BUSY`,
  `DBCPU_BUSY`, `SERIES_LEVEL`, `SERIES_GROWTH`, `CPU_SHIFT`; `value` is the
  scored value (a tablespace's growth rate, `raw_value` its raw delta) and
  `threshold` the allowed deviation. `doc_key` is the unique id input the
  exporters hash. It doubles as a point feed (below).

**M8.2 — one view per report section.** Every section's SELECT now lives in a
`CAPR_*` view, so `report/report.sql` (via `report/sections/*.sql`) and
`report/report_html.sql` only *format*: no analytic SQL is duplicated between
the two drivers, and they cannot drift.

| view | section | notes |
| --- | --- | --- |
| `CAPR_TBSPC_DAYS_TO_FULL` | 1a + 1b | `pct_used`, GiB/MiB numeric columns, `sev_dtf` / `sev_nearfull` (the `CAPR_SEVERITY` TBSPC_FULL / TBSPC_NEARFULL `sev`, with `gated_by` / `gate` / `nearfull_gated_by` and the effective `eff_*` thresholds), the M9.1 `dtf_worst`/`dtf_best` range, plus `rank_dtf` / `rank_nearfull` (`ROW_NUMBER`) so a driver applies `top_n` with `WHERE rank_* <= n` instead of its own `ORDER BY … FETCH FIRST`. `rank_dtf` puts a CYCLIC row without a `days_to_full` after the rows that have one, so section 1a lists it under `top_n` like the rest and prints `gate` beside the severity |
| `CAPR_TBSPC_FORECAST` | 2 | GiB projections + the +180 band, `train_n`, `r2`, `quality`, the Tier 2 `esm30`/`esm30_lo`/`esm30_hi` point, raw byte columns and `rank_chart` for the HTML chart grid, plus the M7.4 bound `is_reportable` / `rank_report` |
| `CAPR_TBSPC_ANOMALIES` | 3 | one row per flagged (day, baseline mode), MiB conversions (`delta_mb`, `rate_mb`, `med_mb`, `thr_mb`), `n_hist`, `baseline_mode` / `mode_short` / `mode_rank`, `day_str`, and `days_ago` = `MAX(day_dt)` over `CAPD_TBSPC_DAILY` minus the row's day, so the report window is `WHERE days_ago < anomaly_days` |
| `CAPR_CPU_TREND` | 4 | per (container, metric) trend with `sat_worst`/`sat_best`, `hot_now`, and `sev` / `gated_by` / `gate` (the worst `CAPR_SEVERITY` sev of the metric's kinds, OK on a metric no kind judges) |
| `CAPR_CPU_ANOMALIES` | 5a | every flagged CPU point, key `(dbid, con_dbid, metric, baseline_mode, ts)`: host `BUSY_PCT` and per-container `DB_CPU_PCT`, day rows (TRAILING, SAME_DOW) and hour rows (HOUR_OF_WEEK); `value_pct`, `median_pct`, `threshold_pct`, `z`, `n_hist`, `mode_short` / `mode_rank`, and `ts_str` (`YYYY-MM-DD`, or `YYYY-MM-DD Dy HH24:MI` for an hour, weekday NLS-proof) |
| `CAPR_CPU_SHIFTS` | 5b | the M10.3 level shifts: flagged rows only, both medians, both window lengths and the N-of-M counts, ranked by `|shift_pct|` via `rank_shift` |
| `CAPR_ESM_COMPARE` | 6a/6b | REGR vs ESM pivoted per (container, series, horizon), in raw units *and* GiB; filter on `series_kind`. Reads `is_reportable` / `rank_report` from `CAPR_TBSPC_RANK`, as `CAPR_TBSPC_FORECAST` does (CPU rows: always `'Y'`, rank 0), so 6a shows exactly section 2's tablespaces |
| `CAPR_TBSPC_RANK` | 2, 6a | the M7.4 bound and the ranks (`is_reportable`, `rank_report`, `rank_chart`) over `CAPF_TBSPC_FORECAST`, decided once for both views above |
| `CAPR_BACKTEST` | 6c | the M9.4 holdout scorecard pivoted per series, incl. the `better` verdict |
| `CAPR_SERIES_ANOMALIES` | 7b | every flagged (day, baseline mode) of an M11 series: `value` (level, or GiB/day growth for `DB_SIZE_GB`), `raw_value`, `expected`, `threshold`, `z`, `n_hist`, `unit`, mode columns and `days_ago` from the last `CAPD_SERIES_DAILY` day |
| `CAPR_SERIES` | 7 | the M11 fixed-ceiling series: `cur_val` / `cur_limit` / `sat_value` in the series' own `unit`, `pct_of_limit`, `days_to_limit` with its `limit_worst` / `limit_best` range, `quality`, `sev` (the worse `CAPR_SEVERITY` sev of SERIES_LIMIT and SERIES_NEARLIMIT) with `gated_by`, and `rank_series` (soonest to hit its limit first) |

All of them resolve `db_pdb` through `CAPR_CONTAINER` themselves. The last
three read `CAPF_COMPARE` / `CAPF_BACKTEST`, which `ddl/50_ml.sql` creates
*after* `ddl/45_report_views.sql`, so they live in `ddl/55_report_views_ml.sql`
(loaded last by `install.sql`). What is still computed inside
`report_html.sql` is only chart *geometry*: the pixel positions of the
`CAPD_*` history points, the anomaly dots and the timeline. The
whole-database hero used to run its own regression (always OLS, no reset, its
own gap fill, days to 100%), so the shipped demo said "5 mo" in the hero and
"7 mo" in section 7. Since M21.2 it reads `CAPR_SERIES` `DB_SIZE_GB`, the row
section 7 prints, with its history from `CAPR_SERIES_POINTS` and its
projection and band from `CAPR_FORECAST_POINTS`; every chart draws the
projections and band knots the views anchor, with no re-anchoring in the
driver. The ESM marker sits at `last_day + esm_horizon_days -
esm_age_days`, the offset `CAPR_FORECAST_POINTS` gives it.

`CAPR_SEGMENT_GROWTH` (M21, ddl/45) answers "which segment is filling this
tablespace": one row per (dbid, con_dbid, tablespace, owner, object,
subobject) with `grown_bytes` = `SUM(space_allocated_delta)` and
`used_grown_bytes` = `SUM(space_used_delta)` over the last `seg_window_days`
(knob, default 28) days up to the dbid's newest snapshot day, `share_pct` =
the segment's part of the growth of the tablespace's growing segments, and
`rank_in_tbspc`. `report/drill_tbspc.sql` prints its top 10 as block 4.

**Point feeds.** Three more `CAPR_*` views serve the external dashboards
(`grafana/API.md` over ORDS, `elk/export_capacity.sql`, the APEX app), one
chartable shape per record type. They only ever gain columns.

| view | one row per | notes |
| --- | --- | --- |
| `CAPR_SERIES_POINTS` | `CAPD_*` daily row (exactly 1:1) | every kind in one shape; the anomaly verdict joins `CAPA_ANOM_DAY`, so it cannot fan out. `anomaly` is 1 when any day mode flagged or any HOUR_OF_WEEK hour of that day did, 0 on an unflagged scored point, NULL on a series nobody scores (`BUSY_P95`, `BUSY_PEAK`, `DB_CPU_P95`, `DB_CPU_SEC`, and the SERIES names outside `CAPA_OBS`: `ASM_DG`, `TEMP_PEAK`, `UNDO_PEAK`); `anomaly_flag` / `z` / `expected` / `threshold` are the headline mode's; `anomaly_modes`, `how_hours_flagged`, `doc_key` (`obs|...|YYYY-MM-DD`). CPU percent rows carry `limit_value` = `cpu_sat_pct` and `pct` = 100 × value / `cpu_sat_pct` |
| `CAPR_HOURLY_POINTS` | `CAPD_CPU_HOURLY` row (exactly 1:1) | host `BUSY_PCT` and per-container `DB_CPU_PCT` per END hour, with `dow` (0 = Monday), `hour_of_day`, `gap`, `n_intervals` and that hour's HOUR_OF_WEEK verdict (`how_expected`, `how_threshold`, `how_z`, `how_flag`, `how_n_hist`); `doc_key` (`obsh|...|YYYY-MM-DDTHH`) |
| `CAPR_ANOMALIES` | flagged (observation, mode), plus each flagged level shift | see above; `grain`, `n_hist`, `alerting`, `alert_kind`, `raw_value`, `doc_key` |

`CAPR_FIT` (ddl/45) and `CAPR_FORECAST_POINTS` (ddl/55) complete the set.
One CPU limit convention runs through all three CPU-carrying feeds
(`CAPR_SERIES_POINTS`, `CAPR_FORECAST_POINTS`, `CAPR_FIT`): `limit_value` is
the saturation line `cpu_sat_pct`, not 100, and `pct` is the value as a
percent of it. `CAPR_FORECAST_POINTS`' CPU horizon 0 is `anchor_value`, where
the projection starts. `CAPR_FIT.sev` is the worst `CAPR_SEVERITY` sev of the
series.

## Layer 7: results (`CAP_RUN`, `CAP_ALERT_STATE`, `CAP_RESULTS`)

The live views answer "what is true now" and stay the one tested definition
of every number. What they cannot answer is anything about time: is this
alert new, did it clear, is this tablespace worse than last week, were last
month's forecasts right, did the refresh stop. And every consumer pays the
whole view chain on every poll (`CAPR_ALERTS` costs seconds; `CAPR_ALERTS_LATEST`
costs a table scan). `ddl/60_results.sql` adds a small writer that snapshots
the live views, and read-only views over what it wrote.

The rule, restated: the suite writes only to `CAP_*` tables it owns, never to
AWR. Operator tables survive re-install, derived tables are a cache. Only the
`CAP_RESULTS` package writes the four tables below, and every view over them
answers on empty tables, so an install that never ran `refresh` still
installs and reports.

| table | one row per | key |
| --- | --- | --- |
| `CAP_RUN` | `refresh` call | `run_id` = `YYYYMMDDHH24MISSFF3` of the start (bumped past the max on a clash) |
| `CAP_FIT_HIST` | run × `CAPR_FIT` row | `(run_id, kind, dbid, con_dbid, series)`, plus `as_of_day` and every `CAPR_FIT` column |
| `CAP_ALERT_STATE` | `CAPR_ALERTS.state_key` ever seen | `state_key` |
| `CAP_ALERT_EVENT` | state change | `event_id` = `run_id * 100000 + n` (no sequence, so no extra privilege) |

The tables are created with their key columns and then gain every other
column one `ALTER TABLE ... ADD` at a time (ORA-01430 ignored), so a later
column reaches an older install on the next `@install.sql`.

**`CAP_RESULTS.refresh(p_as_of)`** inserts the `CAP_RUN` row as `RUNNING` and
commits it at once (a hung run stays visible), copies `CAPR_FIT` into
`CAP_FIT_HIST`, merges `CAPR_ALERTS` into the state table, marks the run `OK`
with its counts and commits. On any error it rolls the run's work back,
marks it `FAILED` with the error stack in `error_text` and re-raises, so the
scheduler log says FAILED too. `CAPR_ALERTS` is read once: one row per
`state_key` (worst severity, then latest day; an anomaly key can carry
several episodes). A `p_as_of` before today records a backdated run: the
fits as the views show them now, labelled with that day, and no alert state,
because the state machine runs in real time. A `LOCK TABLE` on the state
table serialises two refreshes.

The state machine, per `state_key`, on each live run:

| before | this run | after | event |
| --- | --- | --- | --- |
| no row | present | OPEN, `first_seen` = `last_seen` = now | NEW |
| OPEN | present, same severity | OPEN, `last_seen` = now, `missed_runs` = 0 | none |
| OPEN | present, higher severity | OPEN, `max_severity` updated, ack cleared | ESCALATED |
| OPEN | present, lower severity | OPEN | DEESCALATED |
| OPEN | missing, `missed_runs` + 1 < `resolve_grace_runs` | OPEN, `missed_runs` + 1 | none |
| OPEN | missing for the `resolve_grace_runs`-th run | RESOLVED, `resolved_at` = now | RESOLVED |
| RESOLVED | present | OPEN, `reopen_count` + 1, ack cleared, `first_seen` kept | REOPENED |

The grace (`resolve_grace_runs`, 2) is the hysteresis: a `TBSPC_FULL` whose
`days_to_full` wobbles across `dtf_warn` for one run does not resolve and
reopen. Severity changes still show as events, which is what a pager wants.

**Ack.** `CAP_RESULTS.ack(p_key, p_until, p_note, p_by)` takes a `state_key`
or the `alert_key` the state last carried, and hides the state from
`CAPR_ALERTS_LATEST` until `p_until` (NULL = until it resolves; the live
`CAPR_ALERTS` never hides anything). An ESCALATED or REOPENED event clears
the ack: the operator acknowledged a different situation. `unack` undoes it.
`purge(p_keep_days)` deletes runs started more than that many days ago with
their snapshots and events, and states resolved before then, but always
keeps the newest run and the newest OK live run. `reset` forgets everything.

| view | answers |
| --- | --- |
| `CAPR_ALERTS_LATEST` | OPEN, not acked states. The first columns mirror `CAPR_ALERTS` (values of the last run that saw the key), then `max_severity`, `first_seen`, `last_seen`, `age_days`, `reopen_count`, `run_id`, `events_since` (events since it last opened), `last_event`, `last_event_at` |
| `CAPR_ALERT_EVENTS` | every event, newest first, with the run's `as_of_day` and the state's kind and keys |
| `CAPR_RUNS` | every run with `duration_sec`, `is_last`, `last_ok_run_id`, `last_ok_age_hours` and `stale_run` (`Y` when the last OK live run ended `refresh_stale_hours` (36) or more ago, or never ran), plus a one-line `summary` |
| `CAPR_COVERAGE` | per dbid, live: newest snapshot and its age, `history_days`, series by quality, `n_stale` (not current), `retired` (`data_stale_max_days`) and a one-line `summary` |
| `CAPR_FIT_HISTORY` | `CAP_FIT_HIST` of the OK runs |
| `CAPR_WEEKLY_DIGEST` | the latest OK run against the latest OK run at least `digest_days` (7) older: per series `days_to_full`, `pct`, quality and severity then and now, a `change` verdict, and the alert events in between (`n_new`, `n_resolved`, `n_reopened`, `n_sev_changes`, and `events`, the counts per kind) |
| `CAPR_FORECAST_ACCURACY` | every snapshot row whose series has newer data today: `projected` = `value_then + slope_then * elapsed_days` (the anchored formula), `actual` = `CAPR_FIT.value` now, `error`, `error_pct`. Filter `elapsed_days` for a horizon |

**Poller recipe.** Enable `CAP_REFRESH_JOB`, then poll
`SELECT * FROM capr_alert_events WHERE run_id > :last_seen_run_id`, remember
the highest `run_id`, page on NEW / ESCALATED / REOPENED and clear on RESOLVED.
For a state board, read `CAPR_ALERTS_LATEST`. To silence a known issue,
`EXEC cap_results.ack('<state_key>', SYSDATE + 7, 'ticket 123')`. Watch
`CAPR_RUNS.stale_run`: a stopped job is the one failure the events cannot
show.

Section 0 of the text report and the HTML header print the last run
(`last refresh run <id> at <time> (<n> alerts, <n> fits)`, or
`no refresh run yet (live evaluation)`) and the `CAPR_COVERAGE` summary; the
HTML "All clear" banner needs at least one dbid that is not retired. Both
reports still evaluate the live views; the snapshot does not replace them.

Each refresh also keeps `CAPR_COVERAGE` on its `CAP_RUN` row: `cov_n_dbid`,
`cov_n_current` (not retired) and `cov_summary`, the per-dbid summaries joined
with `|` (the HTML header's own aggregation). Columns on `CAP_RUN` rather
than a table, so uninstall and purge need nothing new. SNAPSHOT reports print
`cov_summary` (every dbid, not scoped); a run older than these columns falls
back to its run summary. `CAPR_RUNS` exposes them last.

The fixture (`test/run_test.sql`) runs a backdated run with FIX_LINEAR's and
FIX_ZIGZAG's last 7 days hidden, so the digest and the accuracy view see a
forecast genuinely issued a week earlier: FIX_LINEAR's error is 0 and its
`days_to_full` moves by exactly -7, FIX_ZIGZAG's error is the closed form
`zz(120) - (zz(113) + 7 * slope(24..113))`. It then drives every row of the
state machine table above, ack and unack, a FAILED run and `purge`.

## Report

`report/report.sql` spools a read-only text report (8 sections: an
at-a-glance alert roll-up from `CAPR_ALERTS`, then the seven detail sections —
days-to-full, tablespace forecast, tablespace anomalies, CPU trend, CPU
anomalies + level shifts, ESM/backtest compare, and the M11 fixed-ceiling
series with their anomalies in 7b) to
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
[show_esm]` and the same for `report_html.sql` (M21 adds `[dbid] [con_dbid]
[source]`, below). `report/defaults.sql` stays the
fallback source of truth: both drivers load it, then override each value with
its argument if one was passed. Unset `&1..&3` cannot prompt (a prompt would
hang a non-interactive run and swallow the next heredoc line) because a
`COLUMN 1 NEW_VALUE 1` whose query returns **no rows** defines the variable as
empty, while an argument that *was* passed survives — SQL*Plus only reassigns a
`NEW_VALUE` on a fetched row. Both scripts `UNDEFINE 1 2 3` at the end, so a
second script in the same session does not inherit the first one's arguments
(`UNDEFINE 1 .. 6` since M21).

**M7.5 — drill-down.** `report/drill_tbspc.sql <tablespace> [con_dbid]` and its
CPU twin `report/drill_cpu.sql [metric] [con_dbid]` answer the question a
summary report cannot: *why does this row say that?* Each prints and spools one
series end to end — the fit header (slope / intercept / R² / slope CI /
days-to-full or -saturation with the WORST/BEST range), the daily series over
`train_days` with `fit`, `residual`, delta, gap and that day's TRAILING and
SAME_DOW baselines (each read from `CAPA_ANOM` with `baseline_mode = ...`, so
the join stays 1:1), a residual footer that re-derives `SUM(resid) = 0`, `resid_se` and
`slope_ci` from scratch next to the values the view publishes, and one
spelled-out arithmetic line per flagged (day, mode). `drill_cpu.sql` scores
`BUSY_PCT` and `DB_CPU_PCT` and adds a block of flagged HOUR_OF_WEEK hours
(weekday and hour, `n_hist`, expected, `eff_sigma`, threshold). That is the auditability goal made
operational: the M9.1 bands can be checked with a calculator. Both arguments are
optional and, like the report drivers, never prompt.

**M21 — scope, source, CSV, cron.** Both drivers take three more optional
positional arguments: `[top_n] [anomaly_days] [show_esm] [dbid] [con_dbid]
[source]`. A `-` skips any of them. With a dbid and/or con_dbid every
section filters on them and the header prints the scope with the container
labels. The views' `rank_*` columns are fleet-wide, so the drivers re-number
them inside the scope with `ROW_NUMBER() OVER (ORDER BY rank_*)`: the same
order, `top_n` counted inside the scope, identical to `rank_*` when no scope
is given. Section 6a joins section 2's scoped rank, so both list the same
tablespaces. `source` is `LIVE` (default) or `SNAPSHOT`: SNAPSHOT reads the
alert list from `CAPR_ALERTS_LATEST`, the section 1 and 7 tables from
`CAPR_FIT_HISTORY` of the newest OK live refresh run, and prints the
`CAPR_COVERAGE` roll-up that run kept (`CAP_RUN.cov_summary`) as the coverage
line; the header says which run. Sections 2 to 6 stay live in SNAPSHOT:
`CAP_FIT_HIST` has the fit columns but not what those sections print beside
them (the +30/+90/+180 projections and bands, the ESM point, the CPU anchor
and gate, the anomaly rows, the ESM compare and backtest). A section with a constant false predicate on the other
source never evaluates it, so SNAPSHOT skips the live `CAPR_ALERTS`
evaluation. `report/report_csv.sql [dbid] [con_dbid]` writes one quoted CSV
per CAPR section view (`SET MARKUP CSV ON QUOTE ON`, header line, every row
and column, `NUMFORMAT TM9`) into `reports/cap_csv_<db>_<ts>/`.
`report/run_report.sh [connect] [--html] [--csv] [--scope D[:C]]
[--snapshot] [--keep N] [--container P] [--schema O]` runs the drivers from
the repo root without prompts, exits non-zero when a spool is missing or holds
an `ORA-` / `SP2-` line, prints each path and rotates old reports only after
a clean run; its header has a cron line.

**M21 — HTML resilience.** `report_html.sql` renders the header and each of
sections 0 to 7 inside its own `BEGIN ... EXCEPTION WHEN OTHERS` block. A
failing query closes any open table, prints a red "Section N failed:
<SQLERRM>" block where the section would be, and the page carries on; the
footer says how many sections failed. The healthy-chip groups of section 0
(tablespaces, series, hosts) each stop at 30 chips and print "+N more", so
a fleet cannot overflow the 32000-byte accumulator.

**Report cost (U12).** Each read of a `CAPA_ANOM`-backed or forecast view
re-runs its chain, so a view read many times dominates. The HTML driver reads
each heavy view once into a PL/SQL collection at the header (the alert list
with the orders of its three consumers precomputed as `ROW_NUMBER()` columns,
the flagged series points, the three anomaly views with their strip
aggregates and dot order, days-to-full, the CPU trend with its projection
columns, the series and the level shifts) and every consumer iterates the
copy; the section tables with a SNAPSHOT branch keep their own query. A
collection that failed to load fails only the sections that use it. Section
0 of the text report reads the alert source once: a materialized `WITH`
feeds both a `TOTAL` row (the counts by severity) and the list. Section 6
reads `CAPR_TBSPC_RANK` for section 2's rank, so it no longer walks
`CAPF_COMPARE` twice, and both headers read `CAPF_ESM_HEALTH_SUMMARY` once.
`DEFINE timing = Y` before a run prints the wall seconds per section (text:
a `TIMING START` / `STOP` pair per section through
`report/sections/timing_*.sql`; HTML: an HTML comment at the end, from
`DBMS_UTILITY.GET_TIME`). On the demo story on the test VM the HTML went from
673 s to 164 s and the text from 222 s to 103 s; most of what is left is the
forecast chain (`CAPF_COMPARE`, `CAPR_FIT`, `CAPR_COVERAGE`) sorting through
small work areas on a 2-CPU VM whose PGA is overcommitted.

**M21 — Prometheus.** `grafana/ords/awrcap_module.sql` publishes a PL/SQL GET
handler `metrics` next to the JSON ones: the text exposition format over
`CAPR_ALERTS` (`awrcap_alert`), `CAPR_FIT` (`awrcap_days_to_full`,
`awrcap_pct_used`), `CAPR_FRESHNESS` (`awrcap_data_through_days`) and an
`awrcap_up` line. `grafana/API.md` has the label set, a `scrape_config` and
the security note.

**M8.4 — `doctor.sql`.** A read-only PASS/WARN/FAIL preflight, in one
exception-wrapped anonymous block so a missing privilege prints one WARN line
instead of aborting: pack access, direct `DBA_HIST_*` reads, `SESSION_PRIVS`,
AWR retention and interval per dbid, days of history per source versus
`min_train_days`, invalid `CAP*` objects and the detected seam mode — closing
with a plain-English explanation of why forecasts would read
`INSUFFICIENT_HISTORY`. It queries `ALL_*` filtered on
`SYS_CONTEXT('USERENV','CURRENT_SCHEMA')` rather than `USER_OBJECTS`, because
the latter follows the *session* user and would report nothing useful when
testing as SYSDBA with `CURRENT_SCHEMA` set elsewhere. Section 10 (M21)
covers the results layer and the live seam contract: the last `CAPR_RUNS`
row and `stale_run`, FAILED runs of the last 7 days with the first error
line, RUNNING runs older than an hour, `CAP_REFRESH_JOB` (enabled, last
scheduler run), open versus acknowledged alert states, retired dbids from
`CAPR_COVERAGE`, and every `CAPV_CONTRACT` row.

`drill_cpu.sql`'s residual footer follows `cpu_deseason`: with the knob at 1
the residuals are taken against the deseasoned fit input (value minus its
weekday or weekend mean plus the window mean), as `CAPF_CPU_TREND` fits it,
so `SUM(resid)` is 0 again and `CI_CALC` equals the view's `CI_VIEW`.

## Testing philosophy

The fixture seam is the correctness gate: since we can't `INSERT` into
`DBA_HIST_*`, `CAPV_*` are pointed at `CAP_FIXTURE_*` tables filled with exact,
anchored, deterministic series. Every asserted number is a closed form recorded
in `CAP_FIXTURE_META` (so `run_test.sql` reads expectations rather than
re-deriving dates). `run_test.sql` prints PASS/FAIL per check and a closing
`RESULT:` line, and exits non-zero on any failure (CI-able); `run_test_ml.sql`
adds the Tier 2 checks behind the `CREATE MINING MODEL` privilege. The count
grows with every milestone, so the docs never quote it. The harness needs
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

**The anomaly modes (M15)** get one fixture day each mode alone can see, and
closed forms for all three:

- The injected Tuesday (70% / 70%) is HIGH under every mode. Its 06:00 hour
  reads 70 against 20 (z = 50 / 5 = 10); its 18:00 hour reads 70 against 60,
  a 10-point move under the 15-point hour threshold, and must stay
  unflagged.
- `INVERTED_WED` (40% / 40%) has a normal daily average, so TRAILING and
  SAME_DOW must not flag it, while HOUR_OF_WEEK flags 06:00 HIGH (40 vs 20,
  z 4) and 18:00 LOW (40 vs 60). It is the latest Wednesday in days 90..120,
  and the probe weekday is chosen to avoid it.
- The FIXPDB1 level-shift step is 18 points over its same-weekday priors on
  each of its 7 days, so SAME_DOW flags all 7 (floored sigma, threshold 9,
  z 6), while TRAILING flags only the 3 days whose deviation clears its
  sawtooth-widened threshold. Since M19.3 `CAPR_ALERTS` collapses the 7
  flagged days into one `DBCPU_ANOM` episode, downgraded to INFO because the
  FIXPDB1 level shift is active.
- The injected Tuesday always falls on one of those step days, so a CPU
  anomaly lookup by day alone returns several rows. Every lookup in
  `run_test.sql` names the full key (`anom_flag(kind, series, mode, ts,
  con_dbid)`, `anom_n(...)`).

Structural checks pin the shape: `CAPA_ANOM` rows = `2 × DAY obs + HOUR obs`,
key uniqueness on `CAPA_ANOM`, `doc_key` / `alert_key` uniqueness on the feeds
and `CAPR_ALERTS`, and the flag invariant in both directions (flag ⇔ `|z| >
mad_k`, no gap, complete, `n_hist ≥ min_hist`). Knob flips (`alert_modes_cpu`
6 and 0, `alert_modes_tbspc` 3, `weekly_min_hist` 9, `hour_gap_ratio` 0.5,
`cpu_min_mad_pct_hour` 3) each assert the change and restore the knob.
`test/lint_anom_joins.sh` keeps `CAPA_ANOM` readers where the key rule is
reviewed, and `test/dbmint_harness.sh <SCHEMA> [--ml]` runs the lint before
it syncs and runs the harness in a throwaway schema.

Before the legacy views were deleted, a parity gate on dbmint compared them
with the engine row by row (FULL OUTER JOIN): `CAPA_TBSPC_ANOM` against the
TRAILING tablespace rows (1068 rows) and `CAPA_CPU_ANOM` against the SAME_DOW
`BUSY_PCT` rows (112 rows). Flag, median, MAD-sigma, threshold, the
percentages, the long-run average and `n_hist` matched with zero
differences. The only differences were the new rows the legacy views had
omitted (`n_hist` 0: 9 and 7) and the tablespace `robust_z` on the 963
floored baselines, finite now. The gate was a one-off check and is not
committed.

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
- **M7–M21 — done.** `PLAN.md` carries each milestone with its commit: the
  report and integration work (M7, M8), forecast quality (M9), CPU (M10), the
  fixed-ceiling series (M11), the three visual paths (M12–M14), the anomaly
  modes (M15) and the 2026-10-17 review program (M16 config and install, M17
  seam and daily, M18 forecasts, M19 alerts and results layer, M20 seam
  extensions, M21 consumers and docs).
- **v2** — memory forecasting (SGA / PGA from `DBA_HIST_MEM_DYNAMIC_COMP`, the
  19c view name, and `DBA_HIST_PGASTAT`); cross-DBID series stitching
  (non-CDB → PDB migrations) keyed on a stable warehouse `target_id`.
