#!/usr/bin/env bash
# 07: cont-batching ON vs OFF — PP solo, TG solo, interleave under load.
#
# Cont-batching is a server CLI flag, not an INI key. This scenario is the only
# place that toggles it: restart_bench_server 0|1 → ephemeral compose overlay
# (tools/bench/lib/compose_overlay.sh). After the run, bench-a is restored with
# cont-batching ON.
set -euo pipefail
SCENARIO="07_cont_batch"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/ini_patch.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

fix_np="${SCHED_SWEEP_NP:-2}"
fix_ub="${SCHED_SWEEP_UB:-128}"
fix_b="${SCHED_B:-64}"
if [[ "${SCHED_RESTART_BENCH:-0}" == "1" ]]; then
  patch_bench_ini np "$fix_np"
  patch_bench_ini ub "$fix_ub"
  patch_bench_ini b "$fix_b"
fi

for mode in cont_on cont_off; do
  sub="$sdir/$mode"
  mkdir -p "$sub"
  nocb=0
  [[ "$mode" == "cont_off" ]] && nocb=1
  log "cont-batching test: $mode (cont-batching=$([[ "$nocb" == "1" ]] && echo off || echo on))"
  restart_bench_server "$nocb"

  export SCHED_RUN_DIR="$sub/pp"
  mkdir -p "$SCHED_RUN_DIR"
  SCENARIO_DIR_NAME=pp bash "$SCHED_BENCH_ROOT/scenarios/pp_solo.sh"

  export SCHED_RUN_DIR="$sub/solo"
  mkdir -p "$SCHED_RUN_DIR"
  bash "$SCHED_BENCH_ROOT/scenarios/01_baseline_solo.sh"
  mv "$sub/solo/01_baseline_solo" "$sub/solo/run" 2>/dev/null || true

  export SCHED_RUN_DIR="$sub/interleave"
  mkdir -p "$SCHED_RUN_DIR"
  bash "$SCHED_BENCH_ROOT/scenarios/03_interleave_np2.sh"
  mv "$sub/interleave/03_interleave_np2" "$sub/interleave/run" 2>/dev/null || true
done

restart_bench_server 0
merge_cont_batch_summary "$sdir"
log "done $SCENARIO → $sdir/summary.json"
