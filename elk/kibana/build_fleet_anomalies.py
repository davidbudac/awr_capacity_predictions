#!/usr/bin/env python3
"""Generate dashboards/30-fleet-anomalies.ndjson (AWR Capacity - Fleet anomalies)."""
from lens_lib import (
    AMBER, DASH_CPU, DASH_FLEET, DASH_TBSPC, RED, DashboardBuilder,
    add_alerts_table, add_nav_panel, alarm_when_nonzero, cell_colors, col_count,
    col_date_histogram, col_last_value, col_max, col_palette_steps, col_terms,
    col_unique_count, fmt_number, heatmap_state, metric_state, table_state,
    xy_data_layer, xy_multi_state,
)

ANOM = "cap.record:anomaly"

b = DashboardBuilder(
    "awrcap-fleet-anomalies", DASH_FLEET, "AWR Capacity - Fleet anomalies",
    "Every anomaly the CAPA_* layer flagged, across every exported database: "
    "tablespace growth outliers, host CPU outliers and DB CPU level shifts.",
    time_to="now")
add_nav_panel(b)
b.add_controls(["cap.db", "cap.anomaly_kind", "cap.sev"])

b.add_markdown("header", 0, 0, 24, 8, (
    "**Fleet anomalies: what changed, where, and when?** Each anomaly is one "
    "day a series broke from its own history. **TBSPC_GROWTH**: a tablespace "
    "grew far faster (or slower) than its median daily rate. **CPU_BUSY**: a "
    "host-CPU day far outside its normal range. **CPU_SHIFT**: a container's "
    "DB CPU moved to a new level and stayed there.\n\n"
    "**z** is the robust z-score: distance from the median in MAD units. "
    "Click a database or series in the table to open the tablespace or CPU "
    "dashboard filtered to it. Alerts at the bottom are the latest export's "
    "CAPR_ALERTS rows."))


def kpi(name, title, x, col, pal):
    m = b.uid(f"col:{name}")
    b.add_lens(name, title, x, 0, 6, 8, "lnsMetric",
               metric_state(m, pal=pal), {m: col}, [m], query=ANOM)


kpi("kpi-count", "Anomalies in range", 24,
    col_count("Anomalies", fmt=fmt_number(0)), alarm_when_nonzero())
kpi("kpi-dbs", "Databases affected", 30,
    col_unique_count("cap.db", "Databases", fmt=fmt_number(0)),
    alarm_when_nonzero(AMBER))
kpi("kpi-series", "Series affected", 36,
    col_unique_count("cap.series", "Series", fmt=fmt_number(0)),
    alarm_when_nonzero(AMBER))
kpi("kpi-warn", "WARN anomalies", 42,
    col_count("WARN", kql="cap.sev:WARN", fmt=fmt_number(0)),
    alarm_when_nonzero(AMBER))


def c(panel, name):
    return b.uid(f"col:{panel}-{name}")


p = "over-time"
x, n, k = c(p, "x"), c(p, "count"), c(p, "kind")
cols = {
    x: col_date_histogram(),
    n: col_count("Anomalies"),
    k: col_terms("cap.anomaly_kind", "Kind", n, size=5),
}
b.add_lens("over-time-xy", "Anomalies per day by kind", 0, 8, 30, 12, "lnsXY",
           xy_multi_state([xy_data_layer("bar_stacked", x, [n], split=k)]),
           cols, [k, x, n], query=ANOM)

p = "top-series"
s, n = c(p, "series"), c(p, "count")
cols = {
    n: col_count("Anomalies", fmt=fmt_number(0)),
    s: col_terms("cap.series", "Series", n, size=10),
}
b.add_lens("top-series-bar", "Most anomalous series", 30, 8, 18, 12, "lnsXY",
           xy_multi_state([xy_data_layer("bar_horizontal", s, [n],
                                         colors={n: RED})], legend=False),
           cols, [s, n], query=ANOM)

p = "heat"
x, db, n = c(p, "x"), c(p, "db"), c(p, "count")
cols = {
    x: col_date_histogram(empty_rows=False),
    n: col_count("Anomalies", fmt=fmt_number(0)),
    db: col_terms("cap.db", "Database", n, size=30),
}
b.add_lens("heatmap", "Anomalies per database per day", 0, 20, 48, 9,
           "lnsHeatmap", heatmap_state(x, db, n), cols, [db, x, n], query=ANOM)

p = "latest"
day, db, ser, kind = c(p, "day"), c(p, "db"), c(p, "series"), c(p, "kind")
z, flag, sev, msg = (c(p, n) for n in ("z", "flag", "sev", "msg"))
cols = {
    day: col_date_histogram(label="Day", empty_rows=False),
    db: col_terms("cap.db", "Database", None, size=200),
    ser: col_terms("cap.series", "Series", None, size=500),
    kind: col_terms("cap.anomaly_kind", "Kind", None, size=5),
    sev: col_last_value("cap.sev", "Sev", data_type="string"),
    z: col_max("cap.z", "z", fmt=fmt_number(1)),
    flag: col_last_value("cap.anomaly_flag", "Flag", data_type="string"),
    msg: col_last_value("cap.message.keyword", "What happened",
                        data_type="string"),
}
order = [day, db, ser, kind, sev, z, flag, msg]
b.add_lens("latest-table", "Anomalies, newest first (click a database or series to drill in)",
           0, 29, 48, 16, "lnsDatatable",
           table_state(order, day, page_size=10, overrides={
               day: {"width": 110}, db: {"width": 180}, ser: {"width": 160}, kind: {"width": 130},
               sev: {"width": 60}, flag: {"width": 60},
               z: {**cell_colors(col_palette_steps(3, 5)), "width": 70},
           }),
           cols, order, query=ANOM, drill_to=[DASH_TBSPC, DASH_CPU],
           drill_label=["Open tablespaces dashboard", "Open CPU and series dashboard"])

add_alerts_table(b, "alerts", "Fleet alerts (latest export)", 0, 45, 48, 12,
                 "cap.alert_kind:*")

b.write("30-fleet-anomalies.ndjson")
