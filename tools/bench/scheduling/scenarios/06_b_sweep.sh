#!/usr/bin/env bash
# 06: Interleave (03) for each b in SCHED_B_LIST. np=2, ub fixed at SCHED_SWEEP_UB.
set -euo pipefail
SCENARIO="06_b_sweep"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/ini_patch.sh"

stamp_dir="$(run_dir)"
sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

IFS=',' read -ra B_VALUES <<< "${SCHED_B_LIST:-32,64,128,256}"
fix_ub="${SCHED_SWEEP_UB:-128}"
fix_np="${SCHED_SWEEP_NP:-2}"
restart="${SCHED_RESTART_BENCH:-0}"

if [[ "$restart" == "1" ]]; then
  patch_bench_ini ub "$fix_ub"
  patch_bench_ini np "$fix_np"
fi

for b in "${B_VALUES[@]}"; do
  b="${b// /}"
  [[ -n "$b" ]] || continue
  export SCHED_B="$b"
  sub="$sdir/b_${b}"
  mkdir -p "$sub"

  if [[ "$restart" == "1" ]]; then
    log "patch ini b=$b np=$fix_np ub=$fix_ub and restart bench-a"
    patch_bench_ini b "$b"
    restart_bench_patched
  else
    log "b=$b (set SCHED_RESTART_BENCH=1 to auto-patch ini)"
  fi

  export SCHED_RUN_DIR="$sub"
  bash "$SCHED_BENCH_ROOT/scenarios/03_interleave_np2.sh"
  mv "$sub/03_interleave_np2" "$sub/run" 2>/dev/null || true
done

export SCHED_RUN_DIR="$stamp_dir"
merge_sweep_summary "$sdir" b
[[ -f "$sdir/summary.json" ]] || die "b_sweep produced no summary.json under $sdir"
log "done $SCENARIO → $sdir/summary.json"
