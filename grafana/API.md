# ORDS endpoints for Grafana (route B contract)

Base URL: `http://<ords-host>:8080/ords/<alias>/awrcap/` where `<alias>` is the
ORDS URL mapping of the schema that holds the suite (`capdemo` in the lab).
Every handler is `GET`, returns ORDS' standard collection envelope
`{"items":[...], "hasMore":false, "limit":..., "offset":..., "count":...}`,
and is NOT paginated (every matching row in one response). The analytics are
daily-grain except `hourly` and the `HOUR_OF_WEEK` rows of `anomalies`, which
are hour-grain; all are small enough to ship whole. Column names are
lowercase. Nulls are JSON null.

Timestamps are ISO-8601 strings `YYYY-MM-DDTHH:MI:SSZ` holding the
database's wall clock: AWR days and hours are local DATEs, and the `Z` is a
label, not a conversion to UTC. The boards run with `timezone: utc`, so they
display the DB clock unshifted; a client in another zone must do the same, or
every point moves by its offset. `from`/`to` are compared against that clock
the same way.

| Endpoint | Query params | Columns | Backing view |
|---|---|---|---|
| `containers` | none | `dbid, con_dbid, db_name, con_name, db` | `CAPR_CONTAINER` |
| `series?kind=&db=&series=&from=&to=` | kind required (TBSPC/CPU/SERIES); db (= `db` label) and series optional; from/to ISO date-times, default last 120 days | `ts, kind, series, db, con_dbid, value, limit_value, pct, unit, anomaly (0/1; null on unscored series), anomaly_flag, z, expected, threshold, gap (0/1)` plus kind extras: TBSPC `used_bytes, size_bytes, limit_bytes, delta_bytes, rate_bpd`; CPU `busy_pct, busy_p95, busy_peak_pct` on series BUSY_PCT; then `anomaly_modes` (the baseline modes that flagged the day, comma-separated, e.g. `TRAILING,SAME_DOW`), `how_hours_flagged` (HOUR_OF_WEEK hours flagged that day; BUSY_PCT and DB_CPU_PCT only) | `CAPR_SERIES_POINTS` (ddl/45) |
| `hourly?db=&series=&from=&to=` | all optional; series BUSY_PCT or DB_CPU_PCT; from/to taken as given (no day rounding), default last 14 days | `ts (end of the hour bucket), kind (CPU), series, db, con_dbid, day_dt, dow (0 = Monday), hour_of_day (end hour), unit (pct), value, gap (0/1), ivl_hours, n_intervals, anomaly (0/1), how_expected, how_threshold, how_z, how_flag (HIGH/LOW), how_n_hist` (`how_*` null when the hour was not scored) | `CAPR_HOURLY_POINTS` (ddl/45) |
| `forecast?kind=&db=&series=` | kind required; others optional | `ts, kind, series, db, con_dbid, method (REGR/ESM), horizon_days, value, lo, hi, limit_value, pct, quality` | `CAPR_FORECAST_POINTS` (new, ddl/55; needs CAPF_COMPARE) |
| `fit?kind=&db=` | kind optional (all kinds when absent) | `kind, series, db, con_dbid, unit, method, value, limit_value, pct, slope_per_day, r2, quality, days_to_full, days_to_full_lo, days_to_full_hi, accel, train_n, sev (CRIT/WARN/OK), sev_rank, limit_source, last_day` | `CAPR_FIT` (new, ddl/45) |
| `anomalies?from=&to=&db=&kind=&mode=` | all optional; mode = a baseline_mode; from/to default last 120 days | `ts, kind, series, db, con_dbid, anomaly_kind, anomaly_flag (HIGH/LOW/UP/DOWN), value, expected, threshold, z, shift_pct, unit (bytes_per_day/pct/count/gib_per_day), sev (WARN/INFO), sev_rank, message, obs_day, baseline_mode, grain (DAY/HOUR), n_hist, alerting (Y/N), raw_value` | `CAPR_ANOMALIES` (ddl/45) |
| `alerts?db=` | optional | `sev, sev_rank, alert_kind, kind, series, db, con_dbid, obs_day, value, threshold, unit, message, baseline_mode, alert_key` | `CAPR_ALERTS` |

Enumerations:

- `anomaly_kind`: `TBSPC_GROWTH` (tablespace growth rate), `CPU_BUSY` (host
  BUSY_PCT), `DBCPU_BUSY` (container DB_CPU_PCT), `SERIES_LEVEL` (sessions,
  processes, redo per day), `SERIES_GROWTH` (database size growth),
  `CPU_SHIFT` (a sustained level shift).
- `baseline_mode`: `TRAILING` (the last `mad_window_days` days, DAY grain),
  `SAME_DOW` (the same weekday over the last `dow_weeks` weeks, DAY grain),
  `HOUR_OF_WEEK` (the same weekday and end hour, HOUR grain); null for
  `CPU_SHIFT` and for every non-anomaly alert.
- `alert_kind`: `TBSPC_FULL`, `TBSPC_NEARFULL`, `TBSPC_ANOM`, `CPU_SAT`,
  `DBCPU_SAT`, `CPU_ANOM`, `DBCPU_ANOM`, `CPU_SHIFT`, `SERIES_LIMIT`,
  `SERIES_NEARLIMIT`, `SERIES_ANOM`. The `*_ANOM` kinds carry one row per
  series, day and baseline mode; `alert_key` is unique per row. CPU rows of
  `series`, `forecast` and `fit` share one limit convention: `limit_value` is
  the saturation line `cpu_sat_pct` (not 100) and `pct` is `value` as a
  percent of it, and `CAPR_ALERTS` (the view behind `alerts`) now also has
  the kinds `CPU_HOT`, `DBCPU_HOT`, `DATA_STALE`, `MODEL_HEALTH` and the
  columns `state_key` (stable across days), `direction` (LE/GE/ABS),
  `alarm_threshold` (the WARN level) and `is_current`, which the ORDS handler
  does not select yet.

Semantics are the same as the ELK records (see `elk/README.md`): `series`
rows are the observed daily points with the CAPA_* flag joined on
(`anomaly=1` on a flagged day); `forecast` rows are the REGR anchors at
horizons 0/30/90/180/365 (TBSPC) or 0/30/90 (CPU, SERIES) and the ESM +30
point, `ts` = last observed day + horizon; `fit` is one row per series with
the latest fit; `anomalies` carries one row per flagged event and baseline
mode (a day flagged by TRAILING and SAME_DOW is two rows; an HOUR_OF_WEEK row
is one hour, `ts` at the end of the hour, `obs_day` its day), a level shift
dated at the start of its recent window with the window end in `obs_day`.
On `anomalies`, `value` is the scored value (TBSPC: the growth rate in
bytes/day, so `unit` is `bytes_per_day`; `raw_value` is the day's raw delta in
bytes), `expected` the baseline median and `threshold` the allowed deviation,
so the crossed bound is `expected ± threshold`. `alerting = Y` marks the rows
`alerts` pages on. `hourly` rows are the CPU hour buckets each HOUR_OF_WEEK
verdict is computed from, one per container, metric and end hour.

The new CAPR_* views are suite objects (read-only SELECTs over the existing
layers, 19c syntax, no DBA_HIST_* references) and are what `elk/export_capacity.sql`
should select from too, so both paths share one definition.

Grafana reads these with the Infinity data source (JSON, root selector
`items`), passing `${__from:date:iso}` / `${__to:date:iso}` and dashboard
variables `$db`, `$series` into the query string.
