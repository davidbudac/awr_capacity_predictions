# AWR Capacity Predictions

SQL-level capacity forecasting and deterministic anomaly detection **inside**
Oracle Database (19c floor), driven entirely by AWR history. No external ML
stack, no agent, no data export — just views, a small config table, one OML
package, and a read-only SQL\*Plus text report.

What it answers:

- **Tablespace growth** — projected size at +30/+90/+180/+365 days (with 95%
  prediction bands) and `days_to_full` with a worst/best-case range
  ("120 days, worst case 80"), per tablespace, per container.
- **CPU trend** — host busy% (from `DBA_HIST_OSSTAT`) and DB CPU seconds (from
  `DBA_HIST_SYS_TIME_MODEL`), with days-to-saturation (+ range).
- **Anomalies** — deterministic median + MAD flags that are reproducible by
  hand: every flag exposes value, baseline median, MAD-sigma, the k·sigma
  threshold, and a robust z-score.
- **Fixed-ceiling series** — peak `processes` / `sessions` against the init
  parameters, redo GiB/day (FRA / archive sizing), and total DB size against
  the summed tablespace ceilings, each with the same days-to-limit machinery.
- **Which engine to trust** — `CAPF_BACKTEST` replays the recent past
  (holdout) and scores each forecasting engine's MAPE/bias against what
  actually happened.

Two forecasting engines run side by side:

- **Tier 1 — pure SQL** (`REGR_*` linear least-squares). Every projection is
  reconstructable from slope + intercept.
- **Tier 2 — OML ESM** (`DBMS_DATA_MINING`, exponential smoothing) for a
  seasonality-aware second opinion, compared against Tier 1 in the report.

## Architecture — layered views over a portable seam

```
CAPV_*  seam        DBA_HIST-shaped views  (local | warehouse | fixture source)
  |                 incl. CAPV_CONTAINER: (dbid, con_dbid) -> DB / PDB names
CAPD_*  daily       one clean row per (series, day): blocks->bytes, counter
  |                 deltas with restart guards; CAPD_SERIES_DAILY (M11) adds
  |                 the fixed-ceiling series keyed by a `series` name
CAPF_*  forecast    Tier 1 REGR fits + 95% bands; CAPF_SERIES_FORECAST (M11),
  |                 CAPF_BACKTEST (holdout scores), CAPF_ESM_FORECAST /
  |                 CAPF_COMPARE for Tier 2
CAPA_*  anomaly     rolling median + MAD (tablespace: trailing window;
  |                 CPU: same-weekday seasonal baseline) + CAPA_CPU_SHIFT,
  |                 window-vs-window sustained level shifts
CAPR_*  integration CAPR_CONTAINER (display labels) + CAPR_ALERTS (one row per
  |                 current issue -- pollable by OEM / Zabbix / Nagios)
  |                 + one view per report section (M8.2), so the text and
  |                 HTML drivers only FORMAT and cannot drift
report/             read-only SQL*Plus text report (8 sections) + HTML twin
```

Only **three** tables are persisted: `CAP_CONFIG` (tuning knobs, MERGE-seeded),
`CAP_TBSPC_OVERRIDE` (limit overrides / exclusions) and `CAP_ML_MODEL` (Tier 2
registry). OML models themselves are schema objects.

The **seam** is the portability trick: all analytics are written once against
the thin `CAPV_*` views, so the identical SQL runs against local `DBA_HIST_*`,
the `awr-fleet-warehouse` `AWRV_*` views, or the test fixtures — you just swap
which seam file `install.sql` loads.

## Install

```sql
sqlplus / as sysdba           -- install where DBA_HIST_* is visible: CDB$ROOT
SQL> DEFINE seam_mode = 'local'   -- local | warehouse | fixture
SQL> @install.sql
```

`install.sql` runs the layered DDL in order and ends with a validity check that
fails loudly if any object is invalid. Re-running is idempotent.

Modes:

| seam_mode | source | notes |
|-----------|--------|-------|
| `local` (default) | `DBA_HIST_*` | needs Diagnostics Pack + **direct** SELECT grants on the DBA_HIST views (not via a role). Install in `CDB$ROOT`. |
| `warehouse` | `awrv_*` seam views | the [awr-fleet-warehouse](../awr-fleet-warehouse) collector gathers tablespace/OSSTAT/time-model history from the fleet; install this suite as the warehouse owner (or a schema with SELECT on the `AWRV_*` views). Presents every collected database keyed on `(dbid, con_dbid)`. The warehouse has no resource-limit fact yet, so `CAPV_RESOURCE_LIMIT` is a zero-row stub there and the `PROCESSES` / `SESSIONS` series are simply empty. |
| `fixture` | `CAP_FIXTURE_*` | test hook; run `test/fixture_install.sql` first. |

Uninstall: `@uninstall.sql`.

## Run the report

```sql
sqlplus / as sysdba              -- run from the REPO ROOT (@@ include paths)
SQL> @report/report.sql          -- spools reports/cap_report_<db>_<ts>.txt
SQL> @report/report.sql 5 7 N    -- top_n / anomaly_days / show_esm, positionally
```

Both drivers take the same three **optional positional arguments**
`[top_n] [anomaly_days] [show_esm]` (`@report/report_html.sql 25 60 Y` too). Any
argument you leave off falls back to `report/defaults.sql`, which both scripts
auto-load — so a bare run never prompts, and editing that file still changes the
defaults for every run.

Read-only: the report only SELECTs; it creates/modifies no database object.

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
   day's median / MAD-sigma / threshold / robust-z from the `CAPA_*` view;
3. a **residual footer** — `SUM(residual)` (0 by construction),
   `resid_se = sqrt(SSE/(n-2))` and `slope_ci` recomputed from scratch next to
   the value the view publishes, so the M9.1 prediction bands can be re-derived
   with a calculator;
4. **anomaly arithmetic** — one spelled-out line per flagged day
   (`value - median = dev`, `threshold = GREATEST(k*sigma, floor)`) with the
   `CAP_CONFIG` knob values shown.

Both arguments of each script are optional and never prompt; `drill_tbspc.sql`
with no tablespace prints usage and stops. Read-only, like everything else.

## HTML report

`report/report_html.sql` is a sibling driver that renders the same eight
sections as a single self-contained HTML dashboard instead of plain text —
severity badges, colored quality pills, inline fill bars for days-to-full and
CPU busy%, and inline-SVG growth/trend charts (per-tablespace history + REGR
projection + ESM+30 point/CI + tablespace limit line + anomaly markers in
section 2; per-`con_dbid` host busy% and DB CPU sec/day charts with a
saturation threshold line in section 4), all rendered as plain `<svg>` with no
JS chart library and no external assets. It opens with a plain-English "At a
glance" summary — a colour-coded attention banner that says up front whether
anything (a tablespace, the whole database, or CPU) is heading for trouble, a
side-by-side hero duo charting whole-database size and host-CPU busy% with
plain-English headlines, best-guess prediction cards (when each tablespace is
likely to run out of room, phrased in words rather than statistics) and a
full-width anomaly timeline that marks every recent unusual day on a per-series
lane. Every jargon column header carries a hover/focus
tooltip in plain English, and a collapsible glossary defines the terms for readers
who are new to them. It has a sticky section nav and light/dark theming. Since
M8.2 it reads exactly the same `CAPR_*` per-section views as
`report/sections/*.sql` (only chart geometry is computed in the driver), so
the text and HTML reports can no longer show different numbers:

```sql
sqlplus / as sysdba              -- run from the REPO ROOT (@@ include paths)
SQL> @report/report_html.sql     -- spools reports/cap_report_<db>_<ts>.html
```

Same knobs, same defaults file, same read-only guarantee: it auto-loads
`report/defaults.sql` and only ever issues SELECTs (the HTML itself is built
in one PL/SQL block via `DBMS_OUTPUT`, captured by `SPOOL`). Open the spooled
`.html` file directly in a browser.

## Tier 2 (OML ESM) — optional

```sql
EXEC cap_forecast_ml.train_all(20);      -- top-20 tablespaces + CPU series
EXEC cap_forecast_ml.train_backtest(20); -- optional: holdout twins for section 6c
-- then re-run report/report.sql to see ESM vs REGR (and the backtest) in section 6
```

Needs `CREATE MINING MODEL` (free in all editions since Dec 2019).
`cap_forecast_ml.drop_all` removes the models. For a weekly `DBMS_SCHEDULER`
retrain job, run the opt-in `@install_jobs.sql` (see *Preflight & scheduler
jobs* below) — it creates `CAP_ML_RETRAIN` disabled.

## Configuration

All knobs live in `CAP_CONFIG` (read by the views via a one-row `cfg` CTE), so
tuning never means editing SQL:

```sql
UPDATE cap_config SET cfg_value = 0.70 WHERE cfg_name = 'r2_gate';
```

Key knobs: `train_days` (90), `recent_days` (28), `min_train_days` (14),
`r2_gate` (0.60), `mad_k` (3), `mad_window_days` (28), `cpu_sat_pct` (80),
`abs_floor_bytes` (100 MiB), `dow_weeks` (8), `cpu_gap_hours` (12: a snapshot
interval longer than this is an AWR gap -- its day is flagged, kept out of the
CPU baselines, and left out of `busy_p95`/`busy_max`), `shift_days` (7),
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
the default; 1 = Theil–Sen, the median of the pairwise slopes — robust to a
one-off step such as a bulk load), `reset_on_shrink` (1: restart a tablespace's
training window after the most recent big *shrink*, so a post-purge series is
not fit across the cliff) and its `shrink_mad_k` (6) threshold,
`peak_hour_from`/`peak_hour_to` (8/18, the busy-hour window for `BUSY_PEAK` /
`DB_CPU_PEAK`), `cpu_sat_on_p95` (1: `CPU_SAT` alerts follow the p95 busy-hour
trend rather than the daily average) and `series_sat_pct` (90: the percent of a
fixed-ceiling series' limit — `processes`, `sessions`, total DB size — treated
as saturated, since hitting `processes` exactly is an outage).
Run `SELECT * FROM cap_config ORDER BY cfg_name;` for the full annotated list.

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
(`OVERRIDE` / `AUTOEXTEND` / `ALLOCATED`). The table is persisted: your rows
survive `@install.sql` and are removed only by `@uninstall.sql`.

## Alerting / integration

`CAPR_ALERTS` is the machine-readable surface: one row per current issue —
`severity` (CRIT/WARN/INFO), `kind` (`TBSPC_FULL`, `TBSPC_NEARFULL`,
`TBSPC_ANOM`, `CPU_SAT`, `DBCPU_SAT`, `CPU_ANOM`, `CPU_SHIFT`,
`SERIES_LIMIT`, `SERIES_NEARLIMIT`), the `(dbid, con_dbid)` keys plus a
resolved `db_pdb` label, the metric `value` vs its `threshold`, and a
ready-to-page `message`. Poll it from an OEM metric extension, Zabbix, Nagios,
or a scheduler job:

```sql
SELECT severity, kind, db_pdb, message FROM capr_alerts ORDER BY sev_rank;
```

Both reports' at-a-glance blocks are built from the same view, so what pages
you and what the report says can never disagree.

## Preflight & scheduler jobs

Two standalone scripts at the repo root; neither is part of `install.sql`.

**`@doctor.sql`** — read-only preflight. Run it *before* installing (and again
after) in the schema/container you intend to use. It prints a PASS/WARN/FAIL
checklist: Diagnostics Pack access, direct SELECT on each `DBA_HIST_*` view the
local seam needs, the `CREATE TABLE/VIEW/PROCEDURE/TYPE/MINING MODEL/JOB`
privileges, AWR retention and snapshot interval per dbid, how many distinct days
each source actually holds versus `min_train_days`, and — if the suite is already
installed — invalid `CAP*` objects plus the seam mode in use. It closes with a
plain-English reason why forecasts would come back `INSUFFICIENT_HISTORY`. It
creates nothing and every probe is exception-wrapped, so a missing privilege
prints one WARN line instead of aborting the run.

**`@install_jobs.sql`** — opt-in `DBMS_SCHEDULER` automation, **both jobs created
DISABLED**; re-running it is idempotent. `CAP_ML_RETRAIN` runs
`cap_forecast_ml.train_all` weekly (Sun 02:00). `CAP_REPORT_SPOOL_JOB` runs daily
(03:00) and calls the `cap_report_spool(p_dir)` procedure the script also
creates, which writes `<dir>/cap_alerts.txt` through `UTL_FILE` — a pollable
snapshot (header with timestamp + CRIT/WARN/INFO counts, then one pipe-delimited
line per `CAPR_ALERTS` row), *not* the full report, since SQL\*Plus spooling
cannot happen inside a scheduler job. For the formatted report keep driving
`report/report.sql` from cron. The directory object is not created for you: the
script checks `ALL_DIRECTORIES` and prints the exact `CREATE DIRECTORY` / `GRANT
READ, WRITE` DDL if it is missing. Override its name with
`DEFINE report_dir = 'MY_DIR'` before running (default `CAP_REPORTS`).

```sql
@doctor.sql                                    -- before anything else
@install_jobs.sql                              -- opt-in, jobs land disabled
EXEC DBMS_SCHEDULER.ENABLE('CAP_ML_RETRAIN')
EXEC DBMS_SCHEDULER.ENABLE('CAP_REPORT_SPOOL_JOB')
@uninstall_jobs.sql                            -- drops both jobs + the procedure
```

## Testing

Deterministic fixture harness — no randomness, all closed-form:

```sql
-- in a schema with CREATE TABLE/VIEW/TYPE/PROCEDURE (+ CREATE MINING MODEL for ML):
@test/fixture_install.sql
DEFINE seam_mode = 'fixture'
@install.sql
@test/run_test.sql        -- 199 assertions; exits non-zero on any failure
@test/run_test_ml.sql     -- 13 Tier 2 ESM + backtest assertions (needs CREATE MINING MODEL)
```

No `V$` access is needed (identity comes from `SYS_CONTEXT`), and fixture mode
never touches `DBA_HIST_*`.

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
to exactly 10 MiB/day).

Two containers: the root (`FIXCDB`/`CDB$ROOT`) carries OSSTAT + time-model with
a mid-series restart (dropped by the startup-time guard), an injected
+30-point Tuesday (flags in the same-weekday view) and a pure AWR gap on a
Sunday (the next interval spans 36 h → the following day reads 30% against a
40% baseline and must stay unflagged purely because `gap_flag = 'Y'`);
`FIXCDB`/`FIXPDB1` carries **time-model only** — a 7-day DB CPU sawtooth that
steps +18 points for the last week, which only `CAPA_CPU_SHIFT` can see.

Fixed-ceiling series (M11), from the `CAP_FIXTURE_RESOURCE_LIMIT` /
`CAP_FIXTURE_SYSSTAT` tables: `SESSIONS` 200→440 of 500 (→ `days_to_limit = 5`,
a `SERIES_LIMIT` CRIT), `PROCESSES` constant 150 of 300 (FLAT, silent) and
`REDO_GB_DAY` at exactly 2.0 GiB/day (no ceiling, never alerts).

Every expected number is computed by the installer in exact arithmetic and
stored in `CAP_FIXTURE_META`, so the assertions read them instead of
re-deriving. That includes the M9.1 bands, which the installer computes with
the **same** `t ≈ 1.96 + 2.4/df` approximation `ddl/30_forecast_views.sql`
uses — the two are a matched pair; change them together. Cleanup:
`@test/fixture_remove.sql`.

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
  rows). So Tier 2 forecasts only ever reach **+30 days**; `+90/180/365` are
  REGR-only in `CAPF_COMPARE`. The package caps the step automatically.
- **Anomalies key off the per-day growth RATE, not the raw delta.** Across an
  AWR gap (missing snapshots) `CAPD_TBSPC_DELTA` exposes `day_gap` and divides
  the delta by it, so a multi-day gap is not mistaken for a one-day spike. The
  CPU series handles the same problem differently (M10.5): the day is kept, but
  `max_interval_hours` / `gap_flag` / `day_gap` mark it, `busy_p95` /
  `busy_max` / `busy_peak_pct` (and the `db_cpu_*` twins) ignore intervals
  longer than `cpu_gap_hours`, and `CAPA_CPU_ANOM` / `CAPA_CPU_SHIFT` neither
  score a gap day nor let it into a baseline. The daily *average* over a gap is
  still a valid multi-day average attributed to the ending day — `gap_flag` is
  the column that says so.
- **Re-install preserves your tuning, overrides and models.** `CAP_CONFIG`
  knobs, `CAP_TBSPC_OVERRIDE` rows and the `CAP_ML_MODEL` registry (and its OML
  models) survive `@install.sql` (`00_drop` no longer drops the three persisted
  tables; the MERGE seeds only missing keys). Use `@uninstall.sql` for a full
  teardown.
- **Container identity.** Analytics key on `(dbid, con_dbid)`; `con_dbid`
  separates PDBs (their `TS#` values collide), and `dbid` is folded into ESM
  model names + report correlations so a cross-database `con_dbid` collision
  never merges two series. Cross-DBID series stitching (non-CDB → PDB
  migrations) is a documented v2 item.

See `docs/design.md` for the full rationale and layer-by-layer detail.
