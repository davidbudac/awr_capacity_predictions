#!/usr/bin/env bash
# bench/run_day.sh -- run the whole shaped day back-to-back, now.
#
#   ./bench/run_day.sh [--short] [--anomaly] [--force]
#
# Use this for an ad-hoc session (~3.5 h full, ~50 min with --short). The cron
# schedule in cron/bench.crontab spreads the same phases across wall-clock
# hours instead, which is what actually builds day-shaped AWR history.
#
#   --short    quarter-length phases, for a smoke run
#   --anomaly  append the anomaly phase + a bulk load, so CAPA_TBSPC_ANOM and
#              CAPA_CPU_ANOM have a genuine outlier for today
#   --force    run weekday phases even at the weekend
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

short=0; anomaly=0; force=""
for a in "$@"; do
    case "$a" in
        --short)   short=1 ;;
        --anomaly) anomaly=1 ;;
        --force)   force="--force" ;;
        *) echo "unknown flag: $a" >&2; exit 2 ;;
    esac
done

scale() { local m="$1"; if [[ $short -eq 1 ]]; then echo $(( m / 4 > 0 ? m / 4 : 1 )); else echo "$m"; fi; }

log "=== shaped day starting ($(date +%A)) short=$short anomaly=$anomaly"
"$BENCH_DIR/run_phase.sh" ramp  --minutes "$(scale 45)" $force
"$BENCH_DIR/run_phase.sh" peak  --minutes "$(scale 60)" $force
"$BENCH_DIR/run_phase.sh" dss   --minutes "$(scale 30)" $force
"$BENCH_DIR/run_phase.sh" mixed --minutes "$(scale 45)" $force
"$BENCH_DIR/run_phase.sh" batch --minutes "$(scale 20)" $force

if [[ $anomaly -eq 1 ]]; then
    log "=== anomaly: bulk load + 24-user burst"
    run_sql_pdb "$BENCH_DIR/anomaly_load.sql" "owner=$SOE_USER" "mb=400"
    "$BENCH_DIR/run_phase.sh" anomaly --minutes "$(scale 30)" --force
fi

log "=== shaped day done"
