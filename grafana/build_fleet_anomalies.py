#!/usr/bin/env python3
"""Generate dashboards/awrcap-fleet-anomalies.json (AWR capacity: fleet anomalies)."""
from dash_lib import (
    AMBER, ANOMALY_KINDS, BASELINE_MODES, BLUE, DB, GREEN, GREY, RED, RANGE, Board,
    alerts_table, cell_bg, custom_var, data, db_var, fixed, keep, override, prop, q,
    sev_cell, stat, steps, table, timeseries, where, width,
)

MODE_COLORS = dict(zip(BASELINE_MODES, (RED, AMBER, BLUE)))
# A level shift has no baseline mode, so the mode filter lets it through.
FILT = where(DB, "anomaly_kind IN (${kind:singlequote})", "sev IN (${sev:singlequote})",
             "(anomaly_kind == 'CPU_SHIFT' || baseline_mode IN (${mode:singlequote}))")
ALARM = ((GREEN, None), (RED, 1))
WATCH = ((GREEN, None), (AMBER, 1))
COUNT = r"sev_rank \(count\)"


def count_by(*fields):
    """groupBy transformation: one row per distinct `fields`, counting sev_rank."""
    spec = {f: {"aggregations": [], "operation": "groupby"} for f in fields}
    spec["sev_rank"] = {"aggregations": ["count"], "operation": "aggregate"}
    return {"id": "groupBy", "options": {"fields": spec}}


b = Board("awrcap-fleet-anomalies", "AWR Capacity - Fleet anomalies",
          "Every anomaly the CAPA_* layer flagged, across every database the ORDS "
          "module serves and every baseline mode: tablespace growth, host and DB "
          "CPU, workload series outliers, and DB CPU level shifts.",
          "now-120d", "now")
b.variables += [
    db_var(),
    custom_var("kind", "Anomaly kind", ANOMALY_KINDS),
    custom_var("mode", "Baseline mode", BASELINE_MODES),
    custom_var("sev", "Severity", ["CRIT", "WARN", "INFO"]),
]

LINKS = [
    {"title": "Open tablespaces dashboard",
     "url": "/d/awrcap-tablespaces?var-db=${__data.fields.db}&var-series=${__data.fields.series}"},
    {"title": "Open CPU and series dashboard",
     "url": "/d/awrcap-cpu-series?var-db=${__data.fields.db}"},
]
# The query lives on the first panel: Grafana renders panels lazily, so a
# panel that reuses another's data only loads once that panel has scrolled
# into view. A y=0 stat is always visible.
anomalies = b.add(stat(
    "Anomalies in range",
    q("A", f"anomalies?{RANGE}", ["ts", "obs_day", "db", "series", "anomaly_kind",
                                   "baseline_mode", "sev", "sev_rank",
                                   "z", "anomaly_flag", "message"], filt=FILT),
    field="sev_rank", calc="count", color_steps=ALARM), 0, 0, 6, 4)
b.add(table(
    "Anomalies, newest first (click a database or series to drill in)", anomalies, [
        ("ts", "When", [width(140), prop("unit", "time:YYYY-MM-DD HH:mm")]),
        ("db", "Database", [width(190), prop("links", LINKS)]),
        ("series", "Series", [width(170), prop("links", LINKS)]),
        ("anomaly_kind", "Kind", [width(130)]),
        ("baseline_mode", "Mode", [width(120)]),
        ("sev", "Sev", sev_cell()),
        ("z", "z", cell_bg(((GREEN, None), (AMBER, 3), (RED, 5)),
                           prop("decimals", 1), width(70))),
        ("anomaly_flag", "Flag", [width(60)]),
        ("message", "What happened"), ("sev_rank", "sev_rank"),
        ("obs_day", "obs_day")],
    sort="ts", desc=True, hidden=("sev_rank", "obs_day")),
    0, 20, 24, 12)

b.add(stat("Databases affected", anomalies, transformations=[count_by("db")],
           field=COUNT, calc="count", color_steps=WATCH), 6, 0, 6, 4)
b.add(stat("Series affected", anomalies, transformations=[count_by("series")],
           field=COUNT, calc="count", color_steps=WATCH), 12, 0, 6, 4)
b.add(stat("WARN anomalies", anomalies, transformations=[keep("sev", "WARN")],
           field="sev_rank", calc="count", color_steps=WATCH), 18, 0, 6, 4)

b.add(timeseries(
    "Anomalies per day by kind and baseline mode", anomalies,
    transformations=[count_by("obs_day", "anomaly_kind", "baseline_mode")],
    partition=("anomaly_kind", "baseline_mode"),
    display="${__field.labels.anomaly_kind} ${__field.labels.baseline_mode}", decimals=0,
    custom={"drawStyle": "bars", "fillOpacity": 90, "lineWidth": 1,
            "stacking": {"mode": "normal", "group": "k"}},
    overrides=[override("byRegexp", f"/ {m}$/", fixed(c)) for m, c in MODE_COLORS.items()]
    + [override("byRegexp", "/^CPU_SHIFT/", fixed(GREY))],
    description="One bar segment per kind and baseline mode, coloured by mode (TRAILING red, "
                "SAME_DOW amber, HOUR_OF_WEEK blue, level shifts grey), so a day two modes "
                "flagged shows two segments. HOUR_OF_WEEK counts flagged hours. "
                "TBSPC_GROWTH: tablespace growth rate; CPU_BUSY / DBCPU_BUSY: host CPU / a "
                "container's DB CPU; SERIES_LEVEL / SERIES_GROWTH: workload series; CPU_SHIFT: "
                "a container's DB CPU moved to a new level and stayed there (counted on the "
                "last day of its recent window)."),
    0, 4, 15, 9)

b.add({
    "type": "barchart", "title": "Most anomalous series", **data(anomalies),
    "transformations": [
        count_by("series"),
        {"id": "sortBy", "options": {"sort": [{"field": "sev_rank (count)", "desc": True}]}},
        {"id": "limit", "options": {"limitField": 10}},
    ],
    "fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": RED},
                                 "displayName": "Anomalies", "decimals": 0,
                                 "custom": {"fillOpacity": 90, "lineWidth": 0}},
                    "overrides": []},
    "options": {"orientation": "horizontal", "xField": "series",
                "showValue": "auto", "barWidth": 0.7,
                "legend": {"showLegend": False, "displayMode": "list",
                           "placement": "bottom"},
                "tooltip": {"mode": "single", "sort": "none"}},
}, 15, 4, 9, 9)

b.add({
    "type": "state-timeline", "title": "Anomalies per database per day (worst severity)",
    "description": "One row per database; a cell is a day with at least one anomaly, coloured "
                   "by its worst severity.",
    **data(anomalies),
    "transformations": [
        {"id": "groupBy", "options": {"fields": {
            "obs_day": {"aggregations": [], "operation": "groupby"},
            "db": {"aggregations": [], "operation": "groupby"},
            "sev_rank": {"aggregations": ["min"], "operation": "aggregate"}}}},
        {"id": "partitionByValues", "options": {"fields": ["db"], "keepFields": False}},
    ],
    "fieldConfig": {"defaults": {
        "displayName": "${__field.labels.db}",
        "color": {"mode": "thresholds"},
        "thresholds": steps((GREEN, None)),
        "mappings": [{"type": "value", "options": {
            "1": {"text": "CRIT", "color": RED, "index": 0},
            "2": {"text": "WARN", "color": AMBER, "index": 1},
            "3": {"text": "INFO", "color": BLUE, "index": 2}}}],
        "custom": {"fillOpacity": 90, "lineWidth": 0, "insertNulls": 86400000,
                   "spanNulls": False},
    }, "overrides": []},
    "options": {"mergeValues": False, "showValue": "never", "alignValue": "left",
                "rowHeight": 0.8,
                "legend": {"showLegend": True, "displayMode": "list",
                           "placement": "bottom"},
                "tooltip": {"mode": "single", "sort": "none"}},
}, 0, 13, 24, 7)

b.add(alerts_table("Fleet alerts", DB), 0, 32, 24, 8)

b.write()
