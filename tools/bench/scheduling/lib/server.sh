#!/usr/bin/env bash
# Sched benches use llama-bench-a (:11601) — same isolation as capacity/quality.
# Coexist scenarios keep sticky + lab (:11537); see lib/coexist.sh.
#
#   source "$SCHED_BENCH_ROOT/lib/server.sh"
#   sched_bench_prepare
#   sched_bench_load "$SCHED_MODEL"
#   # … scenarios …
#   sched_bench_cleanup
set -euo pipefail

: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${SCHED_BENCH_ROOT:?SCHED_BENCH_ROOT required}"

# shellcheck source=../../capacity/lib/common.sh
source "$PROJECT_ROOT/tools/bench/capacity/lib/common.sh"

# capacity/common.sh redefines log/die — restore sched branding
log() { printf '[bench sched] %s\n' "$*"; }
die() { printf '[bench sched] error: %s\n' "$*" >&2; exit 1; }

SCHED_SYNC_SOURCES="${SCHED_SYNC_SOURCES:-${CAPACITY_SYNC_SOURCES:-coder,chat,lab}}"
SCHED_BENCH_OWNED="${SCHED_BENCH_OWNED:-0}"
SCHED_BENCH_READY="${SCHED_BENCH_READY:-0}"

sched_bench_prepare() {
  if [[ "${SCHED_SKIP_BENCH:-0}" == "1" ]]; then
    log "SCHED_SKIP_BENCH=1 — using SCHED_BASE_URL as-is (no bench lifecycle)"
    export SCHED_BASE_URL="${SCHED_BASE_URL:-${CAPACITY_URL_A:-http://127.0.0.1:11601}}"
    return 0
  fi
  if [[ "$SCHED_BENCH_READY" == "1" ]]; then
    return 0
  fi
  export CAPACITY_SYNC_SOURCES="$SCHED_SYNC_SOURCES"
  export CAPACITY_AUTO_SYNC="${CAPACITY_AUTO_SYNC:-1}"
  if [[ "${CAPACITY_AUTO_SYNC}" == "1" ]]; then
    log "sync models-bench.ini from: $SCHED_SYNC_SOURCES"
    sync_bench_inis "$SCHED_SYNC_SOURCES"
  fi
  prepare_capacity_gpu
  start_bench_a
  export SCHED_BASE_URL="${CAPACITY_URL_A:-http://127.0.0.1:11601}"
  export SCHED_BENCH_INI="${SCHED_BENCH_INI:-${CAPACITY_INI_A:-$PROJECT_ROOT/models-bench.ini}}"
  SCHED_BENCH_READY=1
  export SCHED_BENCH_READY
  log "bench-a ready at $SCHED_BASE_URL (stickys stopped)"
}

sched_bench_load() {
  local model="${1:-${SCHED_MODEL:-}}"
  [[ -n "$model" ]] || { log "error: empty model"; return 1; }
  sched_bench_prepare
  if ! ensure_model_on_url "${CAPACITY_URL_A:-http://127.0.0.1:11601}" "$model" "sched|$model"; then
    log "error: failed to load $model on bench-a (is it in models-bench.ini?)"
    return 1
  fi
}

sched_bench_cleanup() {
  if [[ "${SCHED_SKIP_BENCH:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "$SCHED_BENCH_OWNED" == "1" ]]; then
    return 0
  fi
  if [[ "$SCHED_BENCH_READY" != "1" ]]; then
    return 0
  fi
  [[ "${SCHED_NO_RESTORE:-0}" == "1" ]] && return 0
  SCHED_BENCH_READY=0
  export SCHED_BENCH_READY
  # Map sched flag onto capacity restore
  CAPACITY_NO_RESTORE="${CAPACITY_NO_RESTORE:-0}" restore_after_capacity || true
}
