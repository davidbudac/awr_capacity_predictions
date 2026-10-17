#!/usr/bin/env bash
# One-time stack setup, run from an admin workstation: the awrcap-capacity
# index template (plus an additive mapping update if the index exists), then
# the Kibana data view and dashboards. Idempotent: PUTs and overwrite=true
# imports with fixed ids. Shipping itself never needs these credentials.
set -euo pipefail

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
if curl -sS -o /dev/null -w '%{http_code}' -u "$ES_USER:$ES_PASSWORD" "$ES_URL/$index" | grep -q 200; then
  es PUT "/$index/_mapping" "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["template"]["mappings"]))' "$elk/elasticsearch/index-template.json")"
fi
echo "index template $index applied"

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

import "$here/data-views.ndjson"
for f in "$here"/dashboards/*.ndjson; do
  import "$f"
done

for id in awrcap-dashboard-tablespaces awrcap-dashboard-cpu-series \
          awrcap-dashboard-fleet-anomalies; do
  echo "$KIBANA_URL/app/dashboards#/view/$id"
done
