# bench/lib/common.sh -- shared helpers. Sourced, never executed.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BENCH_DIR

if [[ ! -f "$BENCH_DIR/env.sh" ]]; then
    echo "bench: $BENCH_DIR/env.sh missing -- copy env.sh.example and edit it." >&2
    exit 2
fi
# shellcheck disable=SC1091
source "$BENCH_DIR/env.sh"

mkdir -p "$BENCH_DIR/results" "$BENCH_DIR/logs"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Oracle env preamble: non-interactive ssh does not source the oracle user's
# .bashrc, so ORACLE_HOME/PATH are unset and sqlplus dies with ORA-12162.
ORAENV="export ORACLE_SID=${DBMINT_ORACLE_SID}; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1;"

_ssh() { ssh -p "$DBMINT_SSH_PORT" "${DBMINT_SSH_USER}@${DBMINT_SSH_HOST}" "$@"; }

# run_sql_root <file> [define=value ...] -- run a script in CDB$ROOT as sysdba.
run_sql_root() {
    local file="$1"; shift
    local defines=""
    for kv in "$@"; do defines+="DEFINE ${kv}"$'\n'; done
    { printf 'WHENEVER SQLERROR EXIT FAILURE\nSET DEFINE ON\n%s' "$defines"; cat "$file"; } \
        | _ssh "${ORAENV} sqlplus -S -L / as sysdba"
}

# run_sql_pdb <file> [define=value ...] -- same, but inside the PDB.
run_sql_pdb() {
    local file="$1"; shift
    local defines=""
    for kv in "$@"; do defines+="DEFINE ${kv}"$'\n'; done
    { printf 'WHENEVER SQLERROR EXIT FAILURE\nSET DEFINE ON\nALTER SESSION SET CONTAINER=%s;\n%s' \
        "$DBMINT_PDB" "$defines"; cat "$file"; } \
        | _ssh "${ORAENV} sqlplus -S -L / as sysdba"
}

# sql_pdb_inline -- ad-hoc SQL in the PDB, read from stdin.
sql_pdb_inline() {
    { printf 'SET HEADING ON PAGESIZE 100 LINESIZE 200 FEEDBACK OFF\nALTER SESSION SET CONTAINER=%s;\n' "$DBMINT_PDB"; cat; } \
        | _ssh "${ORAENV} sqlplus -S -L / as sysdba"
}

# awr_snapshot -- force an AWR snapshot so a phase boundary lands on one.
awr_snapshot() {
    echo "EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;" \
        | _ssh "${ORAENV} sqlplus -S -L / as sysdba" >/dev/null
}

require_swingbench() {
    [[ -x "$SWINGBENCH_HOME/bin/charbench" ]] \
        || { echo "bench: charbench not found under SWINGBENCH_HOME=$SWINGBENCH_HOME" >&2; exit 2; }
}
