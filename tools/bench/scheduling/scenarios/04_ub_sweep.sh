#!/usr/bin/env bash
# 04: Interleave for each ub in SCHED_UB_LIST. np fixed at SCHED_SWEEP_NP.
set -euo pipefail
SCENARIO="04_ub_sweep"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/ini_patch.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

IFS=',' read -ra UB_VALUES <<< "${SCHED_UB_LIST:-32,64,128,256}"
fix_np="${SCHED_SWEEP_NP:-2}"
restart="${SCHED_RESTART_LAB:-0}"

if [[ "$restart" == "1" ]]; then
  patch_bench_ini np "$fix_np"
fi

for ub in "${UB_VALUES[@]}"; do
  ub="${ub// /}"
  [[ -n "$ub" ]] || continue
  export SCHED_UB="$ub"
  sub="$sdir/ub_${ub}"
  mkdir -p "$sub"

  if [[ "$restart" == "1" ]]; then
    log "patch ini ub=$ub np=$fix_np and restart lab router"
    patch_bench_ini ub "$ub"
    restart_bench_patched
  else
    log "ub=$ub (set SCHED_RESTART_LAB=1 to auto-patch ini)"
  fi

  export SCHED_RUN_DIR="$sub"
  bash "$SCHED_BENCH_ROOT/scenarios/03_interleave_np2.sh"
  mv "$sub/03_interleave_np2" "$sub/run" 2>/dev/null || true
done

merge_sweep_summary "$sdir" ub
log "done $SCENARIO → $sdir/summary.json"
