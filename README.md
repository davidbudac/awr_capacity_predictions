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
- **Which engine to trust** — `CAPF_BACKTEST` replays the recent past
  (holdout) and scores each forecasting engine's MAPE/bias against what
  actually happened.

Two forecasting engines run side by side:

- **Tier 1 — pure SQL** (`REGR_*` linear least-squares). Every projection is
  reconstructable from slope + intercept.
- **Tier 2 — OML ESM** (`DBMS_DATA_MINING`, exponential smoothing) for a
  seasonality-aware second opinion, compared against Tier 1 in the report.

## Architecture — six view layers over a portable seam

```
CAPV_*  seam        DBA_HIST-shaped views  (local | warehouse | fixture source)
  |                 incl. CAPV_CONTAINER: (dbid, con_dbid) -> DB / PDB names
CAPD_*  daily       one clean row per (series, day): blocks->bytes, counter
  |                 deltas with restart guards
CAPF_*  forecast    Tier 1 REGR fits (+ CAPF_ESM_FORECAST / CAPF_COMPARE for Tier 2)
CAPA_*  anomaly     rolling median + MAD (tablespace: trailing window;
  |                 CPU: same-weekday seasonal baseline)
CAPR_*  integration CAPR_CONTAINER (display labels) + CAPR_ALERTS (one row per
  |                 current issue -- pollable by OEM / Zabbix / Nagios)
report/             read-only SQL*Plus text report (7 sections)
```

Only **two** tables are persisted: `CAP_CONFIG` (tuning knobs, MERGE-seeded)
and `CAP_ML_MODEL` (Tier 2 registry). OML models themselves are schema objects.

The **seam** is the portability trick: all analytics are written once against
the thin `CAPV_*` views, so the identical SQL runs against local `DBA_HIST_*`,
a future `awr-fleet-warehouse`, or the test fixtures — you just swap which
seam file `install.sql` loads.

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
| `warehouse` | `awrv_*` seam views | the [awr-fleet-warehouse](../awr-fleet-warehouse) collector gathers tablespace/OSSTAT/time-model history from the fleet; install this suite as the warehouse owner (or a schema with SELECT on the `AWRV_*` views). Presents every collected database keyed on `(dbid, con_dbid)`. |
| `fixture` | `CAP_FIXTURE_*` | test hook; run `test/fixture_install.sql` first. |

Uninstall: `@uninstall.sql`.

## Run the report

```sql
sqlplus / as sysdba              -- run from the REPO ROOT (@@ include paths)
SQL> @report/report.sql          -- spools reports/cap_report_<db>_<ts>.txt
```

`report.sql` auto-loads `report/defaults.sql` (so a bare run never prompts); to
change `top_n` / `anomaly_days` / `show_esm`, edit that file.

Read-only: the report only SELECTs; it creates/modifies no database object.

## HTML report

`report/report_html.sql` is a sibling driver that renders the same six
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
who are new to them. It has a sticky section nav and light/dark theming. It duplicates the SQL logic from `report/sections/*.sql`
rather than including those files, so `report.sql` and `report/sections/` are
unaffected:

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
`cap_forecast_ml.drop_all` removes the models. A weekly `DBMS_SCHEDULER`
retrain job is documented (shipped commented-out) in `docs/design.md`.

## Configuration

All knobs live in `CAP_CONFIG` (read by the views via a one-row `cfg` CTE), so
tuning never means editing SQL:

```sql
UPDATE cap_config SET cfg_value = 0.70 WHERE cfg_name = 'r2_gate';
```

Key knobs: `train_days` (90), `recent_days` (28), `min_train_days` (14),
`r2_gate` (0.60), `mad_k` (3), `mad_window_days` (28), `cpu_sat_pct` (80),
`abs_floor_bytes` (100 MiB), `dow_weeks` (8), `dtf_warn`/`dtf_crit` (90/30),
`nearfull_warn_pct`/`nearfull_crit_pct` (90/97), `anomaly_report_days` (14,
the `CAPR_ALERTS` anomaly window), `backtest_holdout_days` (28),
`peak_hour_from`/`peak_hour_to` (8/18, the busy-hour window for `BUSY_PEAK` /
`DB_CPU_PEAK`), `cpu_sat_on_p95` (1: `CPU_SAT` alerts follow the p95 busy-hour
trend rather than the daily average).
Run `SELECT * FROM cap_config ORDER BY cfg_name;` for the full annotated list.

## Alerting / integration

`CAPR_ALERTS` is the machine-readable surface: one row per current issue —
`severity` (CRIT/WARN/INFO), `kind` (`TBSPC_FULL`, `TBSPC_NEARFULL`,
`TBSPC_ANOM`, `CPU_SAT`, `DBCPU_SAT`, `CPU_ANOM`), the `(dbid, con_dbid)` keys plus a
resolved `db_pdb` label, the metric `value` vs its `threshold`, and a
ready-to-page `message`. Poll it from an OEM metric extension, Zabbix, Nagios,
or a scheduler job:

```sql
SELECT severity, kind, db_pdb, message FROM capr_alerts ORDER BY sev_rank;
```

Both reports' at-a-glance blocks are built from the same view, so what pages
you and what the report says can never disagree.

## Testing

Deterministic fixture harness — no randomness, all closed-form:

```sql
-- in a schema with CREATE TABLE/VIEW/TYPE/PROCEDURE (+ CREATE MINING MODEL for ML):
@test/fixture_install.sql
DEFINE seam_mode = 'fixture'
@install.sql
@test/run_test.sql        -- 51 assertions; exits non-zero on any failure
@test/run_test_ml.sql     -- Tier 2 ESM + backtest assertions (needs CREATE MINING MODEL)
```

Fixtures: `FIX_LINEAR` (exact 10 MiB/day → slope, R², days_to_full checked to
the byte), `FIX_SPIKE` (one +2 GiB jump → exactly one HIGH on that day),
`FIX_FLAT` (constant → quality FLAT, no anomaly), `FIX_GAP` (a 3-day AWR gap →
rate-normalized, no false flag), `FIX_NEARFULL` (constant at exactly 97% of
maxsize → near-full ranking + CRIT alert despite a FLAT fit), `FIX_FILLING`
(20 days of headroom → `TBSPC_FULL` CRIT alert), `FIX_ZIGZAG` (linear trend
with alternating ±20 MiB residuals → the M9.1 prediction-interval and M9.4
backtest numbers are asserted against first-principles closed forms), CPU
counters with a mid-series restart (excluded) + an injected +30-point Tuesday
(flags in the same-weekday view), and `FIXCDB`/`FIXPDB1` container rows
(label assertions). Cleanup: `@test/fixture_remove.sql`.

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
  the delta by it, so a multi-day gap is not mistaken for a one-day spike. (The
  CPU busy% over a gap is a valid multi-day average attributed to the ending
  day — a documented minor limitation, not gap-normalized.)
- **Re-install preserves your tuning and models.** `CAP_CONFIG` overrides and
  the `CAP_ML_MODEL` registry (and its OML models) survive `@install.sql`
  (`00_drop` no longer drops the two persisted tables; the MERGE seeds only
  missing keys). Use `@uninstall.sql` for a full teardown.
- **Container identity.** Analytics key on `(dbid, con_dbid)`; `con_dbid`
  separates PDBs (their `TS#` values collide), and `dbid` is folded into ESM
  model names + report correlations so a cross-database `con_dbid` collision
  never merges two series. Cross-DBID series stitching (non-CDB → PDB
  migrations) is a documented v2 item.

See `docs/design.md` for the full rationale and layer-by-layer detail.
