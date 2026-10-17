#!/usr/bin/env bash
# One-time stack setup, run from an admin workstation: the awrcap-capacity
# index template (plus an additive mapping update if the index exists), then
# the Kibana data view and dashboards, and Kibana's dateFormat:tz = UTC (every
# exported day and hour is the DB wall clock labelled Z, so UTC displays it
# unshifted). Idempotent: PUTs, a settings POST and overwrite=true imports with
# fixed ids. Shipping itself never needs these credentials.
#
#   elk/setup.sh                        # template, tz setting, dashboards
#   elk/setup.sh --purge-anomaly-docs   # same, after deleting every anomaly
#                                       # and alert document once (their ids
#                                       # changed with the baseline modes)
set -euo pipefail

purge=""
case "${1:-}" in
  "") ;;
  --purge-anomaly-docs) purge=1 ;;
  *) echo "usage: $0 [--purge-anomaly-docs]" >&2; exit 2 ;;
esac

ES_URL="${ES_URL:-http://localhost:9200}"
ES_USER="${ES_USER:-elastic}"
ES_PASSWORD="${ES_PASSWORD:-changeme}"
KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
KIBANA_USER="${KIBANA_USER:-elastic}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:-changeme}"
elk="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
here="$elk/kibana"
index=awrcap-capacity

es() {
  local method="$1" path="$2" body="$3" out
  out="$(curl -sS -u "$ES_USER:$ES_PASSWORD" -H 'Content-Type: application/json' \
    -X "$method" "$ES_URL$path" --data-binary "$body")"
  if ! grep -q '"acknowledged":true' <<<"$out"; then
    echo "$method $path failed: $out" >&2
    exit 1
  fi
}

es PUT "/_index_template/$index" "@$elk/elasticsearch/index-template.json"
exists=""
if curl -sS -o /dev/null -w '%{http_code}' -u "$ES_USER:$ES_PASSWORD" "$ES_URL/$index" | grep -q 200; then
  exists=1
  es PUT "/$index/_mapping" "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["template"]["mappings"]))' "$elk/elasticsearch/index-template.json")"
fi
echo "index template $index applied"

if [[ -n $purge && -n $exists ]]; then
  out="$(curl -sS -u "$ES_USER:$ES_PASSWORD" -H 'Content-Type: application/json' \
    -X POST "$ES_URL/$index/_delete_by_query?conflicts=proceed&refresh=true" \
    --data-binary '{"query":{"query_string":{"query":"cap.record:(anomaly OR alert)"}}}')"
  if ! grep -q '"failures":\[\]' <<<"$out"; then
    echo "purge of anomaly/alert documents failed: $out" >&2
    exit 1
  fi
  echo "purged anomaly/alert documents: $(grep -o '"deleted":[0-9]*' <<<"$out")"
fi

for builder in "$here"/build_*.py; do
  python3 "$builder"
done

import() {
  local file="$1" out
  out="$(curl -sS -u "$KIBANA_USER:$KIBANA_PASSWORD" -H 'kbn-xsrf: true' \
    -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
    -F "file=@$file")"
  if ! grep -q '"success":true' <<<"$out"; then
    echo "import failed: $file" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "imported $(basename "$file")"
}

out="$(curl -sS -u "$KIBANA_USER:$KIBANA_PASSWORD" -H 'kbn-xsrf: true' \
  -H 'Content-Type: application/json' -X POST "$KIBANA_URL/api/kibana/settings" \
  --data-binary '{"changes":{"dateFormat:tz":"UTC"}}')"
if ! grep -q '"dateFormat:tz":{[^}]*"userValue":"UTC"' <<<"$out"; then
  echo "setting Kibana dateFormat:tz failed: $out" >&2
  exit 1
fi
echo "Kibana dateFormat:tz = UTC"

import "$here/data-views.ndjson"
for f in "$here"/dashboards/*.ndjson; do
  import "$f"
done

for id in awrcap-dashboard-tablespaces awrcap-dashboard-cpu-series \
          awrcap-dashboard-fleet-anomalies; do
  echo "$KIBANA_URL/app/dashboards#/view/$id"
done
