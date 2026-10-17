#!/usr/bin/env python3
"""Generate dashboards/awrcap-cpu-series.json (AWR capacity: CPU and workload series)."""
from dash_lib import (
    AMBER, DASHED, DB, DOTTED, GREEN, GREY, NO_LEGEND, PAST_120D, RANGE, RED,
    SOONEST, Board, alerts_table, keep, named, annotation, cell_bg, db_var, fixed, override, prop, q,
    red_points, sev_cell, steps, table, timeseries, where, width,
)

REGR = where("method == 'REGR'", DB)
LABEL = "${__field.labels.db} ${__field.name}"
DTF_STEPS = ((RED, None), (AMBER, 31), (GREEN, 91))

b = Board("awrcap-cpu-series", "AWR Capacity - CPU and workload series",
          "Host CPU against the 80 % saturation line, DB CPU per container with "
          "level shifts, and sessions / processes / size / redo against their "
          "limits, each with its forecast.",
          "now-120d", "now+120d")
b.variables.append(db_var())


FORECAST_STYLE = [
    override("byRegexp", named("forecast"), DASHED),
    override("byRegexp", named("low|high"), DOTTED, NO_LEGEND, prop("custom.lineWidth", 1)),
]

host = b.add(timeseries(
    "Host CPU busy %: observed, p95 forecast (dashed), anomalies (red)",
    [q("A", f"series?kind=CPU&series=BUSY_PCT&{RANGE}",
       ["ts", "db", ("busy_pct", "busy %"), ("busy_p95", "busy p95")],
       filt=DB)]
    + [q("B", "forecast?kind=CPU&series=BUSY_P95",
         ["ts", "db", "method", ("value", "forecast"), ("lo", "low"), ("hi", "high")], filt=REGR),
       q("C", f"series?kind=CPU&series=BUSY_PCT&{RANGE}",
         ["ts", "db", ("anomaly", "anomaly", "string"), ("value", "anomaly day")],
         filt=where("anomaly == '1'", DB))],
    unit="percent", display=LABEL, decimals=1, partition=("db",),
    thresholds=steps(("transparent", None), (RED, 80)),
    custom={"axisSoftMax": 100},
    overrides=FORECAST_STYLE + red_points("anomaly day"),
    description="Daily host busy % (average and busy-hour p95) from OSSTAT. Right of today: "
                "the REGR forecast of p95 with its band. Red dashed line: the 80 % saturation "
                "line. Red dots and markers: days the anomaly layer flagged against the same "
                "weekday's normal range."),
    0, 0, 14, 10)

dbcpu = b.add(timeseries(
    "DB CPU % of host per container (red region = level shift window)",
    [q("A", f"series?kind=CPU&series=DB_CPU_PCT&{RANGE}", ["ts", "db", ("value", "DB CPU %")],
       filt=DB)],
    unit="percent", display="${__field.labels.db}", decimals=1, time_from=PAST_120D,
    partition=("db",),
    description="Time-model DB CPU as a share of host CPU, per container. A red region marks "
                "a level shift: it starts where the recent window starts and ends on the day "
                "the shift was observed."),
    14, 0, 10, 10)


def trend_table(title, kind, value_label, dtf_label, with_limit, description=""):
    cols = [("db", "Database", [width(190)]), ("series", "Series", [width(150)]),
            ("sev", "Sev", sev_cell()),
            ("value", value_label, [prop("decimals", 1)])]
    if with_limit:
        cols += [("limit_value", "Limit", [prop("decimals", 0)]),
                 ("pct", "% of limit", cell_bg(((GREEN, None), (AMBER, 90), (RED, 97)),
                                               prop("unit", "percent"), prop("decimals", 1)))]
    cols += [("slope_per_day", "Slope / day", [prop("decimals", 3)]),
             ("days_to_full", dtf_label, cell_bg(DTF_STEPS, prop("decimals", 0))),
             ("days_to_full_lo", "low", [prop("decimals", 0)]),
             ("days_to_full_hi", "high", [prop("decimals", 0)]),
             ("r2", "R²", [prop("decimals", 2)]),
             ("quality", "Fit quality")]
    query_cols = {c[0] for c in cols} | {"limit_value"}
    cols.append(("soonest", "soonest"))
    return table(title, q("A", f"fit?kind={kind}", sorted(query_cols), filt=DB,
                          computed=[SOONEST]),
                 cols, sort="soonest", description=description,
                 hidden=("soonest",) if with_limit else ("soonest", "limit_value"))


b.add(trend_table("CPU trend (latest fit per metric, soonest saturation first)",
                  "CPU", "Current", "Days to 80 %", False,
                  "Linear fit per CPU metric; days until it crosses the 80 % line."),
      0, 10, 24, 7)

WORKLOAD = [
    ("SESSIONS", "Sessions vs limit", "none", 0),
    ("PROCESSES", "Processes vs limit", "none", 0),
    ("DB_SIZE_GB", "Database size", "gbytes", 1),
    ("REDO_GB_DAY", "Redo per day", "gbytes", 1),
]
workload_src = [
    q("A", f"series?kind=SERIES&{RANGE}",
      ["ts", "db", "series", ("value", "observed"), ("limit_value", "limit")], filt=DB),
    q("B", "forecast?kind=SERIES",
      ["ts", "db", "series", "method", ("value", "forecast"), ("lo", "low"), ("hi", "high")],
      filt=REGR),
]
for i, (series, title, unit, decimals) in enumerate(WORKLOAD):
    panel_id = b.add(timeseries(
        f"{title}, with forecast (dashed)", workload_src, unit=unit, display=LABEL,
        partition=("db",), transformations=[keep("series", series)], decimals=decimals,
        overrides=FORECAST_STYLE + [override("byRegexp", named("limit"), fixed(GREY), DASHED,
                                             prop("custom.lineWidth", 1))]),
        12 * (i % 2), 17 + 10 * (i // 2), 12, 10)
    workload_src = workload_src if isinstance(workload_src, int) else panel_id

b.add(trend_table("Workload series (latest fit, soonest limit first)",
                  "SERIES", "Current", "Days to limit", True),
      0, 37, 24, 9)

b.add(alerts_table("CPU and series alerts", where("kind != 'TBSPC'", DB)), 0, 46, 24, 8)

b.annotations += [
    annotation("Host CPU anomalies",
               q("Anno", f"anomalies?{RANGE}", ["ts", "db", "series", "anomaly_kind", "message"],
                 filt=where("anomaly_kind == 'CPU_BUSY'", DB)),
               RED, [host], tags="db"),
    annotation("DB CPU level shifts",
               q("Anno", f"anomalies?{RANGE}",
                 ["ts", "obs_day", "db", "series", "anomaly_kind", "message"],
                 filt=where("anomaly_kind == 'CPU_SHIFT'", DB)),
               RED, [dbcpu], time_end="obs_day", tags="db"),
]

b.write()
