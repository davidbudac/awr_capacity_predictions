#!/usr/bin/env bash
# Build and import the AWR capacity data view + dashboards into Kibana.
# Idempotent: every import uses overwrite=true and fixed saved-object ids.
set -euo pipefail

KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
KIBANA_USER="${KIBANA_USER:-elastic}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:-changeme}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kibana"

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
