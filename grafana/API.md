# ORDS endpoints for Grafana (route B contract)

Base URL: `http://<ords-host>:8080/ords/<alias>/awrcap/` where `<alias>` is the
ORDS URL mapping of the schema that holds the suite (`capdemo` in the lab).
Every handler is `GET`, returns ORDS' standard collection envelope
`{"items":[...], "hasMore":false, "limit":..., "offset":..., "count":...}`,
and is NOT paginated (every matching row in one response; the suite's
analytics are daily-grain and small). Timestamps are ISO-8601 UTC strings
`YYYY-MM-DDTHH:MI:SSZ`. Column names are lowercase. Nulls are JSON null.

| Endpoint | Query params | Columns | Backing view |
|---|---|---|---|
| `containers` | none | `dbid, con_dbid, db_name, con_name, db` | `CAPR_CONTAINER` |
| `series?kind=&db=&series=&from=&to=` | kind required (TBSPC/CPU/SERIES); db (= `db` label) and series optional; from/to ISO date-times, default last 120 days | `ts, kind, series, db, con_dbid, value, limit_value, pct, unit, anomaly (0/1), anomaly_flag, z, expected, threshold, gap (0/1)` plus kind extras: TBSPC `used_bytes, size_bytes, limit_bytes, delta_bytes, rate_bpd`; CPU `busy_pct, busy_p95, busy_peak_pct` on series BUSY_PCT | `CAPR_SERIES_POINTS` (new, ddl/45) |
| `forecast?kind=&db=&series=` | kind required; others optional | `ts, kind, series, db, con_dbid, method (REGR/ESM), horizon_days, value, lo, hi, limit_value, pct, quality` | `CAPR_FORECAST_POINTS` (new, ddl/55; needs CAPF_COMPARE) |
| `fit?kind=&db=` | kind optional (all kinds when absent) | `kind, series, db, con_dbid, unit, method, value, limit_value, pct, slope_per_day, r2, quality, days_to_full, days_to_full_lo, days_to_full_hi, accel, train_n, sev (CRIT/WARN/OK), sev_rank, limit_source, last_day` | `CAPR_FIT` (new, ddl/45) |
| `anomalies?from=&to=&db=&kind=` | all optional; from/to default last 120 days | `ts, kind, series, db, con_dbid, anomaly_kind (TBSPC_GROWTH/CPU_BUSY/CPU_SHIFT), anomaly_flag (HIGH/LOW/UP/DOWN), value, expected, threshold, z, shift_pct, unit, sev (CRIT/WARN/INFO), sev_rank, message, obs_day` | `CAPR_ANOMALIES` (new, ddl/45) |
| `alerts?db=` | optional | `sev, sev_rank, alert_kind, kind, series, db, con_dbid, obs_day, value, threshold, unit, message` | `CAPR_ALERTS` |

Semantics are the same as the ELK records (see `elk/README.md`): `series`
rows are the observed daily points with the CAPA_* flag joined on
(`anomaly=1` on a flagged day); `forecast` rows are the REGR anchors at
horizons 0/30/90/180/365 (TBSPC) or 0/30/90 (CPU, SERIES) and the ESM +30
point, `ts` = last observed day + horizon; `fit` is one row per series with
the latest fit; `anomalies` carries one row per flagged event, a level shift
dated at the start of its recent window with the window end in `obs_day`.

The new CAPR_* views are suite objects (read-only SELECTs over the existing
layers, 19c syntax, no DBA_HIST_* references) and are what `elk/export_capacity.sql`
should select from too, so both paths share one definition.

Grafana reads these with the Infinity data source (JSON, root selector
`items`), passing `${__from:date:iso}` / `${__to:date:iso}` and dashboard
variables `$db`, `$series` into the query string.
