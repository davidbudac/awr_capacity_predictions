#!/usr/bin/env python3
"""Generate dashboards/10-tablespaces.ndjson (AWR Capacity - Tablespaces)."""
from lens_lib import (
    AMBER, DASH_TBSPC, GREEN, GREY, KQL_LATEST, PAST, RED, DashboardBuilder,
    add_alerts_table, alarm_when_nonzero, add_nav_panel, cell_colors, col_avg, col_count,
    col_date_histogram, col_last_value, col_max, col_min, col_palette_steps,
    col_sum, col_terms, col_unique_count, fmt_bytes, fmt_number,
    metric_state, palette, table_state, xy_data_layer, xy_multi_state, xy_ref_layer,
)

OBS = "cap.record:observation and cap.kind:TBSPC"
FIT = "cap.record:fit and cap.kind:TBSPC"
FC = "cap.record:forecast and cap.kind:TBSPC and cap.method:REGR"
ANOM_OBS = f"{OBS} and cap.anomaly:true"
GROWTH = "cap.record:anomaly and cap.anomaly_kind:TBSPC_GROWTH"

b = DashboardBuilder(
    "awrcap-tablespaces", DASH_TBSPC, "AWR Capacity - Tablespaces",
    "Tablespace usage from AWR: observed daily, forecast to a year out, "
    "days to full, and the growth days the anomaly layer flagged.")
add_nav_panel(b)
b.add_controls(["cap.db", "cap.series"])

b.add_markdown("header", 0, 0, 24, 8, (
    "**Tablespaces: when do they fill up?** Lines left of today are observed "
    "daily usage; lines right of today are the linear forecast with its "
    "low/high band. The dashed grey line is the ceiling (MAXBYTES or the "
    "operator override).\n\n"
    "**Red bars are anomalies**: days whose growth was far outside the "
    "tablespace's own normal rate (robust z-score on the median daily "
    "growth). The table at the bottom explains each one.\n\n"
    "**Days to full** is the linear fit's projection at today's slope, with "
    "a low/high range from the forecast band. CRIT at 30 days or less, WARN "
    "at 90. Tiles and the alerts table read only the latest export. Pick a "
    "database and tablespace above to read a single chart."))


def kpi(name, title, x, col, pal):
    m = b.uid(f"col:{name}")
    b.add_lens(name, title, x, 0, 6, 8, "lnsMetric",
               metric_state(m, pal=pal), {m: col}, [m])


kpi("kpi-crit", "Tablespaces CRIT", 24, col_unique_count(
    "cap.series", "Tablespaces CRIT",
    kql=f"{FIT} and cap.sev:CRIT and {KQL_LATEST}", fmt=fmt_number(0)), alarm_when_nonzero())
kpi("kpi-warn", "Tablespaces WARN", 30, col_unique_count(
    "cap.series", "Tablespaces WARN",
    kql=f"{FIT} and cap.sev:WARN and {KQL_LATEST}", fmt=fmt_number(0)), alarm_when_nonzero(AMBER))
kpi("kpi-anom", "Growth anomalies in range", 36, col_count(
    "Growth anomalies", kql=GROWTH, fmt=fmt_number(0)), alarm_when_nonzero())
kpi("kpi-dtf", "Worst days to full", 42, col_min(
    "cap.days_to_full", "Worst days to full",
    kql=f"{FIT} and {KQL_LATEST}", fmt=fmt_number(0, suffix=" d")),
    palette([(RED, 0), (AMBER, 31), (GREEN, 91)]))


def c(panel, name):
    return b.uid(f"col:{panel}-{name}")


# Days-to-full table: latest fit per (db, tablespace).
p = "dtf"
db, ser = c(p, "db"), c(p, "series")
pct, used, lim, slope = c(p, "pct"), c(p, "used"), c(p, "limit"), c(p, "slope")
dtf, lo, hi = c(p, "dtf"), c(p, "dtf-lo"), c(p, "dtf-hi")
r2, qual, sev = c(p, "r2"), c(p, "quality"), c(p, "sev")
cols = {
    db: col_terms("cap.db", "Database", None, size=200),
    ser: col_terms("cap.series", "Tablespace", None, size=500),
    sev: col_last_value("cap.sev", "Sev", data_type="string"),
    pct: col_last_value("cap.pct", "Used %", fmt=fmt_number(1, suffix=" %")),
    used: col_last_value("cap.value", "Used", fmt=fmt_bytes(1)),
    lim: col_last_value("cap.limit", "Ceiling", fmt=fmt_bytes(1)),
    slope: col_last_value("cap.slope_per_day", "Growth / day", fmt=fmt_bytes(1)),
    dtf: col_last_value("cap.days_to_full", "Days to full", fmt=fmt_number(0)),
    lo: col_last_value("cap.days_to_full_lo", "DTF low", fmt=fmt_number(0)),
    hi: col_last_value("cap.days_to_full_hi", "DTF high", fmt=fmt_number(0)),
    r2: col_last_value("cap.r2", "R²", fmt=fmt_number(2)),
    qual: col_last_value("cap.quality", "Fit quality", data_type="string"),
}
order = [db, ser, sev, pct, used, lim, slope, dtf, lo, hi, r2, qual]
b.add_lens("dtf-table", "Days to full (latest fit per tablespace, soonest first)",
           0, 8, 48, 12, "lnsDatatable",
           table_state(order, dtf, direction="asc", page_size=10, overrides={
               db: {"width": 190}, ser: {"width": 190},
               pct: cell_colors(col_palette_steps(90, 97)),
               dtf: cell_colors(col_palette_steps(30, 90, (RED, AMBER, GREEN))),
           }),
           cols, order, query=FIT)

# Used bytes: observed + forecast + band + anomaly bars + ceiling.
p = "used"
x_obs, x_fc, x_an = c(p, "x-obs"), c(p, "x-fc"), c(p, "x-an")
s_obs, s_fc = c(p, "s-obs"), c(p, "s-fc")
v_obs, v_fc, v_lo, v_hi = c(p, "obs"), c(p, "fc"), c(p, "lo"), c(p, "hi")
v_an, v_lim = c(p, "anom"), c(p, "limit")
layers = {
    "obs": ({
        x_obs: col_date_histogram(),
        v_obs: col_avg("cap.value", "Observed", kql=OBS, fmt=fmt_bytes(1)),
        s_obs: col_terms("cap.series", "Tablespace", v_obs, size=10),
    }, [s_obs, x_obs, v_obs]),
    "fc": ({
        x_fc: col_date_histogram(),
        v_fc: col_avg("cap.value", "Forecast", kql=FC, fmt=fmt_bytes(1)),
        v_lo: col_avg("cap.lo", "Forecast low", kql=FC, fmt=fmt_bytes(1)),
        v_hi: col_avg("cap.hi", "Forecast high", kql=FC, fmt=fmt_bytes(1)),
        s_fc: col_terms("cap.series", "Tablespace", v_fc, size=10),
    }, [s_fc, x_fc, v_fc, v_lo, v_hi]),
    "anom": ({
        x_an: col_date_histogram(),
        v_an: col_max("cap.value", "Anomaly day", kql=ANOM_OBS,
                      fmt=fmt_bytes(1)),
    }, [x_an, v_an]),
    "limit": ({
        v_lim: col_max("cap.limit", "Ceiling", kql=OBS, fmt=fmt_bytes(1)),
    }, [v_lim]),
}
state = xy_multi_state([
    xy_data_layer("bar", x_an, [v_an], colors={v_an: RED}, key="anom"),
    xy_data_layer("line", x_obs, [v_obs], split=s_obs, key="obs"),
    xy_data_layer("line", x_fc, [v_fc, v_lo, v_hi], split=s_fc, key="fc"),
    xy_ref_layer(v_lim, GREY, key="limit"),
])
state["legend"]["position"] = "right"
b.add_lens("used-xy", "Used space: observed, forecast (REGR + band), anomalies in red",
           0, 20, 48, 16, "lnsXY", state, layers=layers,
           query="cap.kind:TBSPC")

# Daily growth: one stacked bar per day, the flagged part in red, against
# the median rate the anomaly test measures from.
p = "growth"
x, norm, anom = c(p, "x"), c(p, "normal"), c(p, "anom")
x_exp, exp = c(p, "x-exp"), c(p, "expected")
layers = {
    "bars": ({
        x: col_date_histogram(),
        norm: col_sum("cap.tbspc.delta_bytes", "Daily growth",
                      kql=f"{OBS} and not cap.anomaly:true", fmt=fmt_bytes(1)),
        anom: col_sum("cap.tbspc.delta_bytes", "Anomalous growth",
                      kql=ANOM_OBS, fmt=fmt_bytes(1)),
    }, [x, norm, anom]),
    "expected": ({
        x_exp: col_date_histogram(),
        exp: col_sum("cap.expected", "Median daily growth", kql=OBS,
                     fmt=fmt_bytes(1)),
    }, [x_exp, exp]),
}
b.add_lens("growth-xy", "Daily growth (sum of selected tablespaces; red = flagged day)",
           0, 36, 48, 11, "lnsXY", xy_multi_state([
               xy_data_layer("bar_stacked", x, [norm, anom],
                             colors={norm: "#6092c0", anom: RED}, key="bars"),
               xy_data_layer("line", x_exp, [exp], colors={exp: GREY},
                             key="expected"),
           ]), layers=layers, time_range=PAST)

# Growth anomalies, newest first.
p = "anoms"
day, db, ser = c(p, "day"), c(p, "db"), c(p, "series")
val, exp, z, flag, msg = (c(p, n) for n in ("value", "exp", "z", "flag", "msg"))
cols = {
    day: col_date_histogram(label="Day", empty_rows=False),
    db: col_terms("cap.db", "Database", None, size=200),
    ser: col_terms("cap.series", "Tablespace", None, size=500),
    val: col_max("cap.value", "Growth", fmt=fmt_bytes(1)),
    exp: col_max("cap.expected", "Expected", fmt=fmt_bytes(1)),
    z: col_max("cap.z", "z", fmt=fmt_number(1)),
    flag: col_last_value("cap.anomaly_flag", "Flag", data_type="string"),
    msg: col_last_value("cap.message.keyword", "What happened",
                        data_type="string"),
}
order = [day, db, ser, val, exp, z, flag, msg]
b.add_lens("anom-table", "Growth anomalies (newest first)", 0, 47, 48, 12,
           "lnsDatatable", table_state(order, day, page_size=8, overrides={
               day: {"width": 110}, db: {"width": 190}, ser: {"width": 190},
               val: {"width": 110},
               exp: {"width": 110}, z: {**cell_colors(col_palette_steps(3, 5)),
                                       "width": 80},
               flag: {"width": 70},
           }),
           cols, order, query=GROWTH, time_range=PAST)

add_alerts_table(b, "alerts", "Tablespace alerts (latest export)", 0, 59, 48,
                 12, "cap.kind:TBSPC")

b.write("10-tablespaces.ndjson")
