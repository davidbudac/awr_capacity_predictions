#!/usr/bin/env bash
# bench/run_phase.sh -- run one shaped workload phase against PDB1.
#
#   ./bench/run_phase.sh <phase> [--users N] [--minutes M] [--force] [--no-snap]
#
# Phases (weekday shape):
#
#   ramp     4 users  45 min  SOE      baseline OLTP, light growth
#   peak    16 users  60 min  SOE      CPU near cpu_sat_pct, order inserts grow SOETBS
#   dss      3 users  30 min  SH       query-heavy CPU, no growth
#   mixed    8 users  45 min  SOE+SH   blended profile (2 SH users in background)
#   batch    6 users  20 min  SOE      Process/Browse Orders only: redo+undo, few inserts
#   anomaly 24 users  30 min  SOE      deliberate outlier for CAPA_* (see --anomaly below)
#
# On Saturday/Sunday only `ramp` and `dss` run; the rest self-skip unless
# --force is given. That weekday/weekend contrast is what gives the report's
# day-of-week CPU baseline (CAP_CONFIG.dow_weeks) something real to model.
#
# An AWR snapshot is forced either side of every phase so phase boundaries line
# up with snapshot boundaries instead of straddling them.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_swingbench

phase="${1:-}"; shift || true
[[ -n "$phase" ]] || { sed -n '2,25p' "$0"; exit 2; }

users=""; minutes=""; force=0; snap=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --users)   users="$2"; shift 2 ;;
        --minutes) minutes="$2"; shift 2 ;;
        --force)   force=1; shift ;;
        --no-snap) snap=0; shift ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# --- phase defaults ---------------------------------------------------------
sh_bg_users=0
extra=()
case "$phase" in
    ramp)    cfg=soe_oltp; def_users=4;  def_min=45 ;;
    peak)    cfg=soe_oltp; def_users=16; def_min=60 ;;
    dss)     cfg=sh_dss;   def_users=3;  def_min=30 ;;
    mixed)   cfg=soe_oltp; def_users=8;  def_min=45; sh_bg_users=2 ;;
    batch)   cfg=soe_oltp; def_users=6;  def_min=20; extra=(-en PO,BO,WQ,WA -di NCR,OP,UCD,BP) ;;
    anomaly) cfg=soe_oltp; def_users=24; def_min=30 ;;
    *) echo "unknown phase: $phase" >&2; exit 2 ;;
esac
users="${users:-$def_users}"
minutes="${minutes:-$def_min}"

dow=$(date +%u)
if [[ $dow -ge 6 && $force -eq 0 ]]; then
    case "$phase" in
        ramp|dss) : ;;
        *) log "weekend ($(date +%A)): skipping phase '$phase' (use --force to run it)"; exit 0 ;;
    esac
    # weekends are quieter, not just shorter
    users=$(( users > 2 ? users / 2 : 1 ))
fi

stamp="$(date +%Y%m%d_%H%M)"
tag="${stamp}_${phase}"
results="$BENCH_DIR/results/${tag}.xml"
logfile="$BENCH_DIR/logs/${tag}.log"

run_charbench() {  # <config> <user> <pass> <users> <results> [extra...]
    local config="$1" u="$2" p="$3" uc="$4" res="$5"; shift 5
    "$SWINGBENCH_HOME/bin/charbench" \
        -c  "$BENCH_DIR/configs/${config}.xml" \
        -cs "$CONNECT_STRING" -dt thin \
        -u  "$u" -p "$p" \
        -uc "$uc" -rt "0:${minutes}" \
        -a -nc -min 0 -max 0 \
        -r  "$res" -mr \
        -v  trans,tpm,resp \
        -com "capacity-bench ${phase}"
}

log "phase=$phase users=$users minutes=$minutes sh_bg=$sh_bg_users -> $logfile"
[[ $snap -eq 1 ]] && { awr_snapshot; log "AWR snapshot taken (phase start)"; }

{
    echo "### phase=$phase users=$users minutes=$minutes started $(date -Is)"

    bg_pid=""
    if [[ $sh_bg_users -gt 0 ]]; then
        run_charbench sh_dss "$SH_USER" "$SH_PASS" "$sh_bg_users" \
            "$BENCH_DIR/results/${tag}_shbg.xml" &
        bg_pid=$!
        echo "### background SH load pid=$bg_pid users=$sh_bg_users"
    fi

    # charbench's exit status must not kill the script (set -e): a phase that
    # errors should still take its closing AWR snapshot.
    rc=0
    if [[ "$cfg" == sh_dss ]]; then
        run_charbench sh_dss "$SH_USER" "$SH_PASS" "$users" "$results" "${extra[@]}" || rc=$?
    else
        run_charbench soe_oltp "$SOE_USER" "$SOE_PASS" "$users" "$results" "${extra[@]}" || rc=$?
    fi

    [[ -n "$bg_pid" ]] && { wait "$bg_pid" || true; }
    echo "### finished $(date -Is) rc=$rc"
} 2>&1 | tee -a "$logfile"

[[ $snap -eq 1 ]] && { awr_snapshot; log "AWR snapshot taken (phase end)"; }
log "phase $phase done -- results $results"
