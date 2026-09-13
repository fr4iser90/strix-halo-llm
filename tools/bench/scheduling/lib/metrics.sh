#!/usr/bin/env bash
# Sample VRAM / GPU utilization while a scenario runs.
set -euo pipefail

metrics_start() {
  local out_csv="$1"
  local interval_ms="${SCHED_METRICS_INTERVAL_MS:-250}"
  export METRICS_OUT="$out_csv"
  export METRICS_INTERVAL_MS="$interval_ms"
  : >"$out_csv"
  echo "ts_ms,vram_used_mb,gtt_used_mb,gtt_total_mb,mem_avail_mb,gpu_pct,source" >>"$out_csv"
  bash "$SCHED_BENCH_ROOT/lib/metrics_sampler.sh" &
  METRICS_PID=$!
  export METRICS_PID
}

metrics_stop() {
  [[ -n "${METRICS_PID:-}" ]] || return 0
  kill "$METRICS_PID" 2>/dev/null || true
  wait "$METRICS_PID" 2>/dev/null || true
  unset METRICS_PID
}
