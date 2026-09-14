#!/usr/bin/env bash
# Sample VRAM / GPU utilization / sidecar power+temp while a scenario runs.
set -euo pipefail

metrics_start() {
  local out_csv="$1"
  local interval_ms="${SCHED_METRICS_INTERVAL_MS:-250}"
  export METRICS_OUT="$out_csv"
  export METRICS_INTERVAL_MS="$interval_ms"
  # Sidecar watts/temp: off by default. Enable explicitly, e.g.:
  #   GPU_POWER_URL=http://127.0.0.1:9105/power
  #   GPU_THERMAL_URL=http://127.0.0.1:9105/thermal
  export GPU_POWER_URL="${GPU_POWER_URL:-}"
  export GPU_THERMAL_URL="${GPU_THERMAL_URL:-}"
  : >"$out_csv"
  echo "ts_ms,vram_used_mb,gtt_used_mb,gtt_total_mb,mem_avail_mb,gpu_pct,source,power_w,power_source,temp_c" >>"$out_csv"
  if [[ -z "${METRICS_SIDECAR_PROBED:-}" ]]; then
    export METRICS_SIDECAR_PROBED=1
    case "${GPU_POWER_URL}" in
      ""|off|OFF|0|false|FALSE) ;;
      *)
        if curl -sfS --connect-timeout 0.5 --max-time 1 "${GPU_POWER_URL}" >/dev/null 2>&1; then
          printf '[bench metrics] sidecar power ok → %s\n' "$GPU_POWER_URL" >&2
        else
          printf '[bench metrics] sidecar power unreachable (%s) — watts stay empty\n' \
            "$GPU_POWER_URL" >&2
        fi
        ;;
    esac
  fi
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
