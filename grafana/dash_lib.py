"""Shared pieces for the grafana/build_*.py dashboard generators (stdlib only).

Every query goes through the Infinity data source `awrcap-ords` against the
ORDS endpoints in grafana/API.md. Dashboard variables are multi-select, and
the ORDS handlers take a single db/series, so the db/series narrowing happens
in Infinity's backend filterExpression over the kind-scoped response.
"""
import json
import pathlib

RED, AMBER, GREEN, BLUE, GREY = "#e7664c", "#f5a700", "#24c292", "#6092c0", "#8e8e8e"
DS = {"type": "yesoreyeram-infinity-datasource", "uid": "awrcap-ords"}
OUT = pathlib.Path(__file__).resolve().parent / "dashboards"

TIME_COLS = {"ts", "obs_day", "last_day"}
STRING_COLS = {
    "kind", "series", "db", "db_name", "con_name", "unit", "anomaly_flag",
    "method", "quality", "sev", "limit_source", "anomaly_kind", "message",
    "alert_kind",
}
RANGE = "from=${__from:date:iso}&to=${__to:date:iso}"
DB = "db IN (${db:singlequote})"
SERIES = "series IN (${series:singlequote})"
SEV_MAPPING = [{"type": "value", "options": {
    "CRIT": {"color": RED, "index": 0},
    "WARN": {"color": AMBER, "index": 1},
    "INFO": {"color": BLUE, "index": 2},
    "OK": {"color": GREEN, "index": 3},
}}]
PAST_120D = "120d"
# Infinity hands the expression a null days_to_full as 0, so a series that never
# fills (flat, shrinking, or no limit) is keyed by its fit instead; it sorts last.
SOONEST = {"selector": "slope_per_day > 0 && limit_value > 0 ? days_to_full : 1000000",
           "text": "soonest", "type": "number"}


def where(*parts):
    return " && ".join(p for p in parts if p)


def col_type(name):
    if name in TIME_COLS:
        return "timestamp"
    return "string" if name in STRING_COLS else "number"


def q(ref, path, cols, *, filt=None, summarize=None, by=None,
      alias=None, computed=()):
    """One Infinity backend query.

    cols: names, (selector, alias) or (selector, alias, type). A filter-only
    column typed "string" stays off a timeseries chart.
    """
    columns = []
    for c in cols:
        sel, text, typ = (c, c, None) if isinstance(c, str) else (*c, None)[:3]
        columns.append({"selector": sel, "text": text, "type": typ or col_type(sel)})
    t = {
        "refId": ref, "datasource": DS, "type": "json", "source": "url",
        "parser": "backend", "format": "table", "url": "/" + path,
        "url_options": {"method": "GET", "data": ""},
        "root_selector": "items", "columns": columns,
        "filters": [], "computed_columns": list(computed),
    }
    if filt:
        t["filterExpression"] = filt
    if summarize:
        t["summarizeExpression"] = summarize
        t["summarizeBy"] = by
        t["summarizeAlias"] = alias or "summary"
    return t


def prop(pid, value):
    return {"id": pid, "value": value}


def override(matcher, option, *props):
    return {"matcher": {"id": matcher, "options": option}, "properties": list(props)}


def fixed(color):
    return prop("color", {"mode": "fixed", "fixedColor": color})


def steps(*pairs):
    return {"mode": "absolute",
            "steps": [{"color": c, "value": v} for c, v in pairs]}


DASHED = prop("custom.lineStyle", {"fill": "dash", "dash": [10, 6]})
DOTTED = prop("custom.lineStyle", {"fill": "dot", "dash": [2, 6]})
NO_LEGEND = prop("custom.hideFrom", {"legend": True, "tooltip": False, "viz": False})


DASHBOARD_DS = {"type": "datasource", "uid": "-- Dashboard --"}


def data(src):
    """Panel data: Infinity targets, or the id of a panel whose query results to reuse.

    Reuse keeps each ORDS endpoint to one request per dashboard load; ORDS
    answers 429 when a dashboard fires twenty requests at once.
    """
    if isinstance(src, int):
        return {"datasource": DASHBOARD_DS, "targets": [{
            "refId": "A", "datasource": DASHBOARD_DS, "panelId": src,
            "withTransforms": False}]}
    return {"datasource": DS, "targets": src if isinstance(src, list) else [src]}


def keep(field, *values):
    """filterByValue: keep rows whose `field` equals one of `values`."""
    return {"id": "filterByValue", "options": {
        "type": "include", "match": "any",
        "filters": [{"fieldName": field, "config": {"id": "equal", "options": {"value": v}}}
                    for v in values]}}


def named(name):
    """Matcher regex for a lowercase field alias; db and series labels are upper case."""
    return f"/{name}/"


def red_points(name):
    """Overrides that turn the `name` field into red anomaly dots."""
    return [override("byRegexp", named(name), fixed(RED),
                     prop("custom.drawStyle", "points"),
                     prop("custom.showPoints", "always"),
                     prop("custom.pointSize", 11), NO_LEGEND)]


def timeseries(title, src, *, unit="none", display="${__field.name}",
               overrides=(), description="", time_from=None, legend="bottom",
               thresholds=None, custom=None, decimals=None, partition=(),
               transformations=()):
    """partition: label columns that split the long ORDS rows into one line each.

    The queries are merged into one table first because partitionByValues and
    filterByValue only read the first frame; `transformations` run on that
    merged table, and overrides match field names by regex.
    """
    defaults = {
        "unit": unit, "displayName": display,
        "color": {"mode": "palette-classic"},
        "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 0,
                   "showPoints": "never", "spanNulls": True,
                   "axisSoftMin": 0, **(custom or {})},
    }
    if decimals is not None:
        defaults["decimals"] = decimals
    if thresholds:
        defaults["thresholds"] = thresholds
        defaults["custom"]["thresholdsStyle"] = {"mode": "dashed"}
    p = {
        "type": "timeseries", "title": title, "description": description,
        **data(src),
        "transformations": [
            {"id": "merge", "options": {}}, *transformations,
            {"id": "partitionByValues", "options": {
                "fields": list(partition), "keepFields": False}},
        ] if partition else list(transformations),
        "fieldConfig": {"defaults": defaults, "overrides": list(overrides)},
        "options": {
            "legend": {"showLegend": True, "displayMode": "list",
                       "placement": legend},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
    }
    if time_from:
        p["timeFrom"] = time_from
    return p


def stat(title, src, *, field, calc, color_steps, unit="none",
         description="", transformations=()):
    return {
        "type": "stat", "title": title, "description": description,
        **data(src),
        "transformations": list(transformations),
        "fieldConfig": {"defaults": {
            "unit": unit, "noValue": "0", "decimals": 0,
            "color": {"mode": "thresholds"},
            "thresholds": steps(*color_steps),
        }, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": [calc], "fields": f"/^{field}$/",
                              "values": False},
            "colorMode": "background", "graphMode": "none",
            "textMode": "value", "justifyMode": "center",
        },
    }


def table(title, src, columns, *, sort=None, desc=False, hidden=(),
          description="", transformations=(), time_from=None):
    """columns: (field, header, [override props]) in display order; sort is a field."""
    if sort:
        transformations = [*transformations, {"id": "sortBy", "options": {
            "sort": [{"field": sort, "desc": desc}]}}]
    index = {f: i for i, (f, _h, *_r) in enumerate(columns)}
    rename = {f: h for f, h, *_r in columns if h != f}
    overrides = [override("byName", h, *r[0]) for _f, h, *r in columns if r and r[0]]
    p = {
        "type": "table", "title": title, "description": description,
        **data(src),
        "transformations": list(transformations) + [{
            "id": "organize",
            "options": {"indexByName": index, "renameByName": rename,
                        "excludeByName": {h: True for h in hidden}},
        }],
        "fieldConfig": {"defaults": {"custom": {"align": "auto",
                                                "cellOptions": {"type": "auto"}}},
                        "overrides": overrides},
        "options": {"showHeader": True, "cellHeight": "sm",
                    "footer": {"show": False}},
    }
    if time_from:
        p["timeFrom"] = time_from
    return p


NULL_BLANK = {"type": "special", "options": {
    "match": "null", "result": {"text": "", "color": "transparent", "index": 0}}}


def cell_bg(step_pairs, *extra):
    return [prop("custom.cellOptions", {"type": "color-background", "mode": "basic"}),
            prop("thresholds", steps(*step_pairs)), prop("mappings", [NULL_BLANK]),
            *extra]


def sev_cell():
    return [prop("mappings", SEV_MAPPING),
            prop("custom.cellOptions", {"type": "color-text"}),
            prop("custom.width", 70)]


def width(w):
    return prop("custom.width", w)


def alerts_table(title, filt, description=""):
    return table(
        title,
        q("A", "alerts", ["sev", "sev_rank", "alert_kind", "kind", "db", "series",
                          "obs_day", "value", "threshold", "unit", "message"],
          filt=filt),
        [("sev", "Sev", sev_cell()), ("alert_kind", "Alert", [width(150)]),
         ("db", "Database", [width(190)]), ("series", "Series", [width(160)]),
         ("obs_day", "Day", [width(110), prop("unit", "time:YYYY-MM-DD")]),
         ("message", "Message"), ("sev_rank", "sev_rank"), ("kind", "kind"),
         ("value", "value"), ("threshold", "threshold"), ("unit", "unit")],
        hidden=("sev_rank", "kind", "value", "threshold", "unit"),
        transformations=[{"id": "sortBy", "options": {
            "sort": [{"field": "sev_rank", "desc": False}]}}],
        description=description)


def query_var(name, label, target, field):
    return {
        "name": name, "label": label, "type": "query", "datasource": DS,
        "query": {"queryType": "infinity", "infinityQuery": target,
                  "meta": {"valueField": field, "textField": field},
                  "refId": f"var-{name}"},
        "definition": target["url"], "refresh": 2, "sort": 1,
        "multi": True, "includeAll": True,
        "current": {"text": ["All"], "value": ["$__all"]},
    }


def custom_var(name, label, values):
    return {
        "name": name, "label": label, "type": "custom",
        "query": ",".join(values), "multi": True, "includeAll": True,
        "current": {"text": ["All"], "value": ["$__all"]},
        "options": [],
    }


def db_var():
    return query_var("db", "Database", q("V", "containers", ["db"]), "db")


def annotation(name, target, color, panel_ids, *, time="ts", time_end=None,
               text="message", tags="series"):
    mappings = {"time": {"source": "field", "value": time},
                "text": {"source": "field", "value": text},
                "tags": {"source": "field", "value": tags}}
    if time_end:
        mappings["timeEnd"] = {"source": "field", "value": time_end}
    return {
        "name": name, "enable": True, "iconColor": color, "datasource": DS,
        "target": target, "mappings": mappings,
        "filter": {"exclude": False, "ids": list(panel_ids)},
    }


class Board:
    def __init__(self, uid, title, description, time_from, time_to):
        self.uid, self.title, self.description = uid, title, description
        self.time = {"from": time_from, "to": time_to}
        self.panels, self.variables, self.annotations = [], [], []

    def add(self, panel, x, y, w, h):
        panel = {"id": len(self.panels) + 1,
                 "gridPos": {"x": x, "y": y, "w": w, "h": h}, **panel}
        self.panels.append(panel)
        return panel["id"]

    def write(self):
        doc = {
            "uid": self.uid, "title": self.title,
            "description": self.description, "tags": ["awrcap"],
            "editable": True, "graphTooltip": 1, "schemaVersion": 41,
            "time": self.time, "refresh": "", "timezone": "utc",
            "links": [{"type": "dashboards", "tags": ["awrcap"],
                       "asDropdown": False, "includeVars": True,
                       "keepTime": False, "title": "AWR capacity"}],
            "templating": {"list": self.variables},
            "annotations": {"list": self.annotations},
            "panels": self.panels,
        }
        OUT.mkdir(exist_ok=True)
        path = OUT / f"{self.uid}.json"
        path.write_text(json.dumps(doc, indent=2) + "\n")
        print(path)
