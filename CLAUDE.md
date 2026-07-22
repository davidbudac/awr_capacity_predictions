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
- **19c syntax floor.** Inline `OVER (PARTITION BY ... ORDER BY ...)` on every
  window call — the standalone `WINDOW` clause is 21c+. No 21c/23c features.

## Layout / load order

`install.sql` includes, in order: `ddl/00_drop` → `05_config` → the seam
(`10`/`11`/`12` by `seam_mode`) → `20_daily` → `30_forecast` → `40_anomaly` →
`50_ml` (which pulls `ml/cap_forecast_ml.pks/.pkb` and builds the ESM views).
Prefixes: `CAPV_` seam → `CAPD_` daily → `CAPF_` forecast → `CAPA_` anomaly.

## SQL\*Plus gotchas that already bit us

- **Included DDL files `SET DEFINE OFF`**, which persists back into the caller.
  `install.sql` re-asserts `SET DEFINE '&'` before each `&substitution`.
- **A PROMPT line ending in `-` is line continuation** and swallows the next
  line. Never end a PROMPT with a hyphen (that killed the report header once).
- **`&&seam_mode` prompts if undefined** — non-interactive callers must
  `DEFINE seam_mode` up front or a heredoc line gets consumed as the answer.
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
