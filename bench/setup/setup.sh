#!/usr/bin/env bash
# bench/setup/setup.sh -- one-off build of the workload environment.
#
#   ./bench/setup/setup.sh [--redo] [--awr] [--tablespaces] [--soe] [--sh]
#
# --redo is never implied by the no-flag form: it swaps the online/standby redo
# groups (see 00_redo_logs.sql), which is a Data Guard change.
#
# With no flags it runs everything. Each step is idempotent-ish: the SQL steps
# swallow "already exists", the wizards refuse to overwrite an existing schema
# (drop it with bench/teardown.sh first).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_swingbench

do_redo=0; do_awr=0; do_tbs=0; do_soe=0; do_sh=0
if [[ $# -eq 0 ]]; then
    do_awr=1; do_tbs=1; do_soe=1; do_sh=1
else
    for a in "$@"; do
        case "$a" in
            --redo)        do_redo=1 ;;
            --awr)         do_awr=1 ;;
            --tablespaces) do_tbs=1 ;;
            --soe)         do_soe=1 ;;
            --sh)          do_sh=1 ;;
            *) echo "unknown flag: $a" >&2; exit 2 ;;
        esac
    done
fi

if [[ $do_redo -eq 1 ]]; then
    log "REDO: 3 x ${REDO_MB:-512} MB online + 4 x standby (CDB\$ROOT, primary)"
    run_sql_root "$BENCH_DIR/setup/00_redo_logs.sql" "redo_mb=${REDO_MB:-512}"
fi

if [[ $do_awr -eq 1 ]]; then
    log "AWR: 15-minute snapshots, 35-day retention (CDB\$ROOT)"
    run_sql_root "$BENCH_DIR/setup/01_awr_settings.sql"
fi

if [[ $do_tbs -eq 1 ]]; then
    log "PDB1: SOETBS + SHTBS (maxsize $TBS_MAXSIZE) and the $BENCH_ADMIN_USER wizard account"
    run_sql_pdb "$BENCH_DIR/setup/02_bench_objects.sql" \
        "maxsize=$TBS_MAXSIZE" "admin_user=$BENCH_ADMIN_USER" "admin_pass=$BENCH_ADMIN_PASS"
fi

# The wizards are the only heavy client-side step; -tc keeps data generation
# from swamping a 2-vCPU VM.
if [[ $do_soe -eq 1 ]]; then
    log "building SOE (Order Entry, scale $SCHEMA_SCALE) -- this takes a while"
    "$SWINGBENCH_HOME/bin/oewizard" -cl -create -v \
        -cs "$CONNECT_STRING" -dt thin -nc \
        -dba "$BENCH_ADMIN_USER" -dbap "$BENCH_ADMIN_PASS" \
        -u "$SOE_USER" -p "$SOE_PASS" \
        -ts SOETBS -scale "$SCHEMA_SCALE" -tc "$WIZARD_THREADS" \
        -part -allindexes -nocompress \
        2>&1 | tee "$BENCH_DIR/logs/oewizard_$(date +%Y%m%d_%H%M).log"
fi

if [[ $do_sh -eq 1 ]]; then
    log "building SH (Sales History, scale $SCHEMA_SCALE)"
    "$SWINGBENCH_HOME/bin/shwizard" -cl -create -v \
        -cs "$CONNECT_STRING" -dt thin -nc \
        -dba "$BENCH_ADMIN_USER" -dbap "$BENCH_ADMIN_PASS" \
        -u "$SH_USER" -p "$SH_PASS" \
        -ts SHTBS -scale "$SCHEMA_SCALE" -tc "$WIZARD_THREADS" \
        2>&1 | tee "$BENCH_DIR/logs/shwizard_$(date +%Y%m%d_%H%M).log"
fi

log "setup done"
sql_pdb_inline <<'SQL'
COLUMN tablespace_name FORMAT a20
SELECT tablespace_name,
       ROUND(SUM(bytes) / 1024 / 1024) mb,
       ROUND(SUM(maxbytes) / 1024 / 1024) max_mb
  FROM dba_data_files GROUP BY tablespace_name ORDER BY 1;
SQL
