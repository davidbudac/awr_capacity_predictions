#!/usr/bin/env bash
# test/lint_anom_joins.sh -- CAPA_ANOM holds one row per observation AND
# baseline mode, so a reader joining it on the observation key alone fans out.
# Observation-grain consumers join CAPA_ANOM_DAY (one row per observation by
# construction) instead. This lint keeps CAPA_ANOM readers where they are
# reviewed against that rule:
#   * SQL / Python code (comments aside) outside ddl/00 (the drop list),
#     ddl/40, ddl/45, test/, bench/ and report/drill_*.sql must not name
#     capa_anom at all (capa_anom_day is fine);
#   * in a drill script every capa_anom reference needs a "baseline_mode ="
#     predicate within the next 8 lines.
# Exit 1 and list the offenders on a violation.
set -u
cd "$(dirname "$0")/.." || exit 2
rc=0
# Comments are stripped first (SQL "--", Python "#"): prose may name the view.
mentions() {
  awk '{ sub(/--.*$/, ""); if (FILENAME ~ /\.py$/) sub(/#.*$/, ""); print tolower($0) }' "$1" \
    | grep -qE '(^|[^a-z0-9_])capa_anom([^a-z0-9_]|$)'
}
while IFS= read -r f; do
  case "$f" in
    ./ddl/00_drop.sql|./ddl/40_*|./ddl/45_*|./test/*|./bench/*|./report/drill_*.sql) continue;;
  esac
  if mentions "$f"; then
    echo "lint_anom_joins: $f reads CAPA_ANOM (join CAPA_ANOM_DAY, or move the read into ddl/45)"
    rc=1
  fi
done < <(find . \( -name .git -o -name .claude \) -prune -o -type f \( -name '*.sql' -o -name '*.py' \) -print)
for f in report/drill_*.sql; do
  [ -f "$f" ] || continue
  awk -v f="$f" '
    { line[NR] = tolower($0) }
    END {
      bad = 0
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /(^|[^a-z0-9_])capa_anom([^a-z0-9_]|$)/) {
          ok = 0
          for (j = i; j <= i + 8 && j <= NR; j++) if (line[j] ~ /baseline_mode[ \t]*=/) ok = 1
          if (!ok) { printf "lint_anom_joins: %s:%d reads CAPA_ANOM without a baseline_mode = predicate\n", f, i; bad = 1 }
        }
      }
      exit bad
    }' "$f" || rc=1
done
[ $rc = 0 ] && echo "lint_anom_joins: OK"
exit $rc
