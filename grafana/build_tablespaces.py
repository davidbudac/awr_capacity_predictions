#!/usr/bin/env python3
"""Generate dashboards/awrcap-tablespaces.json (AWR capacity: tablespaces)."""
from dash_lib import (
    AMBER, DB, DOTTED, DASHED, GREEN, GREY, NO_LEGEND, PAST_120D, RANGE,
    RED, SERIES, SOONEST, BLUE, Board, named, alerts_table, annotation, cell_bg, fixed, override,
    prop, q, query_var, db_var, red_points, sev_cell, stat, table, timeseries,
    keep, where, width,
)

FILT = where(DB, SERIES)
GROWTH = where("anomaly_kind == 'TBSPC_GROWTH'", FILT)
REGR = where("method == 'REGR'", FILT)
LABEL = "${__field.labels.db} ${__field.labels.series} ${__field.name}"

b = Board("awrcap-tablespaces", "AWR Capacity - Tablespaces",
          "Tablespace usage from AWR: observed daily, forecast to a year out, "
          "days to full, and the growth days the anomaly layer flagged.",
          "now-120d", "now+120d")
b.variables += [
    db_var(),
    query_var("series", "Tablespace", q(
        "V", "fit?kind=TBSPC", ["series", "db"], filt=DB,
        summarize="count(db)", by="series"), "series"),
]

fit = q("A", "fit?kind=TBSPC", [
    "db", "series", "sev", "sev_rank", "pct", "value", "limit_value",
    "slope_per_day", "days_to_full", "days_to_full_lo", "days_to_full_hi",
    "r2", "quality"], filt=FILT, computed=[SOONEST])
DTF_STEPS = ((RED, None), (AMBER, 31), (GREEN, 91))

fit_table = b.add(table(
    "Days to full (latest fit per tablespace, soonest first)", fit, [
        ("db", "Database", [width(190)]), ("series", "Tablespace", [width(190)]),
        ("sev", "Sev", sev_cell()),
        ("pct", "Used %", cell_bg(((GREEN, None), (AMBER, 90), (RED, 97)),
                                  prop("unit", "percent"), prop("decimals", 1))),
        ("value", "Used", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("limit_value", "Ceiling", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("slope_per_day", "Growth / day", [prop("unit", "bytes"), prop("decimals", 1)]),
        ("days_to_full", "Days to full", cell_bg(DTF_STEPS, prop("decimals", 0))),
        ("days_to_full_lo", "DTF low", [prop("decimals", 0)]),
        ("days_to_full_hi", "DTF high", [prop("decimals", 0)]),
        ("r2", "R²", [prop("decimals", 2)]),
        ("quality", "Fit quality"), ("sev_rank", "sev_rank"), ("soonest", "soonest")],
    sort="soonest", hidden=("sev_rank", "soonest"),
    description="Days to full is the linear fit projected at today's slope; low/high come "
                "from the forecast band. CRIT at 30 days or less, WARN at 90."),
    0, 4, 24, 9)

used = b.add(timeseries(
    "Used space: observed, forecast (dashed), anomalies (red)", [
        q("A", f"series?kind=TBSPC&{RANGE}",
          ["ts", "db", "series", ("value", "used"), ("limit_value", "ceiling")], filt=FILT),
        q("B", "forecast?kind=TBSPC",
          ["ts", "db", "series", "method", ("value", "forecast"), ("lo", "low"), ("hi", "high")],
          filt=REGR),
        q("C", f"series?kind=TBSPC&{RANGE}",
          ["ts", "db", "series", ("anomaly", "anomaly", "string"), ("value", "anomaly day")],
          filt=where("anomaly == '1'", FILT)),
    ],
    unit="bytes", display=LABEL, legend="right", partition=("db", "series"),
    overrides=[
        override("byRegexp", named("forecast"), DASHED),
        override("byRegexp", named("low|high"), DOTTED, NO_LEGEND, prop("custom.lineWidth", 1)),
        override("byRegexp", named("ceiling"), fixed(GREY), DASHED, NO_LEGEND,
                 prop("custom.lineWidth", 1)),
        *red_points("anomaly day"),
    ],
    description="Left of today: observed daily used bytes. Right of today: the REGR forecast "
                "(dashed) with its low/high band (dotted). Grey dashed: the ceiling (MAXBYTES "
                "or operator override). Red dots and red markers: growth anomalies; hover a "
                "marker for the explanation."),
    0, 13, 24, 12)

growth = b.add(timeseries(
    "Daily growth (sum of selected tablespaces; red = flagged day)", [
        q("A", f"series?kind=TBSPC&{RANGE}", ["ts", "db", "series", "anomaly", "delta_bytes"],
          filt=where("anomaly == 0", FILT), summarize="sum(delta_bytes)", by="ts",
          alias="Daily growth"),
        q("B", f"series?kind=TBSPC&{RANGE}", ["ts", "db", "series", "anomaly", "delta_bytes"],
          filt=where("anomaly == 1", FILT), summarize="sum(delta_bytes)", by="ts",
          alias="Anomalous growth"),
        q("C", f"series?kind=TBSPC&{RANGE}", ["ts", "db", "series", "expected"],
          filt=FILT, summarize="sum(expected)", by="ts", alias="Median daily growth"),
    ],
    unit="bytes", time_from=PAST_120D, custom={"axisSoftMin": None},
    overrides=[
        override("byFrameRefID", "A", fixed(BLUE), prop("custom.drawStyle", "bars"),
                 prop("custom.fillOpacity", 80), prop("custom.stacking", {"mode": "normal", "group": "g"})),
        override("byFrameRefID", "B", fixed(RED), prop("custom.drawStyle", "bars"),
                 prop("custom.fillOpacity", 100), prop("custom.stacking", {"mode": "normal", "group": "g"})),
        override("byFrameRefID", "C", fixed(GREY), prop("custom.lineWidth", 1)),
    ],
    description="Per-day growth summed over the selected tablespaces. A red bar is the growth "
                "of the tablespaces flagged that day; the grey line is the sum of their median "
                "daily growth, which the anomaly test measures against."),
    0, 25, 24, 8)

anomaly_table = b.add(table(
    "Growth anomalies (newest first)",
    q("A", f"anomalies?{RANGE}", ["ts", "db", "series", "anomaly_kind", "value",
                                   "expected", "z", "anomaly_flag", "sev", "sev_rank",
                                   "message"],
      filt=GROWTH), [
        ("ts", "Day", [width(110), prop("unit", "time:YYYY-MM-DD")]),
        ("db", "Database", [width(190)]), ("series", "Tablespace", [width(170)]),
        ("value", "Growth", [width(100), prop("unit", "bytes"), prop("decimals", 1)]),
        ("expected", "Expected", [width(100), prop("unit", "bytes"), prop("decimals", 1)]),
        ("z", "z", cell_bg(((GREEN, None), (AMBER, 3), (RED, 5)),
                           prop("decimals", 1), width(70))),
        ("anomaly_flag", "Flag", [width(60)]), ("sev", "Sev", sev_cell()),
        ("message", "What happened"), ("anomaly_kind", "anomaly_kind"),
        ("sev_rank", "sev_rank")],
    sort="ts", desc=True, hidden=("anomaly_kind", "sev_rank"), time_from=PAST_120D),
    0, 33, 24, 9)

b.add(stat("Tablespaces CRIT", fit_table, transformations=[keep("sev", "CRIT")],
           field="sev_rank", calc="count", color_steps=((GREEN, None), (RED, 1)),
           description="Latest fit says full in 30 days or less (or already past the near-full line)."),
      0, 0, 6, 4)
b.add(stat("Tablespaces WARN", fit_table, transformations=[keep("sev", "WARN")],
           field="sev_rank", calc="count", color_steps=((GREEN, None), (AMBER, 1))),
      6, 0, 6, 4)
b.add(stat("Growth anomalies in range", anomaly_table,
           field="sev_rank", calc="count", color_steps=((GREEN, None), (RED, 1)),
           description="Days whose growth was far outside the tablespace's own median rate (robust z-score)."),
      12, 0, 6, 4)
b.add(stat("Worst days to full", fit_table, field="days_to_full", calc="min",
           color_steps=DTF_STEPS, unit="suffix: d"),
      18, 0, 6, 4)

b.add(alerts_table("Tablespace alerts", where("kind == 'TBSPC'", DB)), 0, 42, 24, 8)

b.annotations.append(annotation(
    "Growth anomalies",
    q("Anno", f"anomalies?{RANGE}", ["ts", "db", "series", "anomaly_kind", "message"],
      filt=GROWTH),
    RED, [used, growth]))

b.write()
