#!/usr/bin/env python3
"""Generate dashboards/awrcap-fleet-anomalies.json (AWR capacity: fleet anomalies)."""
from dash_lib import (
    AMBER, BLUE, DB, GREEN, RED, RANGE, Board, alerts_table, cell_bg, custom_var,
    data, db_var, fixed, keep, override, prop, q, sev_cell, stat, steps, table,
    timeseries, where, width,
)

KINDS = (("TBSPC_GROWTH", RED), ("CPU_BUSY", AMBER), ("CPU_SHIFT", BLUE))
FILT = where(DB, "anomaly_kind IN (${kind:singlequote})", "sev IN (${sev:singlequote})")
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
          "module serves: tablespace growth outliers, host CPU outliers and DB CPU "
          "level shifts.",
          "now-120d", "now")
b.variables += [
    db_var(),
    custom_var("kind", "Anomaly kind", [k for k, _c in KINDS]),
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
    q("A", f"anomalies?{RANGE}", ["ts", "db", "series", "anomaly_kind", "sev", "sev_rank",
                                   "z", "anomaly_flag", "message"], filt=FILT),
    field="sev_rank", calc="count", color_steps=ALARM), 0, 0, 6, 4)
b.add(table(
    "Anomalies, newest first (click a database or series to drill in)", anomalies, [
        ("ts", "Day", [width(110), prop("unit", "time:YYYY-MM-DD")]),
        ("db", "Database", [width(190), prop("links", LINKS)]),
        ("series", "Series", [width(170), prop("links", LINKS)]),
        ("anomaly_kind", "Kind", [width(130)]),
        ("sev", "Sev", sev_cell()),
        ("z", "z", cell_bg(((GREEN, None), (AMBER, 3), (RED, 5)),
                           prop("decimals", 1), width(70))),
        ("anomaly_flag", "Flag", [width(60)]),
        ("message", "What happened"), ("sev_rank", "sev_rank")],
    sort="ts", desc=True, hidden=("sev_rank",)),
    0, 20, 24, 12)

b.add(stat("Databases affected", anomalies, transformations=[count_by("db")],
           field=COUNT, calc="count", color_steps=WATCH), 6, 0, 6, 4)
b.add(stat("Series affected", anomalies, transformations=[count_by("series")],
           field=COUNT, calc="count", color_steps=WATCH), 12, 0, 6, 4)
b.add(stat("WARN anomalies", anomalies, transformations=[keep("sev", "WARN")],
           field="sev_rank", calc="count", color_steps=WATCH), 18, 0, 6, 4)

b.add(timeseries(
    "Anomalies per day by kind", anomalies,
    transformations=[count_by("ts", "anomaly_kind")], partition=("anomaly_kind",),
    display="${__field.labels.anomaly_kind}", decimals=0,
    custom={"drawStyle": "bars", "fillOpacity": 90, "lineWidth": 1,
            "stacking": {"mode": "normal", "group": "k"}},
    overrides=[override("byRegexp", f"/{k}/", fixed(c)) for k, c in KINDS],
    description="TBSPC_GROWTH: a tablespace grew far faster (or slower) than its median daily "
                "rate. CPU_BUSY: a host-CPU day far outside its normal range. CPU_SHIFT: a "
                "container's DB CPU moved to a new level and stayed there (dated at the start "
                "of its recent window)."),
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
            "ts": {"aggregations": [], "operation": "groupby"},
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
