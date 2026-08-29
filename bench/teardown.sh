#!/usr/bin/env bash
# bench/teardown.sh -- undo everything setup.sh did.
#
#   ./bench/teardown.sh [--schemas] [--tablespaces] [--awr]
#
# With no flags it does all three, in that order. Destructive: it drops the SOE
# and SH schemas and their tablespaces. It never touches anything outside PDB1
# except restoring the AWR snapshot settings in CDB$ROOT.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

do_schemas=0; do_tbs=0; do_awr=0
if [[ $# -eq 0 ]]; then do_schemas=1; do_tbs=1; do_awr=1; fi
for a in "$@"; do
    case "$a" in
        --schemas)     do_schemas=1 ;;
        --tablespaces) do_tbs=1 ;;
        --awr)         do_awr=1 ;;
        *) echo "unknown flag: $a" >&2; exit 2 ;;
    esac
done

read -r -p "This drops SOE/SH and their tablespaces in $DBMINT_PDB. Type YES to continue: " ans
[[ "$ans" == "YES" ]] || { echo "aborted"; exit 1; }

if [[ $do_schemas -eq 1 ]]; then
    log "dropping SOE and SH"
    "$SWINGBENCH_HOME/bin/oewizard" -cl -drop -cs "$CONNECT_STRING" -dt thin \
        -dba "$BENCH_ADMIN_USER" -dbap "$BENCH_ADMIN_PASS" -u "$SOE_USER" -p "$SOE_PASS" || true
    "$SWINGBENCH_HOME/bin/shwizard" -cl -drop -cs "$CONNECT_STRING" -dt thin \
        -dba "$BENCH_ADMIN_USER" -dbap "$BENCH_ADMIN_PASS" -u "$SH_USER" -p "$SH_PASS" || true
fi

[[ $do_tbs -eq 1 ]] && { log "dropping tablespaces + wizard account"; \
    run_sql_pdb "$BENCH_DIR/teardown.sql" "admin_user=$BENCH_ADMIN_USER"; }

[[ $do_awr -eq 1 ]] && { log "restoring AWR settings (60 min / 8 days)"; \
    echo "BEGIN DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(interval => 60, retention => 11520); END;
/" | ssh -p "$DBMINT_SSH_PORT" "${DBMINT_SSH_USER}@${DBMINT_SSH_HOST}" "${ORAENV} sqlplus -S -L / as sysdba"; }

log "teardown done"
