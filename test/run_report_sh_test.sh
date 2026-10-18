#!/usr/bin/env bash
# test/run_report_sh_test.sh -- report/run_report.sh exit rules, no Oracle.
# A mock sqlplus on PATH stands in for the real one; the wrapper runs in a
# temp copy of the repo so reports/ in the checkout is untouched.
#   1. sqlplus exits 1 (ORA- line printed, clean spool)  -> FAIL, non-zero
#   2. sqlplus exits 0, no ORA- line                     -> OK, exit 0
#   3. sqlplus exits 0 but the session log has an ORA-   -> FAIL, non-zero
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/run_report_test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/report" "$T/bin"
cp "$HERE/report/run_report.sh" "$T/repo/report/"

cat > "$T/bin/sqlplus" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
mkdir -p reports
echo "clean report" > reports/cap_report_mock.txt
case "${MOCK_MODE:-}" in
    exit1)  echo "ORA-01435: user does not exist"; echo "Report written to: reports/cap_report_mock.txt"; exit 1 ;;
    logora) echo "ORA-65011: Pluggable database does not exist"; echo "Report written to: reports/cap_report_mock.txt"; exit 0 ;;
    *)      echo "Report written to: reports/cap_report_mock.txt"; exit 0 ;;
esac
MOCK
chmod +x "$T/bin/sqlplus" "$T/repo/report/run_report.sh"

fails=0
run_case() {  # <name> <mock mode> <want exit: 0|nz> <want text>
    out=$(cd "$T/repo" && PATH="$T/bin:$PATH" MOCK_MODE="$2" report/run_report.sh "/ as sysdba" --schema NOPE 2>&1)
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
if [ $fails -eq 0 ]; then
    echo "run_report.sh test: all passed"
else
    echo "run_report.sh test: $fails failed"
    exit 1
fi
