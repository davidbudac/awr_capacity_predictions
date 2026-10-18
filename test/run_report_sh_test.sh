#!/usr/bin/env bash
# test/run_report_sh_test.sh -- report/run_report.sh exit rules, no Oracle.
# A mock sqlplus on PATH stands in for the real one; the wrapper runs in a
# temp copy of the repo so reports/ in the checkout is untouched.
#   1. sqlplus exits 1 (ORA- line printed, clean spool)  -> FAIL, non-zero
#   2. sqlplus exits 0, no ORA- line                     -> OK, exit 0
#   3. sqlplus exits 0 but the session log has an ORA-   -> FAIL, non-zero
#   4. --brief, clean                                   -> OK brief, exit 0
#   5. --brief, ORA- inside the briefing spool          -> FAIL brief, non-zero
#   6. --brief --keep 1                                 -> older cap_brief_*.html rotated away
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/run_report_test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/report" "$T/bin"
cp "$HERE/report/run_report.sh" "$T/repo/report/"

cat > "$T/bin/sqlplus" <<'MOCK'
#!/usr/bin/env bash
call=$(cat)
mkdir -p reports
echo "clean report" > reports/cap_report_mock.txt
case "$call" in
    *report_brief.sql*)
        f=reports/cap_brief_mock_209901010000.html
        if [ "${MOCK_MODE:-}" = briefora ]; then echo "ORA-00942: table or view does not exist" > $f; else echo "clean brief" > $f; fi
        echo "Report written to: $f"; exit 0 ;;
esac
case "${MOCK_MODE:-}" in
    exit1)  echo "ORA-01435: user does not exist"; echo "Report written to: reports/cap_report_mock.txt"; exit 1 ;;
    logora) echo "ORA-65011: Pluggable database does not exist"; echo "Report written to: reports/cap_report_mock.txt"; exit 0 ;;
    *)      echo "Report written to: reports/cap_report_mock.txt"; exit 0 ;;
esac
MOCK
chmod +x "$T/bin/sqlplus" "$T/repo/report/run_report.sh"

fails=0
run_case() {  # <name> <mock mode> <want exit: 0|nz> <want text> [extra wrapper args]
    # shellcheck disable=SC2086
    out=$(cd "$T/repo" && PATH="$T/bin:$PATH" MOCK_MODE="$2" report/run_report.sh "/ as sysdba" --schema NOPE ${5:-} 2>&1)
    rc=$?
    ok=1
    if [ "$3" = 0 ]; then [ $rc -eq 0 ] || ok=0; else [ $rc -ne 0 ] || ok=0; fi
    case "$out" in *"$4"*) ;; *) ok=0 ;; esac
    if [ $ok -eq 1 ]; then
        echo "PASS $1 (exit $rc)"
    else
        echo "FAIL $1: exit $rc, wanted $3 and '$4'"
        echo "$out" | sed 's/^/    /'
        fails=$((fails+1))
    fi
}

bash -n "$HERE/report/run_report.sh" || fails=$((fails+1))
run_case "sqlplus exit 1"      exit1  nz "FAIL text"
run_case "clean run"           ok     0  "OK   text"
run_case "ORA- in session log" logora nz "FAIL text"
run_case "brief clean"         ok      0  "OK   brief: reports/cap_brief_mock_209901010000.html" --brief
run_case "ORA- in brief spool" briefora nz "FAIL brief" --brief
mkdir -p "$T/repo/reports"
touch "$T/repo/reports/cap_brief_mock_202001010000.html" "$T/repo/reports/cap_brief_mock_202101010000.html"
run_case "brief rotation"      ok      0  "OK   brief" "--brief --keep 1"
left=$(cd "$T/repo/reports" && ls cap_brief_*.html)
if [ "$left" = "cap_brief_mock_209901010000.html" ]; then
    echo "PASS brief rotation keeps only the newest"
else
    echo "FAIL brief rotation left: $left"
    fails=$((fails+1))
fi
if [ $fails -eq 0 ]; then
    echo "run_report.sh test: all passed"
else
    echo "run_report.sh test: $fails failed"
    exit 1
fi
