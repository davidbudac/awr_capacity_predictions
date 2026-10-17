#!/usr/bin/env bash
# test/docs_lint.sh -- catch documentation drift against the DDL.
# Bash + grep/awk only. Five checks, each prints one OK / FAIL summary line:
#   1. every knob the ddl/05 seed MERGE inserts is named in docs/reference.html;
#   2. every view / table / package / procedure that ddl/ and ml/ create is
#      named in the object index of docs/reference.html (id="objects" up to
#      id="teardown"), case-insensitive;
#   3. no document hard-codes an assertion count (the harness prints its own;
#      docs point at its summary lines instead);
#   4. no document claims the site is generated (it is maintained by hand);
#   5. every alert kind CAPR_ALERTS can emit is named in docs/reference.html.
#      The kinds come from CAPR_SEVERITY (ddl/45), the alert_kind column of
#      CAPA_OBS (ddl/40) and the extra branches of CAPR_ALERTS (ddl/55).
# Exit 1 when any check fails.
set -u
cd "$(dirname "$0")/.." || exit 2
REF=docs/reference.html
DOCS="README.md CLAUDE.md PLAN.md LAB.md docs/*.html docs/design.md grafana/API.md
      elk/README.md apex/README.md bench/README.md"
rc=0

report() {   # report <label> <checked> <missing list>
  local n_miss
  n_miss=$(printf '%s' "$3" | grep -c . || true)
  if [ "$n_miss" -eq 0 ]; then
    echo "OK   $1: $2 checked, 0 missing"
  else
    echo "FAIL $1: $2 checked, $n_miss missing:"
    printf '%s\n' "$3" | grep . | sed 's/^/       /'
    rc=1
  fi
}

# ---- 1. knobs ---------------------------------------------------------------
knobs=$(awk '/^-- Idempotent seed/{on=1} on && /^\) s$/{exit} on' ddl/05_config.sql \
        | grep -oE "SELECT '[a-z0-9_]+'" | sed -E "s/SELECT '([a-z0-9_]+)'/\1/" | sort -u)
miss=""
for k in $knobs; do
  grep -qE "(^|[^a-z0-9_])${k}([^a-z0-9_]|$)" "$REF" || miss="$miss$k"$'\n'
done
report "knobs seeded in ddl/05 named in $REF" "$(echo "$knobs" | grep -c .)" "$miss"

# ---- 2. objects -------------------------------------------------------------
objects=$(cat ddl/*.sql ml/*.pks ml/*.pkb 2>/dev/null \
  | grep -v -E '^\s*--' \
  | grep -oiE "CREATE( OR REPLACE)?( FORCE)? (VIEW|TABLE|PACKAGE|PROCEDURE|FUNCTION|TYPE) +[a-z0-9_\$]+" \
  | grep -viE 'PACKAGE BODY|TYPE BODY' \
  | awk '{print toupper($NF)}' | sort -u)
index_txt=$(awk '/id="objects"/{on=1} /id="teardown"/{on=0} on' "$REF" | sed 's/<[^>]*>/ /g' | tr 'a-z' 'A-Z')
miss=""
for o in $objects; do
  printf '%s' "$index_txt" | grep -qE "(^|[^A-Z0-9_\$])${o//\$/\\\$}([^A-Z0-9_\$]|$)" || miss="$miss$o"$'\n'
done
report "objects created in ddl/ + ml/ named in the $REF object index" "$(echo "$objects" | grep -c .)" "$miss"

# ---- 3. hard-coded assertion counts ------------------------------------------
# A standalone number of two or more digits (not part of 19c, 18:00 or M15)
# within a short clause of "assertion(s)", or right before "passed" / "PASS".
NUM='(^|[^A-Za-z0-9_.:+-])[*]*[0-9]{2,}[*]*([^A-Za-z0-9_:.]|$)'
hits=$(grep -n -i -E \
  "${NUM}[^.;]{0,40}assertion|assertion[^.;]{0,40}${NUM}|[0-9]{2,} (passed|PASS)" \
  $DOCS 2>/dev/null)
report "documents without a hard-coded assertion count" "$(echo $DOCS | wc -w)" "$hits"

# ---- 4. "generated" claims ----------------------------------------------------
hits=$(grep -n -i -E 'documentation (is )?generated|generated from[^.]{0,40}(README|design\.md)|(site|pages) (is|are) generated' \
  $DOCS 2>/dev/null)
report "documents not claiming the site is generated" "$(echo $DOCS | wc -w)" "$hits"

# ---- 5. alert kinds -------------------------------------------------------------
sev_kinds=$(awk '/CREATE OR REPLACE VIEW capr_severity/{on=1} on && /^CREATE OR REPLACE VIEW/ && !/capr_severity/{exit} on' \
              ddl/45_report_views.sql | grep -oE "SELECT '[A-Z]+_[A-Z_]+'" | grep -oE "[A-Z]+_[A-Z_]+")
anom_kinds=$(grep -oE "'[A-Z]+_ANOM'" ddl/40_anomaly_views.sql | tr -d "'")
alert_kinds=$(awk '/CREATE OR REPLACE VIEW capr_alerts AS/{on=1} on' ddl/55_report_views_ml.sql \
              | grep -oE "^ +'[A-Z]+_[A-Z_]+',$" | grep -oE "[A-Z]+_[A-Z_]+" \
              | grep -vE '^(AWR_SNAPSHOT|ESM_MODELS)$')
kinds=$(printf '%s\n%s\n%s\n' "$sev_kinds" "$anom_kinds" "$alert_kinds" | grep . | sort -u)
miss=""
for k in $kinds; do
  grep -qE "(^|[^A-Z0-9_])${k}([^A-Z0-9_]|$)" "$REF" || miss="$miss$k"$'\n'
done
report "alert kinds ($(echo $kinds | tr ' ' ',')) named in $REF" "$(echo "$kinds" | grep -c .)" "$miss"

exit $rc
