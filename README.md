# AWR Capacity Predictions

SQL-level capacity forecasting and deterministic anomaly detection **inside**
Oracle Database (19c floor), driven entirely by AWR history. No external ML
stack and no agent: views, two operator tables, an OML package, a results
package, and read-only SQL\*Plus reports (text, HTML, CSV). Three optional
visual paths (Kibana, Grafana over ORDS, Oracle APEX) read the same views.

📖 **Documentation site:** <https://davidbudac.github.io/awr_capacity_predictions/>

🧪 **Sample report** (real output, fictional database): <https://davidbudac.github.io/awr_capacity_predictions/demo/cap_report_demo.html>

What it answers:

- **Tablespace growth** — projected size at +30/+90/+180/+365 days (with 95%
  prediction bands) and `days_to_full` with a worst/best-case range
  ("120 days, worst case 80"), per tablespace, per container.
- **CPU trend** — host busy% (from `DBA_HIST_OSSTAT`) and DB CPU per
  container (from `DBA_HIST_CON_SYS_TIME_MODEL`, as a percent of the host's
  logical CPUs), with days-to-saturation (+ range). The fit is deseasoned
  (weekday / weekend) and graded on slope significance by default, and a host
  already running at the saturation line is reported now (`CPU_HOT`), not
  only forecast.
- **Anomalies** — deterministic median + MAD flags that are reproducible by
  hand: every flag exposes value, baseline median, MAD-sigma, the k·sigma
  threshold, the baseline size and a robust z-score. Each observation is scored
  against three baselines side by side: TRAILING (the last 28 days: "unusual
  lately?"), SAME_DOW (the same weekday over the last 8 weeks: "unusual for a
  Tuesday?") and, for CPU, HOUR_OF_WEEK (the same weekday and hour: "unusual
  for Tuesday 06:00?"). Scored series: tablespace growth rates, host busy%,
  DB CPU per container, and the fixed-ceiling series (`PROCESSES`,
  `SESSIONS`, `REDO_GB_DAY` levels and `DB_SIZE_GB` growth).
- **Fixed-ceiling series** — peak `processes` / `sessions` against the init
  parameters, redo GiB/day (with days of FRA at the current rate), total DB
  size against the summed tablespace ceilings, ASM diskgroups, and TEMP / UNDO
  peaks, each with the same days-to-limit machinery.
- **Sizing ask** — how many GiB to add to a tablespace so the upper 95% band
  stays under its ceiling for 30 / 90 / 180 days, and the date to add it by.
- **Alert state over time** — an optional results layer records each refresh
  run, keeps one state per alert (new, escalated, resolved, reopened) with an
  acknowledgement, and derives a weekly digest and the accuracy of past
  forecasts.
- **Which engine to trust** — `CAPF_BACKTEST` replays the recent past
  (holdout) and scores each forecasting engine's MAPE/bias against what
  actually happened.

Two forecasting engines run side by side:

- **Tier 1 — pure SQL** (`REGR_*` linear least-squares by default; Theil-Sen
  or a drift estimator on demand). Projections start at today's value
  (`value + slope x h`), so every one is reconstructable with a calculator.
  A tablespace with recurring purges is graded `CYCLIC` and judged on its
  peaks.
- **Tier 2 — OML ESM** (`DBMS_DATA_MINING`, exponential smoothing) for a
  seasonality-aware second opinion, compared against Tier 1 in the report.

## Architecture — layered views over a portable seam

```
CAPV_*  seam        DBA_HIST-shaped views  (local | warehouse | fixture source)
  |                 incl. CAPV_CONTAINER: (dbid, con_dbid) -> DB / PDB names;
  |                 per-container time model and redo from the DBA_HIST_CON_ views;
  |                 CAPV_CONTRACT says which sources carry rows
CAPD_*  daily       one clean row per (series, day): blocks->bytes, counter
  |                 deltas with restart guards (CAPD_COUNTER_DELTA), day
  |                 coverage (is_complete); interval and hourly CPU views;
  |                 CAPD_SERIES_DAILY adds the fixed-ceiling series by name
CAPF_*  forecast    Tier 1 fits anchored at today + 95% bands, CYCLIC grade,
  |                 is_current; CAPF_SERIES_FORECAST, CAPF_BACKTEST (holdout
  |                 scores), CAPF_ESM_* / CAPF_COMPARE for Tier 2
CAPA_*  anomaly     one median + MAD engine (CAPA_ANOM): every observation x
  |                 every baseline mode of its grain (TRAILING + SAME_DOW per
  |                 day; HOUR_OF_WEEK per CPU hour, from CAPD_CPU_HOURLY);
  |                 CAPA_ANOM_DAY = one row per observation; CAPA_CPU_SHIFT,
  |                 window-vs-window sustained level shifts
CAPR_*  integration CAPR_CONTAINER (display labels), CAPR_SEVERITY (one home
  |                 for forecast severities), CAPR_ALERTS (one row per current
  |                 issue, pollable by OEM / Zabbix / Nagios), one view per
  |                 report section and the point feeds, so the drivers only
  |                 FORMAT and cannot drift
CAPR_* results      (ddl/60, optional to use) CAP_RESULTS.refresh snapshots
  |                 CAPR_FIT and CAPR_ALERTS into run history and alert state:
  |                 CAPR_ALERTS_LATEST, CAPR_ALERT_EVENTS, CAPR_WEEKLY_DIGEST,
  |                 CAPR_FORECAST_ACCURACY, CAPR_COVERAGE
report/             read-only SQL*Plus text report (sections 0-7) + HTML twin
                    + CSV export + run_report.sh (cron) + two drill scripts
```

Seven tables are persisted and survive a re-install: `CAP_CONFIG` (tuning
knobs, MERGE-seeded), `CAP_TBSPC_OVERRIDE` (limit overrides, exclusions,
per-tablespace thresholds), `CAP_ML_MODEL` (Tier 2 registry) and the results
layer `CAP_RUN`, `CAP_FIT_HIST`, `CAP_ALERT_STATE`, `CAP_ALERT_EVENT`. OML
models themselves are schema objects.

The **seam** is the portability trick: all analytics are written once against
the thin `CAPV_*` views, so the identical SQL runs against local `DBA_HIST_*`,
the `awr-fleet-warehouse` `AWRV_*` views, or the test fixtures — you just swap
which seam file `install.sql` loads.

## Quickstart

On the database host (or anywhere `sqlplus` can reach `CDB$ROOT` as sysdba):

```bash
git clone https://github.com/davidbudac/awr_capacity_predictions.git
cd awr_capacity_predictions
./quickstart.sh                  # preflight (doctor.sql) + install (local mode) + first report
```

That is the whole installation. The report lands in `reports/cap_report_<db>_<ts>.txt`.
`./quickstart.sh user/pw@//host/svc` connects as someone else; `@quickstart.sql`
from inside SQL*Plus (started in the repo root) does the same without the shell.
On a stock box the first report says `INSUFFICIENT_HISTORY` -- AWR keeps only
8 days by default; raise it once with
`EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention => 90*24*60);`.

`quickstart` stops before the install when `doctor.sql` reports a FAIL line
(fix it, or `DEFINE force_install = Y` to install anyway). As `/ as sysdba`
it installs into SYS, and `install.sql` prints a warning saying so. For a
lasting install, create a dedicated owner once with `@create_owner.sql` (as
SYSDBA: `C##AWRCAP` in CDB$ROOT, `AWRCAP` in a PDB, with direct grants on
every DBA_HIST_* view the seam reads) and install as that user.

## Install (manual / other modes)

```sql
sqlplus / as sysdba           -- install where DBA_HIST_* is visible: CDB$ROOT
SQL> DEFINE seam_mode = 'local'   -- local | warehouse | fixture
SQL> @install.sql
```

`install.sql` prints the target schema (`CURRENT_SCHEMA`), runs the layered
DDL in order, recompiles any INVALID `CAP*` object of that schema and ends with
a validity check that fails loudly if one is still invalid. Re-running is
idempotent.

Modes:

| seam_mode | source | notes |
|-----------|--------|-------|
| `local` (default) | `DBA_HIST_*` | needs Diagnostics Pack + **direct** SELECT grants on the DBA_HIST views (not via a role). Install in `CDB$ROOT`. |
| `warehouse` | `awrv_*` seam views | the [awr-fleet-warehouse](../awr-fleet-warehouse) collector gathers tablespace/OSSTAT/time-model history from the fleet; install this suite as the warehouse owner (or a schema with SELECT on the `AWRV_*` views). Presents every collected database keyed on `(dbid, con_dbid)`. The warehouse has no resource-limit, parameter, ASM or segment facts yet, so `CAPV_RESOURCE_LIMIT`, `CAPV_PARAMETER`, `CAPV_ASM_DISKGROUP` and `CAPV_SEG_STAT` are zero-row stubs there (the `PROCESSES` / `SESSIONS` / `ASM_DG` series are simply empty), and its time model is the CDB-wide one. |
| `fixture` | `CAP_FIXTURE_*` | test hook; run `test/fixture_install.sql` (or `test/demo_fixture.sql`) first. |

Uninstall: `@uninstall.sql`.

## Run the report

```sql
sqlplus / as sysdba              -- run from the REPO ROOT (@@ include paths)
SQL> @report/report.sql          -- spools reports/cap_report_<db>_<ts>.txt
SQL> @report/report.sql 5 7 N    -- top_n / anomaly_days / show_esm, positionally
SQL> @report/report.sql 10 30 AUTO 42424242 42424243   -- one container only
SQL> @report/report.sql - - - - - SNAPSHOT             -- from the last refresh run
```

Both drivers take the same **optional positional arguments**
`[top_n] [anomaly_days] [show_esm] [dbid] [con_dbid] [source]`
(`@report/report_html.sql 25 60 Y` too). Any argument you leave off, or pass
as `-`, falls back to `report/defaults.sql`, which both scripts auto-load, so
a bare run never prompts. `dbid` / `con_dbid` scope every section to one
database or container, and `top_n` ranks inside that scope. `source` is
`LIVE` (default: evaluate the views now) or `SNAPSHOT`: the alert list and the
section 1 / 7 fits come from the newest OK refresh run of the results layer,
which is fast, and the header says so.

Read-only: the report only SELECTs; it creates/modifies no database object.

`@report/report_csv.sql [dbid] [con_dbid]` writes one CSV per CAPR section
view (every column, every row in the scope) into
`reports/cap_csv_<db>_<ts>/`. For cron, `report/run_report.sh [connect]
[--html] [--csv] [--scope D[:C]] [--snapshot] [--keep N] [--container PDB]
[--schema OWNER]` runs the drivers from the repo root and exits non-zero when
sqlplus exits non-zero (a failed `--container` / `--schema` aborts the run),
when the session output has an ORA- or SP2- line, or when a spool is missing or
holds one.

### Drill-down

When a report row looks wrong, drill into that one series and check the
arithmetic by hand:

```sql
SQL> @report/drill_tbspc.sql SYSAUX          -- one tablespace (name required)
SQL> @report/drill_tbspc.sql SYSAUX 2482321  -- ... in one container only
SQL> @report/drill_cpu.sql                   -- BUSY_PCT (default metric)
SQL> @report/drill_cpu.sql DB_CPU_PCT        -- or BUSY_P95 | BUSY_PEAK |
                                             -- BUSY_PCT | DB_CPU_SEC | DB_CPU_P95
```

Each prints to screen and spools `reports/cap_drill_<name>_<ts>.txt`:

1. the **fit header** — slope, intercept, R², the 95% slope CI and
   days-to-full / days-to-saturation with its WORST/BEST range;
2. the **daily series** over the `train_days` window — actual, fitted
   (`icept + slope * day_n`), residual, day-over-day delta, AWR gap, and that
   day's median / MAD-sigma / threshold / robust-z under TRAILING and under
   SAME_DOW;
3. a **residual footer** — `SUM(residual)` (0 by construction),
   `resid_se = sqrt(SSE/(n-2))` and `slope_ci` recomputed from scratch next to
   the value the view publishes, so the M9.1 prediction bands can be re-derived
   with a calculator;
4. **anomaly arithmetic** — one spelled-out line per flagged (day, mode)
   (`value - median = dev`, `threshold = GREATEST(k*sigma, floor)`) with
   the `CAP_CONFIG` knob values shown. `drill_cpu.sql` scores `BUSY_PCT` and
   `DB_CPU_PCT`, reconciles residuals against the deseasoned fit and adds a
   block of flagged HOUR_OF_WEEK hours;
5. **who is filling it** (`drill_tbspc.sql`) — the top 10 segments by space
   allocated over the last `seg_window_days` (28), with their share of the
   tablespace's growth, from `CAPR_SEGMENT_GROWTH` over `DBA_HIST_SEG_STAT`.
   AWR keeps only the top segments of each snapshot, so small growers may be
   missing.

Both arguments of each script are optional and never prompt; `drill_tbspc.sql`
with no tablespace prints usage and stops. Read-only, like everything else.

## HTML report

`report/report_html.sql` is a sibling driver that renders the same sections
as one self-contained HTML page. It opens with a verdict strip (critical,
warnings, forecast quality, host CPU p95, Tier 2 models, the last refresh run
and data coverage) and a ranked attention list built from `CAPR_ALERTS`: one
row per issue with the number that matters, and one line naming what is
healthy. The charts share one grammar: area under history, the 95%
prediction band as a shaded wedge, a labelled ceiling or saturation line, a
"today" divider, hollow rings on unusual days, the ESM point and the date
where the projection crosses the ceiling. The whole-database hero reads the
suite's own `DB_SIZE_GB` fit, so it prints the same days figure as section 7.
Tablespaces that need a look get a card; quiet ones collapse into a sparkline
strip. Charts are plain `<svg>`: no JavaScript library and no external
assets. Each section renders inside its own exception block, so a broken
view prints a red block for that section and the footer counts it instead of
losing the page. Like the text report it reads only the `CAPR_*` views (only
chart geometry is computed in the driver), so the two cannot show different
numbers:

```sql
sqlplus / as sysdba              -- run from the REPO ROOT (@@ include paths)
SQL> @report/report_html.sql     -- spools reports/cap_report_<db>_<ts>.html
```

Same arguments, same defaults file, same read-only guarantee (the HTML is
built in one PL/SQL block via `DBMS_OUTPUT`, captured by `SPOOL`). Open the
spooled `.html` file directly in a browser.

## Tier 2 (OML ESM) — optional

```sql
EXEC cap_forecast_ml.train_all(20);   -- top-20 tablespaces + CPU series, and their backtest twins
EXEC cap_forecast_ml.train_tablespace('ORDERS_DATA');   -- retrain one series
-- then re-run report/report.sql to see ESM vs REGR (and the backtest) in section 6
```

Needs `CREATE MINING MODEL` (free in all editions since Dec 2019).
`cap_forecast_ml.drop_all` removes the models. A failed build keeps the
previous model, records `FAILED` with `last_error` in `CAP_ML_MODEL`, and the
`train_*` procedures raise ORA-20060 after the batch so a scheduler run does
not read SUCCEEDED. `CAPF_ESM_HEALTH` / `CAPF_ESM_HEALTH_SUMMARY` show ok,
failed and stale models; both report headers print the counts and
`CAPR_ALERTS` raises `MODEL_HEALTH`. For a daily `DBMS_SCHEDULER` retrain,
run the opt-in `@install_jobs.sql` (see *Preflight & scheduler jobs* below);
it creates `CAP_ML_RETRAIN` disabled.

The ESM point compared with Tier 1 is the model's furthest step, at most +30
days on 19c, and it counts only while the model is at most
`esm_max_age_days` (7) older than its series' last day.

## Configuration

All knobs live in `CAP_CONFIG` (the views read them only through the one-row
view `CAP_CFG`), so tuning never means editing SQL:

```sql
UPDATE cap_config SET cfg_value = 0.70 WHERE cfg_name = 'r2_gate';
UPDATE cap_config SET cfg_value = cfg_default WHERE cfg_name = 'r2_gate';  -- reset
SELECT * FROM cap_cfg_check WHERE status <> 'OK';   -- missing knobs, broken range rules
```

A re-install inserts missing keys and refreshes `cfg_default` / `cfg_desc`,
never your `cfg_value`. The one row it overwrites is `suite_version`, which
records the release that built the objects and is not a knob. The full knob
table, with defaults and the `CAP_CFG_CHECK` range rules, is in the
[reference](https://davidbudac.github.io/awr_capacity_predictions/reference.html#config).

Key knobs: `train_days` (90), `recent_days` (28), `min_train_days` (14),
`r2_gate` (0.60), `cpu_sat_pct` (80), `cpu_gap_hours` (12: a snapshot
interval longer than this is an AWR gap -- its day is flagged, kept out of
every anomaly baseline, and left out of `busy_p95`/`busy_max`), `shift_days` (7),
`shift_baseline_days` (28) and `shift_min_pct` (15) for level-shift detection,
`dtf_warn`/`dtf_crit` (90/30),
`nearfull_warn_pct`/`nearfull_crit_pct` (90/97), `anomaly_report_days` (14,
the `CAPR_ALERTS` anomaly window -- distinct from the report's own
`anomaly_days` presentation knob, which bounds sections 3 and 5),
`backtest_holdout_days` (28), `esm_tbspc_model` (2 = AUTO: train both
`EXSM_HOLT` and `EXSM_ADDWINTERS(7)` as holdout twins per tablespace and keep
whichever had the lower backtest MAPE -- 0 pins `EXSM_HOLT`, 1 pins
`EXSM_ADDWINTERS(7)`) and `esm_select_by_backtest` (1: set to 0 to skip the two
extra trainings and let AUTO fall back to `EXSM_HOLT`), `report_min_gb` (1:
sections 2 and 6a print a tablespace only if it is growing, near-full, or at
least this many GiB),
`accel_slope_floor_bpd` (1 MiB/day: below this `|slope|`, `accel_ratio` is NULL
instead of a meaningless ratio off a flat series), `slope_method` (0 = OLS,
the default; 1 = Theil-Sen, the median of the pairwise slopes, robust to a
one-off step such as a bulk load; 2 = DRIFT, the median daily rate with
random-walk bands), `reset_on_shrink` (1: restart a tablespace's
training window after the most recent big *shrink*, so a post-purge series is
not fit across the cliff) and its `shrink_mad_k` (6) threshold,
`cyclic_min_cliffs` (2: that many shrink cliffs in the window grade the
tablespace `CYCLIC`, judged on its peaks; 0 = off),
`peak_hour_from`/`peak_hour_to` (8/18, the busy-hour window for `BUSY_PEAK`
and the `busy_peak_pct` / `db_cpu_peak_pct` daily columns), `cpu_sat_on_p95`
(1: `CPU_SAT` alerts follow the p95 busy-hour trend rather than the daily
average), `cpu_quality_gate` (1: a CPU fit is OK when its slope is
significant; 0 = the R² gate) and `cpu_deseason` (1: remove the weekday /
weekend pattern before the fit), `complete_day_pct` (80: a CPU, DB time or
redo day needs this much valid coverage to be fit), `stale_days` (3: a series
whose last day is older than its source's newest day by more reads
`is_current = 'N'` and stops alerting), `series_sat_pct` (90: the percent of a
fixed-ceiling series' limit (`processes`, `sessions`, total DB size) treated
as saturated, since hitting `processes` exactly is an outage),
`esm_max_age_days` (7) and `esm_auto_tie_pct` (0.25) for Tier 2,
`stale_hours` (36) and `data_stale_max_days` (14) for the `DATA_STALE`
dead-man check, `resolve_grace_runs` (2), `refresh_stale_hours` (36) and
`digest_days` (7) for the results layer, and `seg_window_days` (28) for the
"who is filling it" ranking.
Run `SELECT * FROM cap_config ORDER BY cfg_name;` for the full annotated list.

The anomaly knobs:

- `mad_k` (3): a point flags when `|value - median| > mad_k x sigma`.
- `mad_window_days` (28): the TRAILING window. `dow_weeks` (8): how many
  weeks the SAME_DOW and HOUR_OF_WEEK baselines look back.
- `trailing_min_hist` (7) and `weekly_min_hist` (3): the fewest baseline
  observations before TRAILING, or a weekly mode, may flag. They replace
  `tbspc_min_hist` and `cpu_min_dow_hist`; a re-install carries your value
  over to the new name.
- Threshold floors, one per unit, so a flat baseline (MAD = 0) still flags a
  real jump and sub-floor wiggles never do: `abs_floor_bytes` (100 MiB/day,
  tablespaces), `cpu_min_mad_pct` (3: a sigma floor in points, so a CPU day
  needs 3 x 3 = 9 points), `cpu_min_mad_pct_hour` (5, so 15 points for a CPU
  hour), `series_floor_count` (10 sessions or processes) and
  `series_floor_gib` (0.5 GiB/day, redo and DB size growth).
- `hour_gap_ratio` (1.5): at hour grain an interval of 0 h or less, or longer
  than `LEAST(cpu_gap_hours, 1.5 x the instance's median interval)`, is a gap.
- `alert_modes_tbspc` (1), `alert_modes_cpu` (2) and `alert_modes_series` (1):
  bitmasks of the modes that raise a `CAPR_ALERTS` row. Add the bits:
  1 = TRAILING, 2 = SAME_DOW, 4 = HOUR_OF_WEEK (CPU only), 0 = no anomaly
  alerts. `alert_modes_cpu = 6` pages on both weekly modes.

### Limit overrides / exclusions

The autoextend `maxsize` recorded in AWR is a promise the *storage* may not be
able to keep: a 32 GiB maxsize on a 10 GiB filesystem or ASM diskgroup is not
32 GiB of headroom, and a days-to-full computed against it is a comfortable
lie. `CAP_TBSPC_OVERRIDE` lets you state the real ceiling — and silence the
staging tablespace that is *supposed* to fill up:

```sql
-- the real ceiling is the 200 GiB diskgroup, not the 2 TB datafile maxsize
INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, limit_bytes, note)
VALUES (1234567890, 2345678901, 'APPDATA', 200 * 1024 * 1024 * 1024,
        'DG +DATA is 200G; maxsize is fiction');

-- stop forecasting the nightly-truncated staging tablespace, in every database
INSERT INTO cap_tbspc_override (dbid, con_dbid, tablespace_name, exclude_flag, note)
VALUES (0, 0, 'STAGING', 'Y', 'reloaded nightly -- growth is meaningless');

COMMIT;
```

`tablespace_name` is matched **exactly** (no patterns); `dbid = 0` and
`con_dbid = 0` are **wildcards** meaning "any", so one row can be a fleet-wide
rule and a more specific row overrides it (a real `dbid` wins first, then a
real `con_dbid`). The override is applied in `CAPD_TBSPC_DAILY`, so every
layer above it — forecasts, anomalies, `CAPR_ALERTS`, both reports — honours it
automatically. `CAPF_TBSPC_FORECAST.limit_source` reports which rule applied
(`OVERRIDE` / `AUTOEXTEND` / `ALLOCATED`). The same row can carry the
tablespace's own alert thresholds, `dtf_warn`, `dtf_crit`,
`nearfull_warn_pct` and `nearfull_crit_pct` (NULL = the knob), which every
alert and report reads. The overrides do not apply to the `TEMP_PEAK` /
`UNDO_PEAK` series. The table is persisted: your rows survive `@install.sql`
and are removed only by `@uninstall.sql`.

## Alerting / integration

`CAPR_ALERTS` is the machine-readable surface: one row per current issue,
with `severity` (CRIT/WARN/INFO), `kind`, the `(dbid, con_dbid)` keys plus a
resolved `db_pdb` label, the metric `value` vs its `threshold`, a ready-to-page
`message`, the `baseline_mode` that raised an anomaly kind (NULL for the
others), a per-row `alert_key`, a `state_key` that stays the same across days
(kind, dbid, con_dbid, series, mode), `direction` (LE / GE / ABS),
`alarm_threshold` (the WARN line) and `is_current`. The kinds:

| kind | raised when |
|------|-------------|
| `TBSPC_FULL` | a trustworthy fit reaches the ceiling inside `dtf_warn` (a `CYCLIC` tablespace: its peak line) |
| `TBSPC_NEARFULL` | percent used is at or above `nearfull_warn_pct` now, any fit quality |
| `CPU_SAT` / `DBCPU_SAT` | host busy% (p95 by default) / DB CPU% is forecast to reach `cpu_sat_pct` inside `dtf_warn` |
| `CPU_HOT` / `DBCPU_HOT` | the recent p95 median is already at or above `cpu_sat_pct`, any fit quality |
| `CPU_SHIFT` | a sustained level shift of a CPU series (UP = WARN, DOWN = INFO) |
| `SERIES_LIMIT` / `SERIES_NEARLIMIT` | a fixed-ceiling series is forecast to reach / is near `series_sat_pct` of its limit |
| `TBSPC_ANOM`, `CPU_ANOM`, `DBCPU_ANOM`, `SERIES_ANOM` | anomaly episodes in the last `anomaly_report_days`, for the modes the `alert_modes_*` bitmask enables |
| `DATA_STALE` | a dbid's newest AWR snapshot is at least `stale_hours` old (the dead-man check) |
| `MODEL_HEALTH` | a Tier 2 model failed its last build or is stale |

Forecast kinds and `CPU_SHIFT` need a current series (`is_current = 'Y'`); `CAPR_SEVERITY`
computes their severity once, so the report, the fit feed and the alerts
agree. Consecutive flagged days of one series and mode collapse into one
episode row (`first_day`, `n_days`, `max_z`), and a per-day CPU anomaly
inside an active `CPU_SHIFT` window drops to INFO. By default tablespaces and
the M11 series alert on TRAILING and CPU on SAME_DOW; every other mode stays
visible in `CAPR_ANOMALIES` with `alerting = 'N'`. Poll it from an OEM
metric extension, Zabbix, Nagios, or a scheduler job:

```sql
SELECT severity, kind, db_pdb, message FROM capr_alerts ORDER BY sev_rank;
```

Both reports' at-a-glance blocks are built from the same view, so what pages
you and what the report says can never disagree.

### Results layer: alert state, acknowledgement, digest

`CAPR_ALERTS` is evaluated live, so it has no memory. `cap_results.refresh`
(run it from the opt-in `CAP_REFRESH_JOB`, or by hand) records a run in
`CAP_RUN`, copies `CAPR_FIT` into `CAP_FIT_HIST` and merges `CAPR_ALERTS` by
`state_key` into `CAP_ALERT_STATE`, writing a `CAP_ALERT_EVENT` for each
change: `NEW`, `ESCALATED`, `DEESCALATED`, `RESOLVED` (after
`resolve_grace_runs` runs without it) and `REOPENED`. A failed run is
recorded as `FAILED` and re-raised. It is the only writer of those tables.

```sql
EXEC cap_results.refresh
SELECT severity, kind, db_pdb, message, age_days FROM capr_alerts_latest;  -- open, not acked
EXEC cap_results.ack('<state_key or alert_key>', SYSDATE + 7, 'disk ordered')
EXEC cap_results.unack('<state_key>')
SELECT * FROM capr_alert_events WHERE run_id > :last_run_id;   -- poll the changes
SELECT * FROM capr_weekly_digest;      -- days to full then vs now, new / resolved alerts
SELECT * FROM capr_forecast_accuracy;  -- what past projections said vs what happened
```

An ack hides the state in `CAPR_ALERTS_LATEST` until `p_until` (NULL = until
it resolves); an escalation or a reopen clears it. `CAPR_RUNS` lists the runs
(`stale_run` after `refresh_stale_hours`), `CAPR_COVERAGE` the data age and
fit quality per dbid, and `cap_results.purge(p_keep_days)` trims history.

## Optional: Kibana dashboards (ELK)

If you already run an Elastic stack, `elk/` ships the same analytics the
reports print (daily observations, forecasts, fits, anomalies, alerts) into
one index and installs three Lens dashboards: **Tablespaces**, **CPU and
workload series**, and a fleet-wide **Fleet anomalies** board. Anomalies are
drawn in red on every chart; `CAPR_ALERTS` rows appear as a table on each.

```
DB host:  elk/export.sh  ->  NDJSON  ->  Filebeat  ->  Logstash  ->  awrcap-capacity  ->  Kibana
```

Nothing on the database host talks to Elasticsearch and nothing writes to
Oracle. Stack side, run `elk/setup.sh` once and drop
`elk/logstash/oracle_capacity.conf` beside your Oracle pipeline; on the
database host, add `elk/filebeat/awrcap.yml` to Filebeat's `inputs.d/` and
run `elk/export.sh --sid <sid>` daily. Documents carry deterministic ids, so
re-exports overwrite. Details, record shapes and limits:
[`elk/README.md`](elk/README.md); a walkthrough with a screenshot is on the
[Usage](https://davidbudac.github.io/awr_capacity_predictions/usage.html#kibana)
page.

## Optional: Grafana straight from Oracle (ORDS)

The second visual path needs no Elastic stack and copies nothing: ORDS
(Oracle REST Data Services) publishes seven read-only views as JSON and
Grafana's Infinity data source reads them live. The same three boards as the
Kibana path (tablespaces, CPU and workload series, fleet anomalies), with
anomalies as red markers, points and shaded spans.

```
Oracle CAPR_* views  ->  ORDS module awrcap (grafana/ords/awrcap_module.sql)  ->  Grafana + Infinity
```

Install ORDS against the database (lab recipe with a dedicated installer
user and ORDS in Docker: `grafana/ords/README.md`), run
`@grafana/ords/awrcap_module.sql` as the schema owner, then
`docker compose -f grafana/docker-compose.yml up -d` for a provisioned
Grafana on port 3001. The same module serves `GET .../awrcap/metrics` in
Prometheus text format (alerts, days to full, percent used, data age,
`awrcap_up`) for a scrape job. Contract, limits and security notes:
[`grafana/README.md`](grafana/README.md) and [`grafana/API.md`](grafana/API.md).

## Optional: Oracle APEX application

The third visual path needs nothing outside the database: `apex/` ships an
APEX 26.2 application (Oracle JET charts, Interactive Reports, no external
JavaScript) that reads the same `CAPR_*` views as the other two paths from
its parsing schema. Four pages: Overview (alert counts, the live alert list,
worst days to full, total database size), Tablespaces, CPU and workload, and
Fleet anomalies, with a shared filter bar (database, tablespace, date range)
and a data-freshness badge. Each view is loaded once per session into APEX
collections, so pages stay fast while the views stay live.

```
Oracle CAPR_* views  ->  APEX collections (once per session)  ->  app "AWR Capacity" (apex/awrcap_app.sql)
```

Create a workspace on the suite's schema (`@apex/workspace.sql`), import with
`@install.sql` from the `apex/` directory, open
`/ords/r/<workspace>/awrcap/overview`. The export is generated by
`apex/build.py`; details, limits and the lab shortcut: [`apex/README.md`](apex/README.md).

## Preflight & scheduler jobs

Standalone scripts at the repo root; none is part of `install.sql`.

**`@create_owner.sql`** — run once as SYSDBA to create a dedicated owner
(`C##AWRCAP` in CDB$ROOT, `AWRCAP` in a PDB or non-CDB) with direct grants on
every DBA_HIST_* view the local seam reads and the create privileges. Views
and the definer's-rights packages ignore role grants, which is why the grants
are direct. Idempotent.

**`@doctor.sql`** — read-only preflight. Run it *before* installing (and again
after) in the schema/container you intend to use. It prints a PASS/WARN/FAIL
checklist: Diagnostics Pack access, `STATISTICS_LEVEL`, every `DBA_HIST_*`
view the local seam reads and the target schema's direct grants on them, the
create privileges, AWR retention, snapshot interval and newest snapshot age
per dbid, and a readiness table (days of history each feature needs vs days
available). If the suite is installed it adds invalid `CAP*` objects, the
seam mode, `suite_version`, the fit-quality mix, `CAP_CFG_CHECK`, the results
layer (last run, failed or running runs, the refresh job, open vs acked
states, retired dbids) and the live seam-contract check over
`CAPV_CONTRACT`. It creates nothing and every probe is exception-wrapped.
Doctor takes the seam mode from the install, assumes local before one, or
reads `DEFINE cap_doctor_mode = local | warehouse | fixture`; it leaves the
count of FAIL lines in `cap_doctor_fail`, which `quickstart.sql` uses to stop
before installing.

**`@install_jobs.sql`** — opt-in `DBMS_SCHEDULER` automation, **every job
created DISABLED**; re-running it is idempotent. Jobs are created in the
current schema (`CURRENT_SCHEMA`).

| job | default schedule | runs |
|-----|------------------|------|
| `CAP_REFRESH_JOB` | daily 01:30 (`DEFINE refresh_interval`) | `cap_results.refresh`: run history, alert state, events |
| `CAP_ML_RETRAIN` | daily 02:00 (`DEFINE retrain_interval`) | `cap_forecast_ml.train_all` |
| `CAP_REPORT_SPOOL_JOB` | daily 03:00 | `cap_report_spool(p_dir)` |

`cap_report_spool` writes `<dir>/cap_alerts.txt` through `UTL_FILE`: a
pollable snapshot (header with timestamp, data-through, the last refresh run
and CRIT/WARN/INFO counts, then one pipe-delimited line per alert; with a
refresh run on record it lists the open, not acked states of
`CAPR_ALERTS_LATEST`). It is *not* the full report, since SQL\*Plus spooling
cannot happen inside a scheduler job; for the formatted report use
`report/run_report.sh` from cron. The directory object is not created for
you: the script checks `ALL_DIRECTORIES` and prints the exact `CREATE
DIRECTORY` / `GRANT READ, WRITE` DDL if it is missing. Override its name with
`DEFINE report_dir = 'MY_DIR'` before running (default `CAP_REPORTS`).

```sql
@doctor.sql                                    -- before anything else
@install_jobs.sql                              -- opt-in, jobs land disabled
EXEC DBMS_SCHEDULER.ENABLE('CAP_REFRESH_JOB')
EXEC DBMS_SCHEDULER.ENABLE('CAP_ML_RETRAIN')
EXEC DBMS_SCHEDULER.ENABLE('CAP_REPORT_SPOOL_JOB')
@uninstall_jobs.sql                            -- drops the jobs + the procedure
```

## Testing

Deterministic fixture harness — no randomness, all closed-form:

```sql
-- in a throwaway schema with CREATE TABLE/VIEW/TYPE/PROCEDURE (+ CREATE MINING MODEL for ML):
@test/fixture_install.sql
DEFINE seam_mode = 'fixture'
@install.sql
@test/run_test.sql        -- prints PASS/FAIL per check and a closing total; exits non-zero on any failure
EXEC cap_forecast_ml.train_all
@test/run_test_ml.sql     -- Tier 2 ESM + backtest checks (needs CREATE MINING MODEL)
```

Read the closing summary lines ("All fixture assertions passed." / "All ML
assertions passed.", or the FAIL count); the number of checks grows with every
milestone, so the docs do not quote it. No `V$` access is needed (identity
comes from `SYS_CONTEXT`), and fixture mode never touches `DBA_HIST_*`. A
SYSDBA can run it in any schema with `ALTER SESSION SET CURRENT_SCHEMA`;
`test/dbmint_harness.sh <SCHEMA> [--ml]` is the lab wrapper that syncs the
checkout to a VM and does exactly that. `test/docs_lint.sh` checks the docs
against the DDL (knobs, object index, alert kinds) and needs no database.

The spine is 121 days (`i = 0..120`) anchored to `TRUNC(SYSDATE)`, with **two
snapshots a day** — `2000+2i` ending 06:00 (the overnight interval) and
`2001+2i` ending 18:00 (the daytime / peak-window interval, which also carries
every tablespace usage row).

Ten tablespace series: `FIX_LINEAR` (exact 10 MiB/day → slope, R²,
`days_to_full = 4990` checked to the byte; zero residuals, so the M9.1 bands
collapse), `FIX_SPIKE` (one +2 GiB jump → exactly one HIGH on that day, and
Theil–Sen recovers the true 5 MiB/day while OLS is 3.9× off), `FIX_FLAT`
(constant → quality FLAT, no anomaly, the one `is_reportable = 'N'` row),
`FIX_GAP` (a 3-day AWR gap → rate-normalized, no false flag), `FIX_NEARFULL`
(constant at exactly 97% of maxsize → near-full ranking + CRIT alert despite a
FLAT fit), `FIX_FILLING` (20 days of headroom → `TBSPC_FULL` CRIT alert),
`FIX_ZIGZAG` (linear trend with alternating ±20 MiB residuals → the M9.1
prediction-interval, M9.2 Theil–Sen and M9.4 backtest numbers are asserted
against first-principles closed forms), `FIX_OVERRIDE` (`FIX_LINEAR`'s twin
capped at 2 GiB by `CAP_TBSPC_OVERRIDE` → 4990 days-to-full becomes 74,
`limit_source = OVERRIDE`), `FIX_EXCLUDED` (99% full but silenced by a wildcard
`exclude_flag='Y'` row → must appear nowhere) and `FIX_PURGE` (a −600 MiB cliff
at day 90 → M9.3 restarts the window at the cliff, `train_n = 31`, slope back
to exactly 10 MiB/day). Later milestones added `FIX_OVERFULL` (an override
ceiling under the usage: `limit_below_used`), `FIX_DROPPED` (stops 30 days
early: `is_current = 'N'`), `FIX_CYCLIC` / `FIX_CYCLIC_UP` (30-day purge
sawtooths graded `CYCLIC`, flat and growing peaks), `FIX_TEMP` / `FIX_UNDO`
(the `TEMP_PEAK` / `UNDO_PEAK` series) and three segments in `FIX_FILLING`
for "who is filling it". `FIX_GAP` also carries a 3-day burst, one anomaly
episode.

Three containers: the root (`FIXCDB`/`CDB$ROOT`) carries OSSTAT + time-model
on an SMT host (`NUM_CPUS` 8, `NUM_CPU_CORES` 4, so DB CPU % divides by 8
logical CPUs) with a mid-series restart (dropped by the startup-time guard),
a partial day (a noon restart leaves 12 h of 24: `is_complete = 'N'`), an injected
+30-point Tuesday (HIGH under every mode), an inverted Wednesday (40% / 40%:
a normal daily average, so only HOUR_OF_WEEK flags it, 06:00 HIGH and 18:00
LOW) and a pure AWR gap on a
Sunday (the next interval spans 36 h → the following day reads 30% against a
40% baseline and must stay unflagged purely because `gap_flag = 'Y'`);
`FIXCDB`/`FIXPDB1` carries **time-model only** — a 7-day DB CPU sawtooth that
steps +18 points for the last week: `CAPA_CPU_SHIFT` reports the step, and
SAME_DOW flags each of the 7 step days (`DBCPU_ANOM`); `FIXCDB`/`FIXPDB2`
(time-model only) carries a weekday / weekend DB CPU pattern for the CPU
deseasoning and slope-significance tests.

Fixed-ceiling series (M11), from the `CAP_FIXTURE_RESOURCE_LIMIT` /
`CAP_FIXTURE_SYSSTAT` tables: `SESSIONS` 200→440 of 500 (→ `days_to_limit = 5`,
a `SERIES_LIMIT` CRIT), `PROCESSES` constant 150 of 300 (FLAT, silent) and
`REDO_GB_DAY` at exactly 2.0 GiB/day (no ceiling, never alerts; 50 days of the
100 GiB FRA). `CAP_FIXTURE_PARAMETER` carries the init parameters
(`cpu_count` 8) and `CAP_FIXTURE_ASM_DISKGROUP` a DATA diskgroup filling 5
GiB a day (`ASM_DG:+DATA`, a second `SERIES_LIMIT` CRIT).

Every expected number is computed by the installer in exact arithmetic and
stored in `CAP_FIXTURE_META`, so the assertions read them instead of
re-deriving. That includes the M9.1 bands, which the installer computes with
the **same** `t ≈ 1.96 + 2.4/df` approximation `ddl/30_forecast_views.sql`
uses — the two are a matched pair; change them together. Cleanup:
`@test/fixture_remove.sql`.

`test/demo_fixture.sql` is the other fixture: a designed 150-day story for a
fictional e-commerce CDB ("ECOMPRD") that produces the
[sample report](https://davidbudac.github.io/awr_capacity_predictions/demo/cap_report_demo.html).
Run it instead of `fixture_install.sql`, then install in fixture mode, run
`cap_forecast_ml.train_all` and both report drivers.

### Real workload (optional)

The fixture harness proves the arithmetic; it cannot prove the toolkit reads a
live database sensibly. `bench/` is a swingbench harness that drives a shaped
daily load (OLTP growth + DSS CPU + weekend contrast + an injectable anomaly)
against a test database, so the forecast and anomaly views get genuine AWR
history to work on. See [`bench/README.md`](bench/README.md). Nothing in the
suite depends on it.

## Caveats

- **Diagnostics Pack** is required for `DBA_HIST_*` (local mode). The installer
  runs where you point it; check `CONTROL_MANAGEMENT_PACK_ACCESS`.
- **AWR retention bounds training.** Default retention is only **8 days**, far
  below the 90-day training window, so forecasts degrade to
  `INSUFFICIENT_HISTORY` (`TRAIN_N` < `min_train_days`) and say so loudly. For
  real trends raise it:
  `EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention => 90*24*60);`
- **Block size** comes from `DBA_HIST_TABLESPACE` (populated for every
  tablespace), with `DBA_HIST_DATAFILE` only as a fallback — `DBA_HIST_DATAFILE`
  is missing `SYSTEM` on stock 19c, which would otherwise drop it.
- **`REGR_R2` on a flat series returns 1, not NULL** (Oracle returns NULL only
  when the *x* variance is zero). So `FLAT` is detected by `slope = 0`, not a
  NULL R².
- **OML ESM horizon is hard-capped at 30 steps on 19c** (`EXSM_PREDICTION_STEP`
  ≤ 30 at *any* series length — verified: 30 valid, 31 invalid at 121/300/600
  rows). The package also caps it at a quarter of the series length, so 90
  days of history give a 22-step model. `CAPF_COMPARE` shows the model's
  furthest step (at most +30) while the model is fresh (`esm_max_age_days`);
  `+90/180/365` are REGR-only.
- **Growth anomalies key off the per-day RATE, not the raw delta.** Across an
  AWR gap (missing snapshots) `CAPD_TBSPC_DELTA` exposes `day_gap` and divides
  the delta by it, so a multi-day gap is not mistaken for a one-day spike;
  `DB_SIZE_GB` is scored on the same kind of rate. The CPU series handles the
  same problem differently (M10.5): the day is kept, but
  `max_interval_hours` / `gap_flag` / `day_gap` mark it, `busy_p95` /
  `busy_max` / `busy_peak_pct` (and the `db_cpu_*` twins) ignore intervals
  longer than `cpu_gap_hours`, and neither `CAPA_ANOM` (in any mode) nor
  `CAPA_CPU_SHIFT` scores a gap day or lets it into a baseline (it also skips
  incomplete days, like the CPU fit). The hour grain
  applies a tighter rule (`hour_gap_ratio`), and `REDO_GB_DAY` reuses
  `cpu_gap_hours`. A `DB_SIZE_GB` day whose tablespace set changed (one was
  added or dropped) is a gap day too: its move measures membership, not
  growth. The daily *average* over a gap is still a valid multi-day average
  attributed to the ending day; `gap_flag` is the column that says so.
- **Re-install preserves your tuning, overrides and models.** `CAP_CONFIG`
  knobs, `CAP_TBSPC_OVERRIDE` rows and the `CAP_ML_MODEL` registry (and its OML
  models) survive `@install.sql`, and so do the results-layer tables
  (`00_drop` never drops the seven persisted tables). The seed MERGE inserts
  missing keys and refreshes `cfg_default` / `cfg_desc` but never your
  `cfg_value`; only `suite_version` is overwritten. Use `@uninstall.sql` for a
  full teardown.
- **Per-container CPU and redo come from the CON_ views.** In CDB$ROOT,
  `DBA_HIST_SYS_TIME_MODEL` and `DBA_HIST_SYSSTAT` hold one CDB-wide row per
  snapshot; the seam reads `DBA_HIST_CON_SYS_TIME_MODEL` /
  `DBA_HIST_CON_SYSSTAT` instead, so each PDB gets its own DB CPU and redo
  series and the root row is CDB$ROOT alone. `DBA_HIST_RESOURCE_LIMIT` is
  root-only, so `PROCESSES` / `SESSIONS` are CDB-wide series. Warehouse mode
  still collects the CDB-wide views.
- **Container identity.** Analytics key on `(dbid, con_dbid)`; `con_dbid`
  separates PDBs (their `TS#` values collide), and `dbid` is folded into ESM
  model names + report correlations so a cross-database `con_dbid` collision
  never merges two series. Cross-DBID series stitching (non-CDB → PDB
  migrations) is a documented v2 item.

See `docs/design.md` for the full rationale and layer-by-layer detail.
