#!/usr/bin/env bash
# test/dbmint_harness.sh -- sync this checkout to the dbmint VM and run the
# fixture harness in a throwaway schema (SYSDBA + CURRENT_SCHEMA, PDB1).
#
#   test/dbmint_harness.sh <SCHEMA> [--ml] [--no-fixture] [--sql FILE]...
#
#   <SCHEMA>      target schema in PDB1 (CAPX1 etc.; must already exist with
#                 CREATE TABLE/VIEW/TYPE/PROCEDURE[/MINING MODEL] + USERS quota)
#   --ml          also run cap_forecast_ml.train_all + test/run_test_ml.sql
#   --no-fixture  skip test/fixture_install.sql (reinstall views + test only)
#   --sql FILE    run extra SQL*Plus script(s) after the tests, same session
#                 settings (handy for ad-hoc probes against the fixture)
#
# test/lint_anom_joins.sh runs first and a violation stops the run (exit 4).
# Exit status is the SQL*Plus exit status of the last failing step; the log is
# left in /tmp/dbmint_harness_<SCHEMA>.log and the RESULT / FAIL / ORA- lines
# are echoed at the end. One schema per concurrent run (see CLAUDE.md).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCHEMA=${1:?schema}; shift
ML=0; FIXTURE=1; EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ml) ML=1;;
    --no-fixture) FIXTURE=0;;
    --sql) shift; EXTRA+=("$1");;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done
REMOTE=awr_cap_$(echo "$SCHEMA" | tr 'A-Z' 'a-z')
SSH="ssh -p 2200 oracle@dbmint"
LOG=/tmp/dbmint_harness_${SCHEMA}.log

LINT_OUT=$("$HERE"/test/lint_anom_joins.sh) || { echo "$LINT_OUT"; echo "lint failed: not syncing"; exit 4; }
echo "$LINT_OUT"

rsync -az --delete -e 'ssh -p 2200' \
  --exclude .git --exclude .claude --exclude reports --exclude '__pycache__' \
  --exclude grafana/.ords.env --exclude grafana/ords/config --exclude grafana/.env \
  "$HERE"/ oracle@dbmint:~/"$REMOTE"/ || exit 3

PRE="ALTER SESSION SET CONTAINER = PDB1;
ALTER SESSION SET CURRENT_SCHEMA = $SCHEMA;"
STEPS=()
[ $FIXTURE = 1 ] && STEPS+=("@test/fixture_install.sql")
STEPS+=("DEFINE seam_mode = fixture
@install.sql")
STEPS+=("@test/run_test.sql")
[ $ML = 1 ] && STEPS+=("EXEC cap_forecast_ml.train_all
@test/run_test_ml.sql")
for f in "${EXTRA[@]+"${EXTRA[@]}"}"; do STEPS+=("@$f"); done

: > "$LOG"; rc=0
for step in "${STEPS[@]}"; do
  echo "### $step" | head -1 | tee -a "$LOG"
  $SSH 'bash -s' <<REMOTE_EOF >> "$LOG" 2>&1
export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1
cd ~/$REMOTE && sqlplus -S -L / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
$PRE
$step
EXIT
SQL
REMOTE_EOF
  src=$?
  [ $src -ne 0 ] && { echo "### step failed (exit $src)" | tee -a "$LOG"; rc=$src; break; }
done
grep -E "RESULT:|FAIL|ORA-|PLS-|SP2-|Warning: .* compilation errors|step failed" "$LOG" | grep -v "^  PASS" | head -60
echo "log: $LOG  (exit $rc)"
exit $rc
