"""Builders for the generated AWR capacity Kibana dashboards.

Adapted from elk_db_automation/kibana/lens_dashboard_lib.py. Everything is a
by-value Lens panel plus Kibana 9.4 pinned_panels controls. Gotchas carried
over from that repo, all verified against 9.4:
  - dashboard controls live in attributes.pinned_panels {"panels": {...}}
    with dashboard-level references named "<uuid>:optionsListDataView";
  - a terms column's orderBy cannot reference a formula column;
  - count needs emptyAsNull false or empty buckets render N/A instead of 0;
  - Lens refuses a terms split in a layer whose metrics mix timeShifts;
  - panel time ranges are persisted as snake_case time_range.

Added here: multi-layer XY charts (add_lens with several formBased layers,
each with its own layer id and indexpattern-datasource-layer-<id> reference)
and reference-line layers.

All panel/layer/column ids are md5-derived from stable names (namespaced per
dashboard), so re-running a builder is byte-identical.
"""
import hashlib
import json
import os

DATAVIEW = "awrcap-capacity-dataview"

RED = "#e7664c"
AMBER = "#f5a700"
GREEN = "#24c292"
GREY = "#98a2b3"

# "Current" panels (KPI tiles, alert tables) read only the latest export.
# Fit and alert docs are stamped with the export day, so a 2-day window
# always holds the newest run without needing a "latest" aggregation Lens
# cannot express for counts.
KQL_LATEST = '@timestamp >= "now-2d"'
# Panels that can only hold history (growth, anomalies) skip the forecast
# half of the dashboard's future-reaching time axis.
PAST = {"from": "now-120d", "to": "now"}


def out_path(filename):
    base = os.environ.get("KIBANA_DASHBOARD_OUT_DIR") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "dashboards")
    return os.path.join(base, filename)


# ---------------------------------------------------------------------------
# Column builders (Lens formBased datasource columns)
# ---------------------------------------------------------------------------
def fmt_number(decimals=2, suffix=None):
    p = {"decimals": decimals}
    if suffix:
        p["suffix"] = suffix
    return {"id": "number", "params": p}


def fmt_bytes(decimals=1):
    return {"id": "bytes", "params": {"decimals": decimals}}


def col_metric(op, field, label, kql=None, fmt=None, params=None,
               data_type="number"):
    c = {
        "label": label,
        "customLabel": True,
        "dataType": data_type,
        "operationType": op,
        "isBucketed": False,
        "sourceField": field,
        "params": dict(params or {}),
    }
    if fmt:
        c["params"]["format"] = fmt
    if kql:
        c["filter"] = {"query": kql, "language": "kuery"}
    return c


def col_avg(field, label, **kw):
    return col_metric("average", field, label, **kw)


def col_max(field, label, **kw):
    return col_metric("max", field, label, **kw)


def col_sum(field, label, **kw):
    """emptyAsNull: an empty day is a gap, not a zero (the forecast half of
    the time axis would otherwise draw a flat 0 line)."""
    c = col_metric("sum", field, label, **kw)
    c["params"]["emptyAsNull"] = True
    return c


def col_min(field, label, **kw):
    return col_metric("min", field, label, **kw)


def col_count(label, kql=None, fmt=None):
    c = col_metric("count", "___records___", label, kql=kql, fmt=fmt)
    c["params"]["emptyAsNull"] = False
    return c


def col_unique_count(field, label, kql=None, fmt=None):
    return col_metric("unique_count", field, label, kql=kql, fmt=fmt)


def col_last_value(field, label, kql=None, data_type="number", fmt=None,
                   sort_field="@timestamp"):
    return col_metric("last_value", field, label, kql=kql, fmt=fmt,
                      params={"sortField": sort_field}, data_type=data_type)


def col_static(value, label):
    """Constant for a reference-line layer (e.g. the 80 % saturation line)."""
    return {
        "label": label,
        "customLabel": True,
        "dataType": "number",
        "operationType": "static_value",
        "isBucketed": False,
        "isStaticValue": True,
        "params": {"value": str(value)},
        "references": [],
    }


def col_date_histogram(interval="1d", label="@timestamp", empty_rows=True):
    return {
        "label": label,
        "customLabel": label != "@timestamp",
        "dataType": "date",
        "operationType": "date_histogram",
        "isBucketed": True,
        "sourceField": "@timestamp",
        "params": {"interval": interval, "includeEmptyRows": empty_rows,
                   "dropPartials": False},
    }


def col_terms(field, label, order_col, size=12, direction="desc",
              missing=False, other=False, data_type="string"):
    """order_col=None ranks buckets alphabetically."""
    order_by = ({"type": "alphabetical", "fallback": True} if order_col is None
                else {"type": "column", "columnId": order_col})
    return {
        "label": label,
        "customLabel": True,
        "dataType": data_type,
        "operationType": "terms",
        "isBucketed": True,
        "sourceField": field,
        "params": {
            "size": size,
            "orderBy": order_by,
            "orderDirection": direction,
            "otherBucket": other,
            "missingBucket": missing,
            "parentFormat": {"id": "terms"},
            "include": [],
            "exclude": [],
            "includeIsRegex": False,
            "excludeIsRegex": False,
        },
    }


# ---------------------------------------------------------------------------
# Visualization states. "__LAYER__" is the single-layer placeholder;
# "__LAYER:<key>__" names one layer of a multi-layer chart. add_lens swaps
# both for the md5 layer ids.
# ---------------------------------------------------------------------------
def layer_ph(key=""):
    return f"__LAYER:{key}__" if key else "__LAYER__"


def _xy(layers, legend=True, y_title=None):
    return {
        "legend": {"isVisible": legend, "position": "bottom",
                   "maxLines": 1, "shouldTruncate": True,
                   "legendSize": "large"},
        "valueLabels": "hide",
        "fittingFunction": "Linear",
        "endValue": "None",
        "emphasizeFitting": True,
        "preferredSeriesType": layers[0].get("seriesType", "line"),
        "layers": layers,
        "yTitle": y_title or "",
        "axisTitlesVisibilitySettings": {"x": False, "yLeft": bool(y_title),
                                         "yRight": True},
        "gridlinesVisibilitySettings": {"x": True, "yLeft": True,
                                        "yRight": True},
        "tickLabelsVisibilitySettings": {"x": True, "yLeft": True,
                                         "yRight": True},
    }


def xy_data_layer(series, x_col, accessors, split=None, colors=None, key=""):
    """colors: {accessor: hex}. Only honoured on a layer without a split;
    a split layer takes its colours from the palette."""
    layer = {
        "layerId": layer_ph(key),
        "accessors": accessors,
        "position": "top",
        "seriesType": series,
        "showGridlines": False,
        "layerType": "data",
        "xAccessor": x_col,
    }
    if split:
        layer["splitAccessor"] = split
    if colors:
        layer["yConfig"] = [{"forAccessor": a, "color": c, "axisMode": "left"}
                            for a, c in colors.items()]
    return layer


def xy_ref_layer(accessor, color, key, icon="empty", fill="none"):
    return {
        "layerId": layer_ph(key),
        "layerType": "referenceLine",
        "accessors": [accessor],
        "yConfig": [{
            "forAccessor": accessor,
            "axisMode": "left",
            "color": color,
            "lineStyle": "dashed",
            "lineWidth": 2,
            "fill": fill,
            "icon": icon,
            "iconPosition": "auto",
            "textVisibility": True,
        }],
    }


def xy_annotation_layer(key, label, kql, color=RED, text_field=None,
                        tooltip_fields=()):
    """Query-based event annotations: a vertical marker on every matching
    document's @timestamp. A single anomaly day is one pixel wide as a 1d
    bar on a 120-day axis; a full-height marker is what makes it visible."""
    ann = {
        "type": "query",
        "id": f"{layer_ph(key)}-ann",
        "label": label,
        "key": {"type": "point_in_time"},
        "timeField": "@timestamp",
        "filter": {"type": "kibana_query", "query": kql, "language": "kuery"},
        "color": color,
        "lineStyle": "dashed",
        "lineWidth": 2,
        "icon": "alert",
        "textVisibility": bool(text_field),
        "extraFields": list(tooltip_fields),
    }
    if text_field:
        ann["textField"] = text_field
    return {
        "layerId": layer_ph(key),
        "layerType": "annotations",
        "annotations": [ann],
        "ignoreGlobalFilters": False,
    }


def xy_multi_state(layers, legend=True, y_title=None):
    return _xy(layers, legend, y_title)


def metric_state(accessor, color=None, pal=None):
    """color: static tile colour; pal: value-driven palette (see palette())."""
    s = {"layerId": "__LAYER__", "layerType": "data",
         "metricAccessor": accessor}
    if color:
        s["color"] = color
    if pal:
        s["palette"] = pal
    return s


def heatmap_state(x_col, y_col, value_col):
    return {
        "shape": "heatmap",
        "layerId": "__LAYER__",
        "layerType": "data",
        "legend": {"isVisible": True, "position": "right",
                   "type": "heatmap_legend"},
        "gridConfig": {"type": "heatmap_grid", "isCellLabelVisible": False,
                       "isYAxisLabelVisible": True,
                       "isXAxisLabelVisible": True,
                       "isYAxisTitleVisible": False,
                       "isXAxisTitleVisible": False},
        "valueAccessor": value_col,
        "xAccessor": x_col,
        "yAccessor": y_col,
    }


def palette(bands, max_stop=100000):
    """bands: [(color, from_value), ...] ascending, first from_value 0.
    rangeMin 0 + continuity "all": with rangeMin at the first threshold the
    band below it renders uncoloured."""
    uppers = [f for _, f in bands[1:]] + [max_stop]
    return {
        "name": "custom", "type": "palette",
        "params": {
            "steps": len(bands), "name": "custom", "reverse": False,
            "rangeType": "number", "rangeMin": 0, "rangeMax": max_stop,
            "progression": "fixed", "continuity": "all",
            "colorStops": [{"color": c, "stop": f} for c, f in bands],
            "stops": [{"color": c, "stop": u}
                      for (c, _), u in zip(bands, uppers)],
        },
    }


def col_palette_steps(low, high, colors=(GREEN, AMBER, RED)):
    """3 bands: colors[0] below `low`, colors[1] from `low`, colors[2] from
    `high`. Pass (RED, AMBER, GREEN) for "small is bad" columns."""
    return palette([(colors[0], 0), (colors[1], low), (colors[2], high)])


def cell_colors(pal):
    return {"alignment": "right", "colorMode": "cell", "palette": pal}


def table_state(visible_cols, sort_col, direction="desc", page_size=12,
                overrides=None):
    overrides = overrides or {}
    cols = []
    for i, c in enumerate(visible_cols):
        entry = {"columnId": c, "isTransposed": False}
        if i == 0:
            entry["alignment"] = "left"
        entry.update(overrides.get(c, {}))
        cols.append(entry)
    return {
        "layerId": "__LAYER__",
        "layerType": "data",
        "columns": cols,
        "sorting": {"columnId": sort_col, "direction": direction},
        "rowHeight": "single",
        "headerRowHeight": "single",
        "rowHeightLines": 1,
        "headerRowHeightLines": 1,
        "paging": {"size": page_size, "enabled": True},
    }


# Count tiles: grey at zero, the given colour from one upward.
def alarm_when_nonzero(color=RED):
    return palette([(GREY, 0), (color, 1)])


# ---------------------------------------------------------------------------
# Dashboard assembly
# ---------------------------------------------------------------------------
class DashboardBuilder:
    def __init__(self, namespace, dashboard_id, title, description,
                 time_from="now-120d", time_to="now+120d", dataview=DATAVIEW):
        self.namespace = namespace
        self.dashboard_id = dashboard_id
        self.title = title
        self.description = description
        self.time_from = time_from
        self.time_to = time_to
        self.dataview = dataview
        self.panels = []
        self.references = []
        self.pinned = {}
        self.y_offset = 0

    def uid(self, name):
        h = hashlib.md5((self.namespace + ":" + name).encode()).hexdigest()
        return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"

    def _grid(self, pid, x, y, w, h):
        return {"x": x, "y": y + self.y_offset, "w": w, "h": h, "i": pid}

    def add_markdown(self, name, x, y, w, h, markdown):
        pid = self.uid("panel:" + name)
        self.panels.append({
            "type": "visualization",
            "panelIndex": pid,
            "gridData": self._grid(pid, x, y, w, h),
            "embeddableConfig": {
                "savedVis": {
                    "type": "markdown",
                    "title": "",
                    "params": {"fontSize": 12, "openLinksInNewTab": False,
                               "markdown": markdown},
                    "uiState": {},
                    "data": {"aggs": [],
                             "searchSource": {"query": {"query": "",
                                                        "language": "kuery"},
                                              "filter": []}},
                },
                "enhancements": {},
            },
        })

    def add_lens(self, name, title, x, y, w, h, vis_type, vis_state,
                 columns=None, column_order=None, layers=None, query="",
                 drill_to=None, drill_label=None, time_range=None,
                 annotations=()):
        """Single layer: columns + column_order. Multi-layer: layers =
        {key: (columns, column_order)} with "__LAYER:<key>__" placeholders
        in vis_state. Every layer gets its own datasource reference."""
        if layers is None:
            layers = {"": (columns, column_order)}
        pid = self.uid("panel:" + name)
        ids = {key: self.uid(f"layer:{name}:{key}" if key else f"layer:{name}")
               for key in [*layers, *annotations]}
        text = json.dumps(vis_state)
        for key, lid in ids.items():
            text = text.replace(layer_ph(key), lid)
        vis_state = json.loads(text)
        ds_layers = {}
        lens_refs = []
        for key, (cols, order) in layers.items():
            lid = ids[key]
            ds_layers[lid] = {
                "columns": cols,
                "columnOrder": order,
                "sampling": 1,
                "ignoreGlobalFilters": False,
                "incompleteColumns": {},
            }
            ref = f"indexpattern-datasource-layer-{lid}"
            lens_refs.append({"type": "index-pattern", "id": self.dataview,
                              "name": ref})
            self.references.append({"id": self.dataview,
                                    "name": f"{pid}:{ref}",
                                    "type": "index-pattern"})
        for key in annotations:
            ref = f"xy-visualization-layer-{ids[key]}"
            lens_refs.append({"type": "index-pattern", "id": self.dataview,
                              "name": ref})
            self.references.append({"id": self.dataview,
                                    "name": f"{pid}:{ref}",
                                    "type": "index-pattern"})
        embeddable = {
            "attributes": {
                "references": lens_refs,
                "title": title,
                "description": "",
                "visualizationType": vis_type,
                "version": 2,
                "state": {
                    "visualization": vis_state,
                    "query": {"query": query, "language": "kuery"},
                    "filters": [],
                    "datasourceStates": {
                        "formBased": {"layers": ds_layers},
                        "indexpattern": {"layers": {}},
                        "textBased": {"layers": {}},
                    },
                    "internalReferences": [],
                    "adHocDataViews": {},
                },
            },
            "title": title,
        }
        if time_range:
            # Overrides the dashboard picker for this panel only. 9.4 reads
            # snake_case time_range; camelCase is the pre-9.4 fallback.
            embeddable["time_range"] = dict(time_range)
            embeddable["timeRange"] = dict(time_range)
        if drill_to:
            targets = drill_to if isinstance(drill_to, (list, tuple)) else [drill_to]
            labels = drill_label or [f"Open {t}" for t in targets]
            embeddable["drilldowns"] = []
            for target, label in zip(targets, labels):
                embeddable["drilldowns"].append({
                    "label": label,
                    "trigger": "on_apply_filter",
                    "open_in_new_tab": False,
                    # False: each board restores its own range (the fleet
                    # board ends at now; the others reach into the forecast).
                    "use_time_range": False,
                    "use_filters": True,
                    "type": "dashboard_drilldown",
                    "dashboardRefName": f"dashboard_drilldown_{target}",
                })
                self.references.append({
                    "id": target,
                    "name": f"{pid}:dashboard_drilldown_{target}",
                    "type": "dashboard",
                })
        self.panels.append({
            "type": "vis",
            "panelIndex": pid,
            "gridData": self._grid(pid, x, y, w, h),
            "embeddableConfig": embeddable,
        })

    def add_control(self, name, field, order, single=False, width="medium"):
        cid = self.uid("control:" + name)
        self.references.append({
            "id": self.dataview,
            "name": f"{cid}:optionsListDataView",
            "type": "index-pattern",
        })
        self.pinned[cid] = {
            "config": {
                "dataViewRefName": f"{cid}:optionsListDataView",
                "exclude": False,
                "existsSelected": False, "exists_selected": False,
                "fieldName": field, "field_name": field,
                "ignoreValidations": False, "ignore_validations": False,
                "runPastTimeout": False, "run_past_timeout": False,
                "searchTechnique": "wildcard",
                "search_technique": "wildcard",
                "selectedOptions": [], "selected_options": [],
                "singleSelect": single, "single_select": single,
                "sort": {"by": "_count", "direction": "desc"},
                "useGlobalFilters": True, "use_global_filters": True,
            },
            "grow": False,
            "order": order,
            "type": "options_list_control",
            "width": width,
        }

    def add_controls(self, fields):
        for order, field in enumerate(fields):
            self.add_control(field, field, order)

    def write(self, filename):
        dashboard = {
            "attributes": {
                "description": self.description,
                "kibanaSavedObjectMeta": {
                    "searchSourceJSON": json.dumps(
                        {"query": {"query": "", "language": "kuery"},
                         "filter": []}, separators=(",", ":"))
                },
                "optionsJSON": json.dumps({
                    "hidePanelTitles": False, "hidePanelBorders": False,
                    "useMargins": True, "autoApplyFilters": True,
                    "syncColors": True, "syncCursor": True,
                    "syncTooltips": True,
                }, separators=(",", ":")),
                "panelsJSON": json.dumps(self.panels, separators=(",", ":")),
                "pinned_panels": {"panels": self.pinned},
                "refreshInterval": {"pause": True, "value": 60000},
                "timeFrom": self.time_from,
                "timeRestore": True,
                "timeTo": self.time_to,
                "title": self.title,
            },
            "coreMigrationVersion": "8.8.0",
            "id": self.dashboard_id,
            "managed": False,
            "references": self.references,
            "type": "dashboard",
            "typeMigrationVersion": "10.3.0",
        }
        path = out_path(filename)
        with open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps(dashboard, separators=(",", ":")) + "\n")
        print(f"wrote {path}: {len(self.panels)} panels, "
              f"{len(self.references)} references")


# ---------------------------------------------------------------------------
# Navigation row shared by all three boards. A by-value Links embeddable:
# embeddableConfig is the flat {layout, links} shape (no Lens-style
# "attributes" wrapper), one dashboard reference per link named
# "<panelIndex>:<destinationRefName>".
# ---------------------------------------------------------------------------
NAV_HEIGHT = 3
DASH_TBSPC = "awrcap-dashboard-tablespaces"
DASH_CPU = "awrcap-dashboard-cpu-series"
DASH_FLEET = "awrcap-dashboard-fleet-anomalies"
NAV_LINKS = [
    ("Tablespaces", DASH_TBSPC),
    ("CPU and workload series", DASH_CPU),
    ("Fleet anomalies", DASH_FLEET),
]


def add_nav_panel(b, name="nav"):
    """Call first: it bumps b.y_offset so later panels sit below it."""
    pid = b.uid("panel:" + name)
    links = []
    for label, target in NAV_LINKS:
        ref_name = f"link_{b.uid(f'navlink:{name}:{target}')}_dashboard"
        links.append({
            "type": "dashboardLink",
            "label": label,
            "destinationRefName": ref_name,
            "options": {"open_in_new_tab": False, "use_filters": True,
                        "use_time_range": False},
        })
        b.references.append({"id": target, "name": f"{pid}:{ref_name}",
                             "type": "dashboard"})
    b.panels.append({
        "type": "links",
        "panelIndex": pid,
        "gridData": {"x": 0, "y": 0, "w": 48, "h": NAV_HEIGHT, "i": pid},
        "embeddableConfig": {"layout": "horizontal", "links": links},
    })
    b.y_offset += NAV_HEIGHT


def add_alerts_table(b, name, title, x, y, w, h, kql):
    """Latest export's alerts, one row per (db, series, alert kind)."""
    q = f"cap.record:alert and {KQL_LATEST} and ({kql})"
    sev = b.uid(f"col:{name}-sev")
    kind = b.uid(f"col:{name}-kind")
    db = b.uid(f"col:{name}-db")
    ser = b.uid(f"col:{name}-series")
    rank = b.uid(f"col:{name}-rank")
    msg = b.uid(f"col:{name}-msg")
    cols = {
        rank: col_max("cap.sev_rank", "Rank", fmt=fmt_number(0)),
        sev: col_terms("cap.sev", "Sev", rank, size=5, direction="asc"),
        kind: col_terms("cap.alert_kind", "Alert", None, size=20),
        db: col_terms("cap.db", "Database", None, size=200),
        ser: col_terms("cap.series", "Series", None, size=200, missing=True),
        msg: col_last_value("cap.message.keyword", "Message", data_type="string"),
    }
    order = [sev, kind, db, ser, rank, msg]
    state = table_state(order, rank, direction="asc", page_size=8, overrides={
        rank: {"hidden": True}, sev: {"width": 70}, db: {"width": 190},
        ser: {"width": 190},
        kind: {"width": 170}})
    b.add_lens(name, title, x, y, w, h, "lnsDatatable", state, cols, order,
               query=q)
