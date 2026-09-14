#!/usr/bin/env bash
# Throughput isolation: stop stickys, optional sync models-bench.ini, restore after.
# Unlike quality/sched, this suite runs llama-bench one-shot (no bench-a HTTP server).
# Lab router (:11537) is not touched.
#
#   source "$PROJECT_ROOT/tools/bench/throughput/lib/server.sh"
#   throughput_bench_prepare
#   # … llama-bench …
#   throughput_bench_cleanup
set -euo pipefail

: "${PROJECT_ROOT:?PROJECT_ROOT required}"

THROUGHPUT_SYNC_SOURCES="${THROUGHPUT_SYNC_SOURCES:-coder,chat,lab}"
THROUGHPUT_BENCH_OWNED="${THROUGHPUT_BENCH_OWNED:-0}"
THROUGHPUT_BENCH_READY="${THROUGHPUT_BENCH_READY:-0}"
VK_COMPOSE="${VK_COMPOSE:-$PROJECT_ROOT/compose.yaml}"
ROCM_COMPOSE="${ROCM_COMPOSE:-$PROJECT_ROOT/compose.rocm.yaml}"

throughput_log() { printf '[bench throughput] %s\n' "$*"; }

throughput_sync_bench_ini() {
  # shellcheck source=../../lib/python.sh
  source "$PROJECT_ROOT/tools/bench/lib/python.sh"
  # shellcheck source=../../capacity/lib/sync_ini.sh
  CAPACITY_INI_A="${CAPACITY_INI_A:-$PROJECT_ROOT/models-bench.ini}"
  CAPACITY_INI_B="${CAPACITY_INI_B:-$PROJECT_ROOT/models-bench-b.ini}"
  source "$PROJECT_ROOT/tools/bench/capacity/lib/sync_ini.sh"
  throughput_log "sync models-bench.ini from: $THROUGHPUT_SYNC_SOURCES"
  sync_bench_inis "$THROUGHPUT_SYNC_SOURCES"
}

throughput_bench_prepare() {
  if [[ "${THROUGHPUT_SKIP_BENCH:-0}" == "1" ]]; then
    throughput_log "THROUGHPUT_SKIP_BENCH=1 — no router lifecycle"
    return 0
  fi
  if [[ "$THROUGHPUT_BENCH_READY" == "1" ]]; then
    return 0
  fi
  if [[ "${THROUGHPUT_DO_SYNC:-0}" == "1" ]]; then
    throughput_sync_bench_ini
  fi
  if ! command -v docker >/dev/null 2>&1; then
    throughput_log "docker missing — skip stop routers"
    THROUGHPUT_BENCH_READY=1
    export THROUGHPUT_BENCH_READY
    return 0
  fi
  throughput_log "stop sticky routers so llama-bench owns the GPU (lab untouched)"
  (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" stop llama llama-coder llama-embeddings llama-extractor 2>/dev/null) || true
  if [[ -f "$ROCM_COMPOSE" ]]; then
    (cd "$PROJECT_ROOT" && docker compose -f "$ROCM_COMPOSE" stop llama llama-coder llama-embeddings llama-extractor 2>/dev/null) || true
  fi
  THROUGHPUT_BENCH_READY=1
  export THROUGHPUT_BENCH_READY
}

throughput_bench_cleanup() {
  if [[ "${THROUGHPUT_SKIP_BENCH:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "$THROUGHPUT_BENCH_OWNED" == "1" ]]; then
    return 0
  fi
  if [[ "$THROUGHPUT_BENCH_READY" != "1" ]]; then
    return 0
  fi
  [[ "${THROUGHPUT_NO_RESTORE:-${BENCH_NO_RESTORE:-0}}" == "1" ]] && return 0
  THROUGHPUT_BENCH_READY=0
  export THROUGHPUT_BENCH_READY
  # shellcheck source=../../lib/routers.sh
  source "$PROJECT_ROOT/tools/bench/lib/routers.sh"
  bench_restore_after_throughput || true
}
