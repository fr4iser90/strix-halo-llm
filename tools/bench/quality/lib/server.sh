#!/usr/bin/env bash
# Quality benches ALWAYS use llama-bench-a (:11601) — never sticky routers.
# Stickys are stopped for a clean GPU (same policy as capacity).
#
# Source from plugins after PROJECT_ROOT is set:
#   source "$PROJECT_ROOT/tools/bench/quality/lib/server.sh"
#   quality_bench_prepare          # once
#   quality_bench_load "$MODEL"    # per model
#   # … run suite …
#   quality_bench_cleanup          # trap EXIT
set -euo pipefail

: "${PROJECT_ROOT:?PROJECT_ROOT required}"

# shellcheck source=../../capacity/lib/common.sh
source "$PROJECT_ROOT/tools/bench/capacity/lib/common.sh"

QUALITY_URL="${QUALITY_URL:-${QUALITY_BASE_URL:-http://127.0.0.1:11601}}"
QUALITY_SYNC_SOURCES="${QUALITY_SYNC_SOURCES:-${CAPACITY_SYNC_SOURCES:-coder,chat,lab}}"
# Set by matrix when it owns lifecycle (prepare once, load per model, cleanup once)
QUALITY_BENCH_OWNED="${QUALITY_BENCH_OWNED:-0}"
QUALITY_BENCH_READY="${QUALITY_BENCH_READY:-0}"

quality_log() { printf '[bench quality] %s\n' "$*"; }

quality_bench_prepare() {
  if [[ "${QUALITY_SKIP_BENCH:-0}" == "1" ]]; then
    quality_log "QUALITY_SKIP_BENCH=1 — using QUALITY_BASE_URL as-is (no bench lifecycle)"
    return 0
  fi
  if [[ "$QUALITY_BENCH_READY" == "1" ]]; then
    return 0
  fi
  export CAPACITY_SYNC_SOURCES="$QUALITY_SYNC_SOURCES"
  export CAPACITY_AUTO_SYNC="${CAPACITY_AUTO_SYNC:-1}"
  if [[ "${CAPACITY_AUTO_SYNC}" == "1" ]]; then
    quality_log "sync models-bench.ini from: $QUALITY_SYNC_SOURCES"
    sync_bench_inis "$QUALITY_SYNC_SOURCES"
  fi
  prepare_capacity_gpu
  start_bench_a
  QUALITY_URL="http://127.0.0.1:11601"
  export QUALITY_BASE_URL="$QUALITY_URL"
  QUALITY_BENCH_READY=1
  export QUALITY_BENCH_READY
  quality_log "bench-a ready at $QUALITY_BASE_URL (stickys stopped)"
}

quality_bench_load() {
  local model="$1"
  [[ -n "$model" ]] || { quality_log "error: empty model"; return 1; }
  quality_bench_prepare
  if ! ensure_model_on_url "${CAPACITY_URL_A:-http://127.0.0.1:11601}" "$model" "quality|$model"; then
    quality_log "error: failed to load $model on bench-a"
    return 1
  fi
}

quality_bench_cleanup() {
  if [[ "${QUALITY_SKIP_BENCH:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "$QUALITY_BENCH_OWNED" == "1" ]]; then
    # Matrix owns cleanup
    return 0
  fi
  if [[ "$QUALITY_BENCH_READY" != "1" ]]; then
    return 0
  fi
  QUALITY_BENCH_READY=0
  export QUALITY_BENCH_READY
  restore_after_capacity || true
}

# Normalize URL to host without requiring /v1 yet
quality_default_base_url() {
  if [[ -n "${QUALITY_BASE_URL:-}" && "${QUALITY_SKIP_BENCH:-0}" == "1" ]]; then
    printf '%s\n' "$QUALITY_BASE_URL"
    return
  fi
  printf '%s\n' "${QUALITY_BASE_URL:-http://127.0.0.1:11601}"
}
