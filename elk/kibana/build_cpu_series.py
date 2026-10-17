#!/usr/bin/env python3
"""Generate dashboards/20-cpu-series.ndjson (AWR Capacity - CPU and workload series)."""
from lens_lib import (
    AMBER, DASH_CPU, GREEN, PAST, RED, DashboardBuilder, add_alerts_table,
    add_nav_panel, cell_colors, col_avg, col_date_histogram, col_last_value,
    col_max, col_palette_steps, col_static, col_terms, fmt_number,
    table_state, xy_annotation_layer, xy_data_layer, xy_multi_state, xy_ref_layer,
)

OBS_HOST = "cap.record:observation and cap.kind:CPU and cap.series:BUSY_PCT"
OBS_DBCPU = "cap.record:observation and cap.kind:CPU and cap.series:DB_CPU_PCT"
FC_HOST = ("cap.record:forecast and cap.kind:CPU and cap.method:REGR "
           "and cap.series:BUSY_P95")
ANOM_HOST = f"{OBS_HOST} and cap.anomaly:true"
SHIFT = "cap.record:anomaly and cap.anomaly_kind:CPU_SHIFT"
PCT = fmt_number(1, suffix=" %")

b = DashboardBuilder(
    "awrcap-cpu-series", DASH_CPU, "AWR Capacity - CPU and workload series",
    "Host CPU against the 80 % saturation line, DB CPU per container with "
    "level shifts, and sessions / processes / size / redo against their "
    "limits, each with its forecast.")
add_nav_panel(b)
b.add_controls(["cap.db", "cap.series"])

b.add_markdown("header", 0, 0, 48, 4, (
    "**CPU and workload: how close to the ceiling, and since when?** Solid "
    "lines left of today are observed daily values; lines right of today are "
    "the linear forecast with its low/high band. **Red bars mark anomalies**: "
    "a host-CPU day far outside its normal range, or the day a container's "
    "DB CPU shifted to a new level. The red dashed line is the 80 % "
    "saturation line; grey dashed lines are SESSIONS / PROCESSES limits. "
    "Pick one database with the control above to read a single host."))


def c(panel, name):
    return b.uid(f"col:{panel}-{name}")


# Host CPU: busy avg + p95, p95 forecast, anomaly days, 80 % line.
p = "host"
x_obs, x_fc, x_an = c(p, "x-obs"), c(p, "x-fc"), c(p, "x-an")
s_obs, s_fc = c(p, "s-obs"), c(p, "s-fc")
busy, p95, an = c(p, "busy"), c(p, "p95"), c(p, "anom")
fc, lo, hi, sat = c(p, "fc"), c(p, "lo"), c(p, "hi"), c(p, "sat")
layers = {
    "anom": ({
        x_an: col_date_histogram(),
        an: col_max("cap.value", "Anomaly day", kql=ANOM_HOST, fmt=PCT),
    }, [x_an, an]),
    "obs": ({
        x_obs: col_date_histogram(),
        busy: col_avg("cap.cpu.busy_pct", "Busy %", kql=OBS_HOST, fmt=PCT),
        p95: col_avg("cap.cpu.busy_p95", "Busy p95", kql=OBS_HOST, fmt=PCT),
        s_obs: col_terms("cap.db", "Database", busy, size=10),
    }, [s_obs, x_obs, busy, p95]),
    "fc": ({
        x_fc: col_date_histogram(),
        fc: col_avg("cap.value", "p95 forecast", kql=FC_HOST, fmt=PCT),
        lo: col_avg("cap.lo", "p95 forecast low", kql=FC_HOST, fmt=PCT),
        hi: col_avg("cap.hi", "p95 forecast high", kql=FC_HOST, fmt=PCT),
        s_fc: col_terms("cap.db", "Database", fc, size=10),
    }, [s_fc, x_fc, fc, lo, hi]),
    "sat": ({sat: col_static(80, "Saturation 80 %")}, [sat]),
}
b.add_lens("host-xy", "Host CPU busy %: observed, p95 forecast, anomalies in red",
           0, 4, 28, 15, "lnsXY", xy_multi_state([
               xy_data_layer("bar", x_an, [an], colors={an: RED}, key="anom"),
               xy_data_layer("line", x_obs, [busy, p95], split=s_obs, key="obs"),
               xy_data_layer("line", x_fc, [fc, lo, hi], split=s_fc, key="fc"),
               xy_ref_layer(sat, RED, key="sat", icon="alert"),
           ]), layers=layers,
           query="cap.kind:CPU and cap.series:(BUSY_PCT or BUSY_P95)")

# DB CPU per container, level shifts in red.
p = "dbcpu"
x_obs, x_sh, s_obs = c(p, "x-obs"), c(p, "x-shift"), c(p, "s-obs")
val, sh = c(p, "value"), c(p, "shift")
layers = {
    "shift": ({
        x_sh: col_date_histogram(),
        sh: col_max("cap.value", "Level shift", kql=SHIFT, fmt=PCT),
    }, [x_sh, sh]),
    "obs": ({
        x_obs: col_date_histogram(),
        val: col_avg("cap.value", "DB CPU %", kql=OBS_DBCPU, fmt=PCT),
        s_obs: col_terms("cap.db", "Container", val, size=10),
    }, [s_obs, x_obs, val]),
}
b.add_lens("dbcpu-xy", "DB CPU % of host per container (red = level shift)",
           28, 4, 20, 15, "lnsXY", xy_multi_state([
               xy_data_layer("bar", x_sh, [sh], colors={sh: RED}, key="shift"),
               xy_data_layer("line", x_obs, [val], split=s_obs, key="obs"),
               xy_annotation_layer("shift-marker", "Level shift", SHIFT,
                                   text_field="cap.db",
                                   tooltip_fields=["cap.message.keyword"]),
           ]), layers=layers, query="cap.kind:CPU and cap.series:DB_CPU_PCT",
           time_range=PAST, annotations=["shift-marker"])


def trend_table(p, title, y, h, kind, value_label, value_fmt, dtf_label,
                with_limit):
    db, ser = c(p, "db"), c(p, "series")
    sev, cur, lim, pct = c(p, "sev"), c(p, "value"), c(p, "limit"), c(p, "pct")
    slope, r2, qual = c(p, "slope"), c(p, "r2"), c(p, "quality")
    dtf, lo, hi = c(p, "dtf"), c(p, "dtf-lo"), c(p, "dtf-hi")
    cols = {
        db: col_terms("cap.db", "Database", None, size=200),
        ser: col_terms("cap.series", "Series", None, size=50),
        sev: col_last_value("cap.sev", "Sev", data_type="string"),
        cur: col_last_value("cap.value", value_label, fmt=value_fmt),
        slope: col_last_value("cap.slope_per_day", "Slope / day",
                              fmt=fmt_number(3)),
        dtf: col_last_value("cap.days_to_full", dtf_label, fmt=fmt_number(0)),
        lo: col_last_value("cap.days_to_full_lo", "low", fmt=fmt_number(0)),
        hi: col_last_value("cap.days_to_full_hi", "high", fmt=fmt_number(0)),
        r2: col_last_value("cap.r2", "R²", fmt=fmt_number(2)),
        qual: col_last_value("cap.quality", "Fit quality", data_type="string"),
    }
    order = [db, ser, sev, cur]
    overrides = {dtf: cell_colors(col_palette_steps(30, 90, (RED, AMBER, GREEN)))}
    if with_limit:
        cols[lim] = col_last_value("cap.limit", "Limit", fmt=fmt_number(0))
        cols[pct] = col_last_value("cap.pct", "% of limit", fmt=PCT)
        order += [lim, pct]
        overrides[pct] = cell_colors(col_palette_steps(90, 97))
    order += [slope, dtf, lo, hi, r2, qual]
    overrides.update({db: {"width": 190}, ser: {"width": 150}})
    b.add_lens(f"{p}-table", title, 0, y, 48, h, "lnsDatatable",
               table_state(order, dtf, direction="asc", page_size=8,
                           overrides=overrides),
               cols, order, query=f"cap.record:fit and cap.kind:{kind}")


trend_table("cputrend", "CPU trend (latest fit per metric, soonest saturation first)",
            19, 11, "CPU", "Current", fmt_number(1), "Days to 80 %", False)


def workload_xy(p, title, x, y, series, num):
    obs = f"cap.record:observation and cap.series:{series}"
    fcq = f"cap.record:forecast and cap.method:REGR and cap.series:{series}"
    x_obs, x_fc, s_obs, s_fc = c(p, "x-obs"), c(p, "x-fc"), c(p, "s-obs"), c(p, "s-fc")
    val, lim, fc, lo, hi = (c(p, n) for n in ("value", "limit", "fc", "lo", "hi"))
    layers = {
        "obs": ({
            x_obs: col_date_histogram(),
            val: col_avg("cap.value", "Observed", kql=obs, fmt=num),
            lim: col_max("cap.limit", "Limit", kql=obs, fmt=num),
            s_obs: col_terms("cap.db", "Database", val, size=10),
        }, [s_obs, x_obs, val, lim]),
        "fc": ({
            x_fc: col_date_histogram(),
            fc: col_avg("cap.value", "Forecast", kql=fcq, fmt=num),
            lo: col_avg("cap.lo", "Forecast low", kql=fcq, fmt=num),
            hi: col_avg("cap.hi", "Forecast high", kql=fcq, fmt=num),
            s_fc: col_terms("cap.db", "Database", fc, size=10),
        }, [s_fc, x_fc, fc, lo, hi]),
    }
    b.add_lens(f"{p}-xy", title, x, y, 24, 13, "lnsXY", xy_multi_state([
        xy_data_layer("line", x_obs, [val, lim], split=s_obs, key="obs"),
        xy_data_layer("line", x_fc, [fc, lo, hi], split=s_fc, key="fc"),
    ]), layers=layers, query=f"cap.kind:SERIES and cap.series:{series}")


COUNT = fmt_number(0)
GB = fmt_number(1, suffix=" GB")
workload_xy("sessions", "Sessions vs limit, with forecast", 0, 30, "SESSIONS", COUNT)
workload_xy("processes", "Processes vs limit, with forecast", 24, 30, "PROCESSES", COUNT)
workload_xy("dbsize", "Database size (GB), with forecast", 0, 43, "DB_SIZE_GB", GB)
workload_xy("redo", "Redo per day (GB), with forecast", 24, 43, "REDO_GB_DAY", GB)

trend_table("seriestrend", "Workload series (latest fit, soonest limit first)",
            56, 13, "SERIES", "Current", fmt_number(1), "Days to limit", True)
add_alerts_table(
    b, "alerts", "CPU and series alerts (latest export)", 0, 69, 48, 12,
    "cap.alert_kind:(CPU_SAT or DBCPU_SAT or CPU_ANOM or CPU_SHIFT or "
    "SERIES_LIMIT or SERIES_NEARLIMIT)")

b.write("20-cpu-series.ndjson")
