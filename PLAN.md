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
- [x] **M7.4 Bound sections 2 and 6.** Done: `CAPR_TBSPC_FORECAST` computes
      `is_reportable` (growing OR near-full OR `cur_used >= report_min_gb` GiB
      — near-full is in the disjunction so M7.1's rule still holds) and
      `rank_report` (reportable first, growing first, then biggest);
      `CAPR_ESM_COMPARE` inherits both (CPU rows always `'Y'` / rank 0). Text
      and HTML apply the identical `WHERE is_reportable='Y' AND rank_report <=
      top_n` and print the bound in the section header. New knob
      `report_min_gb` (1). Fixture: FIX_FLAT is the one `'N'`.
- [x] **M7.5 Drill-down script.** Done: `report/drill_tbspc.sql <tablespace>
      [con_dbid]` and its CPU twin `report/drill_cpu.sql [metric] [con_dbid]`
      (metric = `BUSY_PCT` default | `BUSY_P95` | `BUSY_PEAK` | `DB_CPU_SEC` |
      `DB_CPU_PCT` | `DB_CPU_P95`) print + spool one series end-to-end: fit
      header (slope/intercept/R2/slope CI/days-to-full|sat with WORST/BEST),
      the daily series over `train_days` with `fit`, `residual`, delta, gap and
      the CAPA_* baseline per day, a residual footer proving `SUM(resid)=0` and
      re-deriving `resid_se` + `slope_ci` from scratch, and one spelled-out
      arithmetic line per flagged day. Optional args via the COLUMN NEW_VALUE
      zero-row trick (never prompts) and `UNDEFINE`d at the end.
- [x] **M7.6 Positional report args.** Done: `@report/report.sql [top_n]
      [anomaly_days] [show_esm]` and the same for `report_html.sql`, with
      `report/defaults.sql` still the fallback source of truth. Unset `&1..&3`
      are defined-as-empty by the zero-row `COLUMN 1 NEW_VALUE 1` trick (a
      passed argument survives it), so neither form ever prompts; both scripts
      `UNDEFINE 1 2 3` at the end. Verified non-interactively on 19c with 0, 1
      and 3 arguments.
- [x] **M7.7 Cleanups.** Done: `anomaly_report_days` KEPT (it is
      `CAPR_ALERTS`' window; the report's `anomaly_days` DEFINE stays
      presentation-only) and README / `docs/reference.html` now say which
      window is which; every header knob goes through
      `TO_CHAR(..,'FM9999990')`, so the text report prints
      `WARN<=90 CRIT<=30 ; CPU saturation 80%` and `reaches 80%`; GiB / MiB
      labels unified across text + HTML wherever the number is `/1073741824`
      (`/1048576`); `accel_ratio` is NULL when
      `|slope| < accel_slope_floor_bpd` (new knob, 1 MiB/day), so a near-flat
      series can no longer show a 500x acceleration.

## M8 — Integration surface

- [x] **M8.1 `CAPR_ALERTS` view.** Done (`ddl/45_report_views.sql`): one row
      per issue — `severity/sev_rank, kind (TBSPC_FULL | TBSPC_NEARFULL |
      TBSPC_ANOM | CPU_SAT | CPU_ANOM), dbid, con_dbid, db_pdb, series_key,
      day_dt, value, threshold, unit, message`. Anomaly kinds window on the
      `anomaly_report_days` knob. Read-only; fixture-asserted.
- [x] **M8.2 `CAPR_*` report views.** Done: one view per report section —
      `CAPR_TBSPC_DAYS_TO_FULL` (1a/1b, with `sev_dtf`/`sev_nearfull` and
      `rank_dtf`/`rank_nearfull` so a driver applies `top_n` with a WHERE),
      `CAPR_TBSPC_ANOMALIES` / `CAPR_CPU_ANOMALIES` (flagged rows + `days_ago`
      so the window is a WHERE too), `CAPR_CPU_TREND` in
      `ddl/45_report_views.sql`; `CAPR_TBSPC_FORECAST`, `CAPR_ESM_COMPARE`
      and `CAPR_BACKTEST` in the new `ddl/55_report_views_ml.sql` (loaded
      after `50_ml`, because they read `CAPF_COMPARE`/`CAPF_BACKTEST`). Every
      GiB/MiB conversion, severity marker and `db_pdb` label is computed once
      in the view; `report/sections/0[1-6]*.sql` and `report_html.sql` now
      only format, so the two drivers cannot drift. Text and HTML output are
      byte-identical to before on the fixture.
- [x] **M8.3 Jobs.** Done: `install_jobs.sql` / `uninstall_jobs.sql` (opt-in,
      repo root, not in `install.sql`) create `CAP_ML_RETRAIN` (weekly
      `cap_forecast_ml.train_all`; daily since M18.3) and `CAP_REPORT_SPOOL_JOB` (daily
      `cap_report_spool(p_dir)` → `UTL_FILE` snapshot of `CAPR_ALERTS` into a
      `report_dir` DEFINE, default `CAP_REPORTS`), both DISABLED and
      idempotent; jobs share the schema namespace with procedures, hence the
      `_JOB` suffix (ORA-27477).
- [x] **M8.4 `doctor.sql` preflight.** Done: read-only PASS/WARN/FAIL checklist
      in one exception-wrapped anonymous block — pack access, direct
      `DBA_HIST_*` reads, `SESSION_PRIVS`, AWR retention/interval per dbid,
      days of history per source vs `min_train_days`, invalid `CAP*` objects +
      detected seam mode, then a plain-English "why `INSUFFICIENT_HISTORY`".

## M9 — Forecast quality (Tier 1)

- [x] **M9.1 Prediction intervals.** Done: `REGR_SXX/SXY/SYY/AVGX` → residual
      SE → 95% bands (`proj_*_lo/hi`) + `days_to_full_lo/hi` /
      `days_to_sat_lo/hi` ranges on both CAPF views (t approximated as
      `1.96 + 2.4/df`, part of the contract). Reports show the range (1a/4
      WORST/BEST columns, section 2 +180 band, HTML RANGE columns + worst-case
      card line). `FIX_ZIGZAG` fixture asserts the closed forms; `FIX_LINEAR`
      asserts bands collapse at zero residuals.
- [x] **M9.2 Robust slope.** Done: Theil–Sen (median of the pairwise slopes
      `(y_j−y_i)/(x_j−x_i)` via a self-join on the training window, O(n²) ≈ 4k
      pairs at 90 days) computed alongside OLS in **both** `CAPF_TBSPC_FORECAST`
      and `CAPF_CPU_TREND`. Knob `slope_method` (CAP_CONFIG is numeric: `0` =
      OLS default, `1` = THEILSEN); both estimators are always exposed
      (`ols_slope_bpd` / `ts_slope_bpd`, `ols_slope_per_day` /
      `ts_slope_per_day`, plus `ts_icept`) and `slope_method` says which one the
      row used. When THEILSEN is selected it drives `slope_bpd`, `icept`, every
      `proj_*`, `days_to_full`/`days_to_sat`, both halves of `accel_ratio` and
      the `slope = 0` FLAT test; `r2` and the M9.1 bands (`proj_*_lo/hi`,
      `slope_ci_bpd`, `days_to_full_lo/hi`) stay OLS residual quantities drawn
      around the chosen line — there is no closed-form Theil–Sen interval in
      SQL. Fixtures: `FIX_LINEAR` (TS = 10 MiB/day exactly), `FIX_ZIGZAG` (TS =
      the median of all 4005 pairwise slopes, enumerated and sorted in the
      installer), `FIX_SPIKE` (TS within 1% of the true 5 MiB/day while OLS is
      3.9× off), plus a knob-flip test that switches to THEILSEN mid-run and
      back. Since M18.1 the Theil-Sen self-joins run only when
      `slope_method = 1` (the `ts_*` columns are NULL otherwise), and M18.2
      adds `slope_method = 2` (DRIFT).
- [x] **M9.3 Change-point reset.** Done: knobs `reset_on_shrink` (1) and
      `shrink_mad_k` (6). `CAPF_TBSPC_FORECAST` restarts the training window at
      the most recent day whose day-over-day delta is below
      `−GREATEST(shrink_mad_k·MAD_sigma(window deltas), abs_floor_bytes)` (MAD
      computed inline, two passes like ddl/40 but per series over the one
      window), so a post-purge series is fit only on post-purge data. The cliff
      day itself is day 1 of the new window (its `used_bytes` is already the
      post-purge level); new columns `train_start` / `reset_day` (NULL = no
      reset) make it visible, and a window left shorter than `min_train_days`
      honestly reads `INSUFFICIENT_HISTORY`. Fixture `FIX_PURGE` (10 MiB/day,
      −600 MiB at day 90, 10 MiB/day again) asserts `reset_day` = the cliff,
      `train_n` = 31, slope = 10 MiB/day exactly and days-to-full off the
      post-purge line; `FIX_SPIKE` (positive step), `FIX_LINEAR` and
      `FIX_ZIGZAG` assert `reset_day IS NULL`. Not applied to `CAPF_CPU_TREND`:
      a "shrink" is a tablespace event, and a CPU level shift is M10.3's job.
- [x] **M9.4 Backtest / holdout accuracy.** Done: `CAPF_BACKTEST` (in
      `ddl/50_ml.sql`) scores each engine against the held-out last
      `backtest_holdout_days` (knob, 28): REGR recomputed in pure SQL (always
      available), ESM via `cap_forecast_ml.train_backtest` — purpose=BACKTEST
      twin models (CBT* names, new `CAP_ML_MODEL.purpose` column, exposed via
      `CAPF_ESM_BACKTEST`, never leak into `CAPF_ESM_FORECAST`/`CAPF_COMPARE`).
      Section 6c (text + HTML) shows MAPE/bias per engine + BETTER verdict.
      Feeds ESM model-type selection in M10.4.
- [x] **M9.5 Tablespace limit overrides / exclusions.** Done:
      `CAP_TBSPC_OVERRIDE (dbid, con_dbid, tablespace_name, limit_bytes,
      exclude_flag, note)` — the THIRD persisted table (created idempotently in
      `ddl/05_config.sql`, preserved by `00_drop`, dropped only by
      `uninstall.sql`). Autoextend `maxsize` is not real headroom when the
      filesystem / ASM DG is smaller, so a row replaces the computed limit;
      `exclude_flag='Y'` silences staging/scratch tablespaces entirely.
      Applied once in `CAPD_TBSPC_DAILY` (an `ores` CTE resolves the most
      specific of the matching rows — `dbid`/`con_dbid` `0` are wildcards — so
      the LEFT JOIN cannot fan out), which means forecasts, anomalies,
      `CAPR_ALERTS` and both reports honour it with no further code. New
      `limit_source` (`OVERRIDE`/`AUTOEXTEND`/`ALLOCATED`) rides through
      `CAPF_TBSPC_FORECAST`. Fixtures `FIX_OVERRIDE` (FIX_LINEAR's twin capped
      at 2 GiB: 4990 days-to-full becomes 74) and `FIX_EXCLUDED` (99% full,
      excluded via the wildcard row, must appear nowhere) assert it.

## M10 — CPU / capacity analysis

- [x] **M10.1 Peak, not average.** Done: `CAPD_CPU_DAILY` adds `busy_p95`,
      `busy_max`, `busy_peak_pct` (+ `peak_intervals`, `host_busy_sec`) from
      the per-snapshot OSSTAT deltas; peak window = intervals ending in
      `(peak_hour_from, peak_hour_to]` (knobs, default 8/18). `CAPF_CPU_TREND`
      fits `BUSY_P95` / `BUSY_PEAK` with `days_to_sat`; `CPU_SAT` alerts key
      off `BUSY_P95` unless `cpu_sat_on_p95 = 0`. Fixture now has two
      snapshots/day (06:00 night, 18:00 peak) with closed-form assertions.
- [x] **M10.2 DB CPU as % of core capacity.** Done: `CAPD_DBTIME_DAILY` adds
      `db_cpu_pct`, `db_cpu_p95_pct`, `db_cpu_max_pct`, `db_cpu_peak_pct`,
      `host_share_pct` (per-PDB share of host busy seconds); `CAPF_CPU_TREND`
      metrics `DB_CPU_PCT` / `DB_CPU_P95` with `days_to_sat`; new alert kind
      `DBCPU_SAT`. Since M17.2 the denominator is logical CPUs (`NUM_CPUS`),
      not cores.
- [x] **M10.3 Level-shift detection.** Done: `CAPA_CPU_SHIFT`
      (`ddl/40_anomaly_views.sql`) — per (dbid, con_dbid, metric ∈ `BUSY_PCT` /
      `BUSY_P95` / `DB_CPU_PCT`) the median of the last `shift_days` (7) days
      vs the median of the `shift_baseline_days` (28) before it,
      `shift_pct = recent_med - base_med` in percentage POINTS. `UP` needs
      `shift_pct > shift_min_pct` (15) AND a full recent window AND enough
      baseline AND the N-of-M rule (`n_above >= shift_days`: every recent day
      above `base_med + max(base_mad_sigma, cpu_min_mad_pct)`) — which is what
      stops one loud day from dragging a 7-day median into a "shift". `DOWN` is
      the mirror (INFO, not WARN). One row per series (current state) with every
      input exposed. New alert kind `CPU_SHIFT`, new `CAPR_CPU_SHIFTS` view,
      report section 5b (text + HTML). Gap days (M10.5) are excluded from both
      windows. Fixture: a SECOND container (FIXPDB1, con_dbid 42424243, time-
      model rows only) whose DB CPU is a 7-day 34..46% sawtooth — so both
      medians are exact closed forms — stepping +18 points for the last 7 days.
- [x] **M10.4 ESM tuning.** Done: `train_tablespaces` now picks the ESM model
      type per series. With `esm_tbspc_model = 2` (AUTO) and
      `esm_select_by_backtest = 1` (both new knobs, both defaults) it builds
      BOTH candidate M9.4 twins — `EXSM_HOLT` and `EXSM_ADDWINTERS(7)`, names
      now hashing the model type too — scores them in the new
      `CAPF_ESM_CANDIDATE` (one row per series per candidate) and trains
      production with the lower-MAPE one (ties / no evidence → HOLT). The
      decision rides on `CAP_ML_MODEL.model_type` / `chosen_by` / `mape_holt` /
      `mape_addw` and surfaces as `CAPR_ESM_COMPARE.esm_model` (6a/6b column
      `ESM_MODEL`) and `CAPR_BACKTEST.esm_pick` (6c column `ESM_PICK`, e.g.
      `ADDW H=2.90 W=1.20`). `esm_tbspc_model = 0|1` pins a type and skips the
      twins. Quality gate: tablespaces (`CAPF_TBSPC_FORECAST`) and CPU
      (`CAPF_CPU_TREND`) are trained only at `quality IN
      ('OK','LOW_CONFIDENCE')`, so FIX_FLAT / FIX_NEARFULL get no model.
      `CAPF_COMPARE` / `CAPF_BACKTEST` stay backward compatible (a `model_type`
      column added; `CAPF_BACKTEST`'s ESM row is the SELECTED candidate, so it
      is still one row per series per engine). Stale twins are purged per
      series on retrain and `drop_all` gained an orphan sweep over the six
      `<prefix>_<16 hex>` model names.
- [x] **M10.5 CPU gap handling.** Done: `CAPD_CPU_DAILY` and
      `CAPD_DBTIME_DAILY` now expose `max_interval_hours`, `gap_flag` (`'Y'`
      when any interval of the day is longer than the new `cpu_gap_hours` knob,
      default 12) and `day_gap`, mirroring `CAPD_TBSPC_DELTA`. The day is KEPT
      in the series, but `busy_p95` / `busy_max` / `busy_peak_pct` (and the
      `db_cpu_*` twins) are computed only from intervals `<= cpu_gap_hours`, so
      a 36 h average can never pose as a peak hour; `CAPA_CPU_ANOM` neither
      scores a gap day nor lets it into a same-weekday baseline, and
      `CAPA_CPU_SHIFT` skips them too. Default is 12 h rather than something
      tighter because the flag SUPPRESSES scoring — an over-sensitive value
      would silence the CPU anomaly layer wherever snapshot intervals are wide.
      Fixture: a pure AWR gap (a Sunday in day 70..80 whose two snapshots carry
      no OSSTAT/time-model rows) makes the next 06:00 interval span 36 h; that
      day reads 30% busy against a 40% Monday baseline (10 points over a
      9-point threshold) and must stay unflagged purely because of the guard.

## M11 — New series with fixed ceilings (cheap, high value)

All three landed as ONE generic pair of views keyed by a `series` name --
`CAPD_SERIES_DAILY (dbid, con_dbid, series, day_dt, value, limit_value, unit,
n_samples)` in the new `ddl/25_series_daily.sql` and `CAPF_SERIES_FORECAST` in
the new `ddl/35_series_forecast.sql` -- so a fourth series costs a UNION ALL
branch and nothing else. Shared plumbing: new knob `series_sat_pct` (90), new
alert kinds `SERIES_LIMIT` / `SERIES_NEARLIMIT`, new `CAPR_SERIES` report view,
new report section 7 (text + HTML), new fixture tables
`CAP_FIXTURE_RESOURCE_LIMIT` / `CAP_FIXTURE_SYSSTAT`.

- [x] **M11.1 Processes / sessions.** Done: `CAPV_RESOURCE_LIMIT` in all three
      seams over `DBA_HIST_RESOURCE_LIMIT` filtered to `processes`/`sessions`
      (verified on 19c: that view DOES carry `CON_DBID`; `LIMIT_VALUE` is a
      `VARCHAR2(10)` that can read `UNLIMITED`, converted to NUMBER in the seam,
      non-numeric → NULL = no ceiling). Daily value = the day's
      `MAX(max_utilization)` per instance, SUMMED across instances, against the
      summed per-instance limits (NULL if any instance is UNLIMITED).
      `days_to_limit = FLOOR((limit·series_sat_pct/100 − cur)/slope)`, with the
      M9.1 lo/hi range. Fixture `SESSIONS` 200+2·i of 500 → 5 days → a
      `SERIES_LIMIT` CRIT; `PROCESSES` constant 150 of 300 → FLAT, silent.
      **Warehouse TODO:** the sibling `awr-fleet-warehouse` has no
      `awrw_resource_limit` fact / `awrv_resource_limit` view yet, so
      `ddl/11_seam_warehouse.sql` emits the column contract with `WHERE 1 = 0`
      (zero rows, everything downstream stays valid). Add the collector pull +
      fact + AWRV view there, then swap the stub for a pass-through.
- [x] **M11.2 Redo GB/day.** Done: `CAPV_SYSSTAT` (local: `DBA_HIST_SYSSTAT`
      filtered to `redo size`; warehouse: `awrv_sysstat`, which the collector
      already gathers whole, with `con_dbid := dbid` — right for redo, one
      stream per database). Same diff-and-restart-guard as `CAPD_CPU_DAILY`,
      summed per day, /2^30. No ceiling, so `days_to_limit` is NULL and it can
      never alert — it is a trend for FRA / archive sizing. Fixture: +1 GiB per
      12 h interval, reset at the same restart as the CPU counters → exactly
      2.0 GiB/day, restart day dropped.
- [x] **M11.3 Total DB size.** Done: `SUM(used_bytes)` vs `SUM(limit_bytes)`
      over `CAPD_TBSPC_DAILY` per (dbid, con_dbid, day) — so it needs no new
      seam, and it inherits that view's rules (UNDO/TEMPORARY excluded, M9.5
      overrides + exclusions applied). Fixture asserts the identity against a
      re-derived sum plus a positive, fittable slope.

## M12 — Optional ELK / Kibana path (done)

- [x] **M12.1 Export.** `elk/export_capacity.sql` emits one JSON document per
      line (observation / forecast / fit / anomaly / alert) from the CAPD_/
      CAPF_/CAPA_/CAPR_ views; `elk/export.sh` runs it on the DB host and
      validates every document against the strict mapping in
      `elk/elasticsearch/index-template.json` before Filebeat sees it.
- [x] **M12.2 Transport.** Filebeat input (`elk/filebeat/awrcap.yml`) and a
      Logstash branch (`elk/logstash/oracle_capacity.conf`) loaded beside
      `elk_db_automation`'s Oracle pipeline; deterministic `_id`s so a
      re-export overwrites. No Elasticsearch access from the DB host.
- [x] **M12.3 Dashboards.** Three generated Lens dashboards
      (`elk/kibana/build_*.py`, imported by `elk/setup.sh`): tablespaces,
      CPU + workload series, fleet anomalies. Anomalies as red bars/markers
      on every chart; alerts as a table on every board.
- [ ] **M12.4 Scheduling.** A daily `export.sh` run (cron or an external
      DBMS_SCHEDULER job) is still a manual step; so is keeping Filebeat up
      across reboots (by `elk_db_automation` design).

## M13 — Optional Grafana path straight from Oracle (ORDS) (done)

- [x] **M13.1 Point feeds.** `CAPR_SERIES_POINTS`, `CAPR_FIT`, `CAPR_ANOMALIES`
      (ddl/45) and `CAPR_FORECAST_POINTS` (ddl/55): one chartable shape per
      record type, shared by `elk/export_capacity.sql` and the ORDS module;
      asserted in `test/run_test.sql`.
- [x] **M13.2 ORDS module.** `grafana/ords/awrcap_module.sql` publishes six
      GET endpoints (`grafana/API.md`), no pagination, `from`/`to` bound
      explicitly; lab install with a dedicated installer user and ORDS in
      Docker in `grafana/ords/README.md`.
- [x] **M13.3 Dashboards.** Three generated Grafana boards
      (`grafana/build_*.py`, provisioned by `grafana/docker-compose.yml`
      with the Infinity plugin); anomalies as annotations, red points and
      shaded shift spans.
- [ ] **M13.4 Follow-ups.** Multi-value `db`/`series` filters server-side;
      a result cache or materialized views under the point feeds for large
      sites; ORDS privilege on the module for untrusted networks.

## M14 — Optional Oracle APEX application (done)

- [x] **M14.1 Generator.** `apex/build.py` (stdlib) emits `apex/awrcap_app.sql`,
      an APEX 26.2 export in the native import API with deterministic ids;
      one registry maps each CAPR point feed to an `AWRCAP_*` collection and
      to the CTE every region query starts from.
- [x] **M14.2 Pages.** Overview (alert counts, alert list, worst days to
      full, DB size, data freshness), Tablespaces, CPU and workload, Fleet
      anomalies; global filter bar (database, tablespace, date range, kind,
      severity) and a Refresh-data button; views loaded once per session.
- [x] **M14.3 Install.** `apex/install.sql` (workspace, schema, app id
      arguments, refuses a foreign app id), `apex/workspace.sql` (workspace
      + ADMIN + viewer accounts, passwords prompted), `apex/publish.sh` (lab),
      `apex/test/apex_smoke.sql` (every region query inside a scripted APEX
      session).
- [ ] **M14.4 Follow-ups.** Collections hold whole views (fine for one
      database); multi-select filters. The results layer and alert
      acknowledgement now exist (M19.3) but the app does not read
      `CAPR_ALERTS_LATEST` or call `cap_results.ack` yet.

## M15 — Anomaly baseline modes (done)

Every anomaly series is scored against each baseline MODE of its grain, as rows
of one engine: TRAILING (the last `mad_window_days`) and SAME_DOW (the same
weekday, `dow_weeks` back) per day, HOUR_OF_WEEK (the same weekday and hour)
per CPU hour. A mode is a reference-set selector, nothing more; the floor,
z-score and flag rule are shared.

- [x] **M15.1 Engine + registry.** `CAPA_OBS` (ddl/40) is the registry of what
      is scored and how: kind, series, grain, unit, scored value vs raw value,
      gap and `is_complete` flags, the per-(unit, grain) threshold floor and
      the family's alert bitmask. `CAPA_ANOM` scores every observation against
      every mode of its grain (key `dbid, con_dbid, kind, series,
      baseline_mode, ts`; `2 x DAY obs + HOUR obs` rows); `CAPA_ANOM_DAY` rolls
      the day modes up to one row per observation. `CAPA_TBSPC_ANOM` and
      `CAPA_CPU_ANOM` are deleted. Knobs: `trailing_min_hist` /
      `weekly_min_hist` replace `tbspc_min_hist` / `cpu_min_dow_hist` (value
      carried over), new `cpu_min_mad_pct_hour`, `hour_gap_ratio`,
      `series_floor_count`, `series_floor_gib` and the bitmasks
      `alert_modes_tbspc` / `_cpu` / `_series` (1 = TRAILING, 2 = SAME_DOW,
      4 = HOUR_OF_WEEK), all in `CAP_CFG` and `CAP_CFG_CHECK`.
- [x] **M15.2 Hourly source.** `CAPD_CPU_INTERVAL` / `CAPD_DBTIME_INTERVAL`
      (one row per valid snapshot interval; the daily CPU views are GROUP BYs
      over them, byte-identical) and `CAPD_CPU_HOURLY` (host `BUSY_PCT` and
      per-container `DB_CPU_PCT` per END-hour bucket, 5 min flush grace;
      `gap_flag` from `hour_gap_ratio`).
- [x] **M15.3 More series scored.** Per-container `DB_CPU_PCT`
      (`DBCPU_BUSY` / `DBCPU_ANOM`) and the M11 series: `PROCESSES`,
      `SESSIONS`, `REDO_GB_DAY` on their level, `DB_SIZE_GB` on its daily
      growth (`SERIES_LEVEL` / `SERIES_GROWTH` / `SERIES_ANOM`).
      `CAPD_SERIES_DAILY` gains `day_gap`, `max_interval_hours`, `gap_flag`
      (REDO over `cpu_gap_hours`; DB_SIZE_GB when the tablespace set changed).
- [x] **M15.4 Consumer migration.** `CAPR_ANOMALIES` owns severity, message
      and `alerting` and gains `baseline_mode`, `grain`, `n_hist`,
      `alert_kind`, `raw_value`, `doc_key`; `CAPR_ALERTS` takes its anomaly
      rows from it in one branch (+ `baseline_mode`, `alert_key`; an
      HOUR_OF_WEEK day carries its worst hour). `CAPR_TBSPC_ANOMALIES` /
      `CAPR_CPU_ANOMALIES` carry the mode (`busy_pct` renamed `value_pct`);
      new `CAPR_SERIES_ANOMALIES` (section 7b) and `CAPR_HOURLY_POINTS`;
      `CAPR_SERIES_POINTS` stays 1:1 through `CAPA_ANOM_DAY` (headline mode)
      and gains `anomaly_modes`, `how_hours_flagged`, `doc_key`. The text and
      HTML reports and both drill scripts show the mode.
- [x] **M15.5 ELK / ORDS / Grafana.** Strict-mapping fields for
      `baseline_mode`, `grain`, `n_hist`, `raw_value`, `anomaly_modes`,
      `alerting`, `hours_flagged`; anomaly and alert doc ids keyed on the
      mode; an hourly ORDS endpoint over `CAPR_HOURLY_POINTS`; a mode filter
      on the fleet anomaly boards. Timestamps are the DB wall clock labelled
      `Z`; the dashboards run in UTC.
- [x] **M15.6 Tests.** The fixture gains `INVERTED_WED` (40% / 40%: invisible
      to the day modes, HOUR_OF_WEEK 06:00 HIGH and 18:00 LOW). Every
      `run_test.sql` anomaly lookup names the full key (`anom_flag` /
      `anom_n`); new mode closed forms, key-uniqueness checks and knob
      flips. `test/lint_anom_joins.sh` rejects any
      `CAPA_ANOM` read outside ddl/40, ddl/45, test/, bench/ and the drill
      scripts; `test/dbmint_harness.sh` runs it first. Parity gate before the
      legacy views were deleted: `CAPA_TBSPC_ANOM` vs TRAILING (1068 rows) and
      `CAPA_CPU_ANOM` vs SAME_DOW `BUSY_PCT` (112 rows), zero differences
      apart from rows the legacy views omitted (`n_hist` 0) and `robust_z` on
      flat tablespace baselines (finite now).
- [ ] **M15.7 Follow-ups.** Hourly observation docs are not exported to ELK
      (`CAPR_HOURLY_POINTS` is ORDS-only). Warehouse mode has no per-source
      timezone, so a fleet spanning timezones compares wall clocks. Done
      since: shift suppression and episode collapsing in `CAPR_ALERTS`
      (M19.3), `docs/demo/` regenerated (M21.4).

## M16 — Config access and install hygiene (done)

The 2026-10-17 review program (M16–M21) implemented every finding of a
whole-repo review, one unit per commit, each verified on 19c with the
fixture harness and both reports.

- [x] **M16.1 One config access path.** `CAP_CFG` (one row, one NUMBER
      column per knob, no defaults inlined) replaces the 14 pasted `cfg`
      CTEs in ddl/20..55, the report drivers and the drill scripts.
      `CAP_CONFIG.cfg_default`; the seed MERGE inserts missing keys and
      refreshes only `cfg_default` / `cfg_desc`; reset is `UPDATE ... SET
      cfg_value = cfg_default`. `CAP_CFG_CHECK` reports each knob OK /
      MISSING / BAD with its range rule. (8b57bc8)
- [x] **M16.2 Schema-aware install, uninstall and doctor.** `install.sql`
      prints the target schema, warns on SYS, recompiles INVALID `CAP*`
      objects in two passes and checks `ALL_OBJECTS` on `CURRENT_SCHEMA`;
      `WHENEVER SQLERROR EXIT FAILURE`. `suite_version` is the one MERGE row
      overwritten on every install. New `create_owner.sql` (dedicated owner
      with direct DBA_HIST_* grants). `doctor.sql`: all DBA_HIST_* views the
      seam reads, direct grants, `STATISTICS_LEVEL`, newest snapshot age, a
      readiness table, `CAP_CFG_CHECK`, `cap_doctor_mode` in and
      `cap_doctor_fail` out; `quickstart.sql` stops on a FAIL unless
      `force_install = Y`. Drivers create `reports/` before spooling.
      (abe891b)

## M17 — Seam and daily layer (done)

- [x] **M17.1 Per-container sources.** In CDB$ROOT the SYS_ time model and
      sysstat are CDB-wide, so `CAPV_TIME_MODEL` / `CAPV_SYSSTAT` read
      `DBA_HIST_CON_SYS_TIME_MODEL` / `DBA_HIST_CON_SYSSTAT` (PDB$SEED
      dropped, SYS_ fallback for a non-CDB). `CAPV_RESOURCE_LIMIT` documented
      as root-only. New `CAPV_CONTRACT` diagnostic in all three seams.
      (82e8a42)
- [x] **M17.2 One counter-delta view and the logical-CPU denominator.**
      `CAPD_COUNTER_DELTA` holds the LAG + restart rule once for OSSTAT, time
      model and sysstat. `db_cpu_pct` and its twins divide by `NUM_CPUS x
      ivl_sec` per interval (cores read 2x on SMT); the fixture host is
      NUM_CPUS 8 / cores 4. (82e8a42)
- [x] **M17.3 Day coverage.** `covered_sec` / `is_complete` on the CPU, DB
      time and series daily views (knob `complete_day_pct` 80); a fixture
      partial day. (82e8a42)

## M18 — Forecasts (done)

- [x] **M18.1 Anchored, clamped, current.** Projections are `cur_value +
      slope x h` with the OLS half-widths around that anchor (+30 and
      days_to_full agree); days_to_full clamps at 0 and `limit_below_used`
      flags a ceiling under usage; `newest_day` / `is_current` on every CAPF
      view (knob `stale_days` 3); CPU and REDO fit complete days only;
      Theil-Sen on demand; drill footers on `train_start`. Fixtures
      `FIX_OVERFULL`, `FIX_DROPPED`. (4eb8e9e)
- [x] **M18.2 CYCLIC, DRIFT, CPU gate, hot now.** `cyclic_min_cliffs` (2)
      grades a sawtooth tablespace CYCLIC, judged on its peaks; `slope_method
      = 2` (DRIFT) with random-walk bands; `cpu_quality_gate` and
      `cpu_deseason` (both on by default: a deliberate default change) with
      `slope_sig` / `deseasoned`; the CPU anchor is the median of the last
      `shift_days` complete days; `recent_p95_med` / `hot_now`. Fixtures
      `FIX_CYCLIC`, `FIX_CYCLIC_UP`, `FIXPDB2`. The demo SESSION_STORE false
      page is gone. (0e63b84)
- [x] **M18.3 Tier 2 that shows up and fails loudly.** The ESM row of
      `CAPF_COMPARE` is the model's furthest step (<= 30, `esm_horizon_days`)
      and counts while `model_age_days <= esm_max_age_days` (7); builds use
      a temp name and `RENAME_MODEL`, a failure keeps the old model and
      records FAILED / `last_error`, `train_*` raise ORA-20060 after the
      batch; `CAPF_ESM_HEALTH` / `_SUMMARY`; `train_all` refreshes the
      backtest twins (CPU too); `train_tablespace(name)`; AUTO ties within
      `esm_auto_tie_pct` keep HOLT; `CAP_ML_RETRAIN` daily by default.
      (6e4a045)

## M19 — Alerts and results layer (done)

- [x] **M19.1 How much more than usual.** Anomaly rows carry
      `pct_vs_median` / `pct_vs_avg` (and the trailing average rate for
      tablespaces); the alert messages say "+N% vs ..." next to the z-score.
      (08cdb95)
- [x] **M19.2 One alert surface.** `CAPR_ALERTS` (moved to ddl/55) gains
      `state_key`, `direction`, `alarm_threshold`, `is_current`;
      `CAPR_SEVERITY` computes every forecast severity once (section 1a GATE
      column); forecast kinds need `is_current = 'Y'`; TBSPC_FULL on the peak
      line of a CYCLIC tablespace; new kinds DATA_STALE (`stale_hours`),
      CPU_HOT / DBCPU_HOT and MODEL_HEALTH; per-tablespace thresholds in
      `CAP_TBSPC_OVERRIDE`; each fit view read once. (c96e6a5)
- [x] **M19.3 Results layer.** ddl/60: `CAP_RUN`, `CAP_FIT_HIST`,
      `CAP_ALERT_STATE`, `CAP_ALERT_EVENT` (persisted like `CAP_CONFIG`) and
      `cap_results` (refresh / ack / unack / purge / reset), the only writer;
      `CAPR_ALERTS_LATEST`, `CAPR_ALERT_EVENTS`, `CAPR_RUNS`,
      `CAPR_FIT_HISTORY`, `CAPR_WEEKLY_DIGEST`, `CAPR_FORECAST_ACCURACY`,
      `CAPR_COVERAGE`; anomaly episodes and shift suppression in
      `CAPR_ALERTS`; retired dbids (`data_stale_max_days`);
      `CAP_REFRESH_JOB`. Knobs `resolve_grace_runs`, `refresh_stale_hours`,
      `digest_days`. (d451151)

## M20 — Seam extensions (done)

- [x] **M20.1 Parameters and ASM.** `CAPV_PARAMETER` (nine init
      parameters as numbers, root rows) and `CAPV_ASM_DISKGROUP`; zero-row
      stubs in warehouse mode and when the demo fixture lacks the tables.
      `db_cpu_pct` divides by `LEAST(num_cpus, cpu_count)`. (10eee46)
- [x] **M20.2 New series.** `ASM_DG:+<group>`, `TEMP_PEAK:<ts>`,
      `UNDO_PEAK:<ts>` through the generic series model; FRA days on
      `REDO_GB_DAY`; the sizing ask `need_gib_30/90/180` and `add_by_day`.
      Fixtures `FIX_TEMP`, `FIX_UNDO`, `CAP_FIXTURE_PARAMETER`,
      `CAP_FIXTURE_ASM_DISKGROUP`. (10eee46)

## M21 — Consumers (done)

- [x] **M21.1 Scoped and snapshot reports.** Both drivers take `[dbid]
      [con_dbid] [LIVE|SNAPSHOT]` after the three presentation arguments,
      `-` skips one; SNAPSHOT reads the last refresh run. New
      `report/report_csv.sql` and `report/run_report.sh` (cron, exit codes).
      (55e496c)
- [x] **M21.2 Resilient HTML.** Every section in its own exception block;
      the hero reads the suite's `DB_SIZE_GB` fit, so it matches section 7.
      (55e496c)
- [x] **M21.3 Who is filling it, metrics, doctor.** `CAPV_SEG_STAT` +
      `CAPR_SEGMENT_GROWTH` (`seg_window_days`) in `drill_tbspc.sql`; the ORDS
      `metrics` handler (Prometheus text); doctor prints the results layer
      and the live `CAPV_CONTRACT` check. `suite_version` 16. (55e496c)
- [x] **M21.4 Docs.** README, CLAUDE.md, PLAN.md and the docs site describe
      M16–M21; `docs/demo/` regenerated from `test/demo_fixture.sql`;
      `test/docs_lint.sh` checks the knob table, the object index and the
      alert kinds against the DDL, and rejects assertion counts and
      "generated" claims. (branch rf/u10-docs)
- [ ] **M21.5 Follow-ups.** `suite_version` is 16 while the latest milestone
      is M21 (bump it with its `CAP_CFG_CHECK` rule). Tier 2 still trains on
      incomplete days (`is_complete` not applied in ml/, `CAPF_BACKTEST`
      input, `CAPF_ESM_CANDIDATE`, `CAPF_ESM_HEALTH`).
      `test/fixture_remove.sql` does not drop `CAP_FIXTURE_SEG_STAT`.
      `CAP_TBSPC_OVERRIDE` does not apply to the TEMP / UNDO peak series;
      PDB-level `cpu_count` is unused. ELK forecast doc ids hash
      `horizon_days`, which moves as an ESM model ages; ORDS / ELK do not
      select the new `CAPR_ALERTS` columns (`state_key`, `direction`,
      `alarm_threshold`, `is_current`). `CAPR_ALERTS` costs seconds per query
      on the fixture and the live demo reports take minutes: snapshot
      `CAPR_COVERAGE` per run, and consider a run_test snapshot of
      `CAPR_ALERTS`. The warehouse collector should gather the CON_ views,
      parameters, ASM and segment facts (sibling repo).

## v2 (unchanged)

- [ ] Memory forecasting (SGA/PGA from `DBA_HIST_MEM_DYNAMIC_COMP` (the
      19c view name) / `DBA_HIST_PGASTAT`).
- [ ] Cross-DBID series stitching (non-CDB → PDB migrations) keyed on a stable
      warehouse `target_id`.

---

Suggested order: M7.1–M7.3 + M8.1 (immediate user value) → M9.1 + M9.4 →
M10.1/M10.2 → M8.2 → rest.
