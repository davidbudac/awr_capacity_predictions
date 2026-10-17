#!/usr/bin/env bash
#
# report/run_report.sh -- run the report drivers non-interactively (cron).
# =====================================================================
# Runs report/report.sql (always), plus report/report_html.sql (--html) and
# report/report_csv.sql (--csv), from the repo root so the @@ includes
# resolve, and checks each output: the script exits non-zero when a spool is
# missing or contains an ORA- or SP2- line. Prints the path of every file it
# wrote. Read-only against the database, like the drivers.
#
# Usage:
#   report/run_report.sh [connect] [--html] [--csv] [--scope dbid[:con_dbid]]
#                        [--snapshot] [--keep N] [--container PDB]
#                        [--schema OWNER]
#     connect        sqlplus connect string, default "/ as sysdba" (quote it)
#     --html         also write the HTML report
#     --csv          also write the CSV directory
#     --scope D[:C]  only dbid D (and con_dbid C); C alone: --scope -:C
#     --snapshot     read the alert list and the section 1 / 7 fits from the
#                    last refresh run (CAP_RESULTS.refresh) instead of live
#     --keep N       after a good run, keep only the newest N reports of each
#                    kind in reports/ (text, HTML, CSV directories)
#     --container P  ALTER SESSION SET CONTAINER = P first (SYSDBA runs)
#     --schema O     ALTER SESSION SET CURRENT_SCHEMA = O first (an install
#                    owned by another schema, read as SYSDBA)
#   top_n / anomaly_days / show_esm come from report/defaults.sql.
#
# Cron example (daily 06:30, as the oracle user, environment from oraenv):
#   30 6 * * * . /home/oracle/.bash_profile; /opt/awrcap/report/run_report.sh "/ as sysdba" --html --keep 14 >> /var/log/awrcap_report.log 2>&1
#
set -u

cd "$(dirname "$0")/.." || exit 2

conn="/ as sysdba"
do_html=0
do_csv=0
keep=""
sdbid="-"
scon="-"
source="LIVE"
container=""
schema=""

if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
    conn="$1"
    shift
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --html)      do_html=1 ;;
        --csv)       do_csv=1 ;;
        --snapshot)  source="SNAPSHOT" ;;
        --keep)      shift; keep="${1:-}" ;;
        --scope)     shift
                     sdbid="${1%%:*}"
                     case "$1" in *:*) scon="${1#*:}" ;; esac ;;
        --container) shift; container="${1:-}" ;;
        --schema)    shift; schema="${1:-}" ;;
        -h|--help)   sed -n '2,32p' "$0"; exit 0 ;;
        *)           echo "run_report.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done

for v in "$sdbid" "$scon"; do
    case "$v" in -|'') ;; *[!0-9]*) echo "run_report.sh: --scope wants digits, got '$v'" >&2; exit 2 ;; esac
done
[ -z "$sdbid" ] && sdbid="-"
[ -z "$scon" ] && scon="-"
case "$keep" in ''|*[!0-9]*) [ -n "$keep" ] && { echo "run_report.sh: --keep wants a number" >&2; exit 2; } ;; esac
case "$container$schema" in *[!A-Za-z0-9_\$#]*) echo "run_report.sh: bad --container / --schema name" >&2; exit 2 ;; esac

command -v sqlplus >/dev/null 2>&1 || { echo "run_report.sh: sqlplus not on PATH" >&2; exit 2; }
mkdir -p reports

pre=""
[ -n "$container" ] && pre="${pre}ALTER SESSION SET CONTAINER = ${container};"$'\n'
[ -n "$schema" ]    && pre="${pre}ALTER SESSION SET CURRENT_SCHEMA = ${schema};"$'\n'

rc=0
log="$(mktemp "${TMPDIR:-/tmp}/awrcap_report.XXXXXX")"
trap 'rm -f "$log"' EXIT

# run_driver <label> <marker> <driver call>: runs one driver, finds the path it
# printed after <marker>, and checks it. A directory (CSV) is checked file by
# file.
run_driver() {
    label="$1"; marker="$2"; call="$3"
    sqlplus -S -L "$conn" > "$log" 2>&1 <<SQL
WHENEVER OSERROR EXIT 9
${pre}${call}
EXIT
SQL
    out="$(sed -n "s/^${marker} *//p" "$log" | tail -1)"
    if [ -z "$out" ] || [ ! -e "$out" ]; then
        echo "FAIL $label: no output file (sqlplus said:)" >&2
        grep -E 'ORA-|SP2-|ERROR' "$log" | head -5 >&2
        rc=1
        return
    fi
    if grep -q -r -E '(ORA|SP2)-[0-9]{4,5}' "$out"; then
        echo "FAIL $label: $out contains errors:" >&2
        grep -h -E '(ORA|SP2)-[0-9]{4,5}' -r "$out" | head -5 >&2
        rc=1
        return
    fi
    echo "OK   $label: $out"
}

run_driver "text" "Report written to:" "@report/report.sql - - - $sdbid $scon $source"
[ $do_html -eq 1 ] && run_driver "html" "Report written to:" "@report/report_html.sql - - - $sdbid $scon $source"
[ $do_csv  -eq 1 ] && run_driver "csv"  "CSV written to:"    "@report/report_csv.sql $sdbid $scon"

# Rotation only after a clean run, so a failing job never deletes the last
# good reports.
if [ $rc -eq 0 ] && [ -n "$keep" ]; then
    for pat in 'cap_report_*.txt' 'cap_report_*.html' 'cap_csv_*'; do
        # names carry a sortable timestamp, newest last
        ls -1d reports/$pat 2>/dev/null | sort | head -n -"$keep" | while read -r old; do
            rm -rf -- "$old"
        done
    done
fi
exit $rc
