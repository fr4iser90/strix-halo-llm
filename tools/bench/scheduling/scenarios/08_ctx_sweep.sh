#!/usr/bin/env bash
# 08: Solo decode + VRAM at each context size c in SCHED_C_LIST.
set -euo pipefail
SCENARIO="08_ctx_sweep"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/ini_patch.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

IFS=',' read -ra C_VALUES <<< "${SCHED_C_LIST:-16384,32768,65536,131072,262144}"
restart="${SCHED_RESTART_BENCH:-0}"

for c in "${C_VALUES[@]}"; do
  c="${c// /}"
  [[ -n "$c" ]] || continue
  sub="$sdir/c_${c}"
  mkdir -p "$sub"

  if [[ "$restart" == "1" ]]; then
    log "patch ini c=$c and restart bench-a"
    patch_bench_ini c "$c"
    patch_bench_ini fit off
    restart_bench_server 0
  else
    log "c=$c (set SCHED_RESTART_BENCH=1 to auto-patch ini)"
  fi

  export SCHED_RUN_DIR="$sub"
  if ! bash "$SCHED_BENCH_ROOT/scenarios/01_baseline_solo.sh"; then
    log "warning: c=$c failed (likely OOM) — skipping"
    rm -rf "$sub"
    continue
  fi
  mv "$sub/01_baseline_solo" "$sub/run" 2>/dev/null || true
done

merge_sweep_summary "$sdir" c
log "done $SCENARIO → $sdir/summary.json"
