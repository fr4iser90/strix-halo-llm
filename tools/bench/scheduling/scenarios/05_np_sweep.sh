#!/usr/bin/env bash
# 05: Interleave (03) for each np in SCHED_NP_LIST. ub fixed at SCHED_SWEEP_UB.
set -euo pipefail
SCENARIO="05_np_sweep"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/ini_patch.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

IFS=',' read -ra NP_VALUES <<< "${SCHED_NP_LIST:-1,2,4}"
fix_ub="${SCHED_SWEEP_UB:-128}"
restart="${SCHED_RESTART_LAB:-0}"

if [[ "$restart" == "1" ]]; then
  patch_lab_ini ub "$fix_ub"
fi

for np in "${NP_VALUES[@]}"; do
  np="${np// /}"
  [[ -n "$np" ]] || continue
  export SCHED_NP="$np"
  sub="$sdir/np_${np}"
  mkdir -p "$sub"

  if [[ "$restart" == "1" ]]; then
    log "patch ini np=$np ub=$fix_ub and restart lab router"
    patch_lab_ini np "$np"
    restart_lab_patched
  else
    log "np=$np (set SCHED_RESTART_LAB=1 to auto-patch ini)"
  fi

  export SCHED_RUN_DIR="$sub"
  bash "$SCHED_BENCH_ROOT/scenarios/03_interleave_np2.sh"
  mv "$sub/03_interleave_np2" "$sub/run" 2>/dev/null || true
done

merge_sweep_summary "$sdir" np
log "done $SCENARIO → $sdir/summary.json"
