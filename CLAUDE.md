# CLAUDE.md — working notes for this repo

AWR-driven capacity forecasting + anomaly detection, entirely in-database
(Oracle 19c floor). Read `README.md` for the user-facing overview and
`docs/design.md` for deep design rationale. This file is the fast orientation
for making changes safely.

## Golden rules

- **Read-only against AWR.** The suite writes only to its own `CAP_CONFIG` /
  `CAP_ML_MODEL` tables (and OML models). The report and all `CAPV/CAPD/CAPF/CAPA`
  views must never issue DML/DDL against Oracle data. Preserve this.
- **All analytics go through the `CAPV_*` seam.** Never reference `DBA_HIST_*`
  outside `ddl/10_seam_local.sql`. That is what keeps local / warehouse /
  fixture modes byte-identical downstream.
- **Config, not constants.** Thresholds live in `CAP_CONFIG`, read via a one-row
  `cfg` CTE. Add a knob there (idempotent MERGE in `ddl/05_config.sql`) rather
  than hard-coding.
- **`CAP_TBSPC_OVERRIDE` is the third persisted table** (with `CAP_CONFIG` and
  `CAP_ML_MODEL`): operator-set tablespace ceilings + exclusions, created
  idempotently at the bottom of `ddl/05_config.sql`, applied once in
  `CAPD_TBSPC_DAILY`, NOT dropped by `ddl/00_drop.sql`, dropped only by
  `uninstall.sql`. `dbid`/`con_dbid` `0` are wildcards; the most specific
  matching row wins.
- **19c syntax floor.** Inline `OVER (PARTITION BY ... ORDER BY ...)` on every
  window call — the standalone `WINDOW` clause is 21c+. No 21c/23c features.

## Layout / load order

`install.sql` includes, in order: `ddl/00_drop` → `05_config` → the seam
(`10`/`11`/`12` by `seam_mode`) → `20_daily` → `25_series_daily`
(CAPD_SERIES_DAILY, M11) → `30_forecast` → `35_series_forecast`
(CAPF_SERIES_FORECAST) → `40_anomaly` →
`45_report_views` (CAPR_CONTAINER + CAPR_ALERTS + CAPR_SERIES) → `50_ml` (which
pulls `ml/cap_forecast_ml.pks/.pkb` and builds the ESM views + CAPF_BACKTEST)
→ `55_report_views_ml` (the Tier-2-dependent CAPR_* section views).
Opt-in extras outside install.sql: `doctor.sql` (preflight), `install_jobs.sql`
/ `uninstall_jobs.sql` (DBMS_SCHEDULER, disabled by default),
`report/drill_tbspc.sql` / `report/drill_cpu.sql` (single-series drill-down).
Prefixes: `CAPV_` seam → `CAPD_` daily → `CAPF_` forecast → `CAPA_` anomaly →
`CAPR_` integration (display labels + pollable alerts).

## SQL\*Plus gotchas that already bit us

- **Included DDL files `SET DEFINE OFF`**, which persists back into the caller.
  `install.sql` re-asserts `SET DEFINE '&'` before each `&substitution`.
- **A PROMPT line ending in `-` is line continuation** and swallows the next
  line. Never end a PROMPT with a hyphen (that killed the report header once).
- **`&&seam_mode` prompts if undefined** — non-interactive callers must
  `DEFINE seam_mode` up front or a heredoc line gets consumed as the answer.
- **A `--` comment line ending in `;` terminates the statement buffer** in
  plain-SQL context (SQL*Plus doesn't parse comments when scanning for the
  terminator), truncating a CREATE VIEW mid-statement with a baffling
  ORA-00936 pointing at the comment. Safe inside PL/SQL blocks (`/`
  terminates those). Bit us in ddl/30 (M9.1).
- **A substitution variable followed by `.` swallows the dot** in PROMPT text
  (`top &top_n.` prints `top 3`); rephrase. `AUDIT` is a reserved word
  (ORA-00936 pointing at the SELECT). Default `SERVEROUTPUT` (WORD_WRAPPED)
  strips leading blanks from DBMS_OUTPUT lines.
- **`USER_OBJECTS` / `USER_DEPENDENCIES` follow the SESSION user, not
  `CURRENT_SCHEMA`.** When testing as SYSDBA with `ALTER SESSION SET
  CURRENT_SCHEMA = CAPTEST`, query `ALL_*` filtered on
  `owner = SYS_CONTEXT('USERENV','CURRENT_SCHEMA')` (doctor.sql does).
- **Positional args:** `COLUMN 1 NEW_VALUE 1` + a zero-row SELECT defines an
  unpassed `&1` as empty and leaves a passed one intact (verified 19c);
  scripts `UNDEFINE 1 2 3` at the end so a later script doesn't inherit them.
- **`@@` includes resolve relative to the OUTERMOST caller** on 19c, so run
  `install.sql` / `report/report.sql` from the repo root and use full paths
  (`@@ddl/...`, `@@report/sections/...`).

## Non-obvious correctness facts (verified on Oracle 19c)

- `DBA_HIST_DATAFILE` has **no SYSTEM row** on stock 19c → block size must come
  from `DBA_HIST_TABLESPACE.block_size` (primary), datafile only as fallback.
- `REGR_R2` returns **1** for a zero-variance *y* (flat) series, NULL only for
  zero-variance *x*. `FLAT` quality keys off `slope = 0`.
- OML `EXSM_PREDICTION_STEP` is HARD-capped at **30** on 19c at any series
  length (30 ok / 31 fails at 121, 300 and 600 rows). `build_model` caps at
  `LEAST(30, cfg, FLOOR(rows/4))`; don't remove that. So ESM only reaches +30 —
  `CAPF_COMPARE` shows no ESM beyond that.
- `DM$VP<model>` result view columns: `PARTITION_NAME, CASE_ID, VALUE,
  PREDICTION, LOWER, UPPER`. `get_forecast` reads the last five.
- Host CPU (OSSTAT) records under the CDB `con_dbid`; time-model DB CPU is
  per-container. `db_cpu_per_core` divides by summed OSSTAT core counts.
- `DBA_HIST_RESOURCE_LIMIT` **does** carry `CON_DBID` on 19c (verified on
  dbmint), so M11's `CAPV_RESOURCE_LIMIT` keys like every other seam view. Its
  `LIMIT_VALUE` is a `VARCHAR2(10)` ('UNLIMITED' possible) — convert with the
  `REGEXP_LIKE(TRIM(..),'^[0-9]+$')` guard, never a bare `TO_NUMBER`. And
  `MAX_UTILIZATION` is a high-water mark **since instance startup**, so it
  resets on a restart (a level shift, not a lie).
- `DBA_HIST_PDB_INSTANCE` (19c) carries `CON_DBID` + `PDB_NAME` and includes a
  `CDB$ROOT` row whose `con_dbid` equals the CDB dbid — `CAPV_CONTAINER` leans
  on that; the `DBA_HIST_DATABASE_INSTANCE` branch only matters for non-CDBs.
- M9.1 intervals use `t ~ 1.96 + 2.4/df` (no t-distribution in SQL; good to
  ~1% for df>=10, and min_train_days guarantees df>=12). The FIXTURE INSTALLER
  computes expected bands with the same formula — it is part of the contract;
  change both together or FIX_ZIGZAG assertions break.
- Peak-window membership (M10.1) is by the interval's END hour in
  `(peak_hour_from, peak_hour_to]`, so with hourly AWR the default (8,18] is
  exactly the snapshots ending 09:00..18:00. The fixture has TWO snapshots per
  day (ids `2000+2i` ending 06:00, `2001+2i` ending 18:00); tablespace usage
  hangs only off the 18:00 one, and the restart day has no 06:00 snapshot.
- The CPU fixture has **two containers**: the root (`42424242`, OSSTAT +
  time-model) and `FIXPDB1` (`42424243`, **time-model only** — OSSTAT records
  under the CDB con_dbid in real AWR, and giving the PDB its own rows would
  double `host_busy_sec` and break `host_share_pct`). The M10.3 level shift
  therefore rides on `DB_CPU_PCT`. Any assertion counting CPU rows must scope
  on `con_dbid`, not just `dbid`.
- `cpu_gap_hours` defaults to **12**, not something tighter, because the
  fixture's snapshots are 12 h apart (06:00 / 18:00) and, more importantly,
  because `gap_flag` SUPPRESSES anomaly scoring — an over-sensitive default
  silences the whole CPU anomaly layer on a site with wide AWR intervals.
- Backtest ESM twins (`train_backtest`) share the 19c 30-step cap AND the
  `FLOOR(rows/4)` floor, so they may cover fewer than holdout_days forecast
  days (fixture: 93 rows -> 23 of 28). `CAPF_BACKTEST.n_days` reports actual
  coverage; don't assert full-holdout coverage for ESM.
- M9.2/M9.3 contracts in `ddl/30`: the chosen estimator (`slope_method` 0=OLS,
  1=THEILSEN) drives slope/intercept/projections/days-to-full/accel_ratio/FLAT,
  but `r2` and every M9.1 band stay **OLS** residual quantities drawn around
  the chosen line — there is no closed-form Theil-Sen interval in SQL. The
  M9.3 reset day is **inside** the new window (`train_start = reset_day`; its
  used_bytes is already post-purge). Both are asserted by the fixture; change
  the view and the assertions together.
- `SYS.ODCINUMBERLIST` is a shipped `VARRAY(32767) OF NUMBER` and works in
  `TABLE(v)` from PL/SQL — handy for building an expectation list without a
  fixture-owned type. But a collection METHOD (`v.COUNT`) inside a SQL
  statement is ORA-00984 ("column not allowed here"); assign it to a local
  variable first.

## Testing on a 19c test database

Connect where AWR is visible: `sqlplus / as sysdba` in `CDB\$ROOT` (AWR lives
there for local mode).

- **Local smoke** (real AWR): install `seam_mode=local` as sysdba in CDB\$ROOT,
  run the report. Expect `INSUFFICIENT_HISTORY` everywhere unless retention was
  raised (default 8 days).
- **Fixture harness + ML** need `CREATE TABLE/VIEW/TYPE/PROCEDURE` and (for ML)
  `CREATE MINING MODEL`. `V$*` views are **not** required — the report uses
  `SYS_CONTEXT` for identity. Create a test user in a PDB with those privileges,
  then run: `@test/fixture_install.sql` → `DEFINE seam_mode=fixture` →
  `@install.sql` → `@test/run_test.sql` (+ `@test/run_test_ml.sql`). Both exit
  non-zero on failure. Sync the repo to the DB host first because of the
  relative `@@` includes.

## Warehouse mode (Milestone W / M6 — done)

- The `awr-fleet-warehouse` collector now gathers the three sources this suite
  needs into `awrw_tbspc_stat` / `awrw_osstat` / `awrw_time_model` (+ the
  `awrw_tablespace` / `awrw_datafile` dims) and exposes them as `AWRV_*` seam
  views. `ddl/11_seam_warehouse.sql` re-maps CAPV_* onto those AWRV_* views, so
  warehouse mode is byte-identical downstream to local mode.
- Install warehouse mode where the AWRV_* views are visible: **as the warehouse
  owner (AWRWH)**, or a schema with direct SELECT grants on them. The warehouse
  presents every collected database; the report shows con_dbid per row (one
  target reads as one DB, many targets as a fleet report).
- Those warehouse-side objects live in the sibling repo
  (`../awr-fleet-warehouse`): facts in `ddl/30_facts.sql`, dims in
  `ddl/20_dimensions.sql`, AWRV_* in `ddl/50_awrv_views.sql`, collector pulls in
  `collect/awrw_collect.pkb`, forward migration `migrate/002_capacity_facts.sql`.
  Those five capacity tables are the only ones there keyed on `(dbid, con_dbid)`.

## Not yet built (see PLAN.md milestones)

- Memory forecasting (v2 scope). Cross-DBID series stitching (v2).
