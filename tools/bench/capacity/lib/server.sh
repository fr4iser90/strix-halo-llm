#!/usr/bin/env bash
# Capacity lifecycle on bench-a/b — same prepare/load/cleanup shape as quality/sched.
# Expects capacity/lib/common.sh already sourced (prepare_capacity_gpu, start_bench_*, …).
#
#   capacity_bench_prepare          # solo → bench-a
#   capacity_bench_prepare dual     # dual → bench-a + bench-b
#   capacity_bench_cleanup
set -euo pipefail

CAPACITY_BENCH_OWNED="${CAPACITY_BENCH_OWNED:-0}"
CAPACITY_BENCH_READY="${CAPACITY_BENCH_READY:-0}"

capacity_bench_prepare() {
  local mode="${1:-solo}"
  if [[ "${CAPACITY_SKIP_BENCH:-0}" == "1" ]]; then
    log "CAPACITY_SKIP_BENCH=1 — no bench lifecycle"
    return 0
  fi
  if [[ "$CAPACITY_BENCH_READY" == "1" ]]; then
    return 0
  fi
  if [[ "${CAPACITY_AUTO_SYNC:-1}" == "1" ]]; then
    log "sync models-bench.ini from: $CAPACITY_SYNC_SOURCES"
    sync_bench_inis "$CAPACITY_SYNC_SOURCES"
  fi
  prepare_capacity_gpu
  case "$mode" in
    dual|ab|both)
      start_bench_ab
      ;;
    *)
      start_bench_a
      ;;
  esac
  CAPACITY_BENCH_READY=1
  export CAPACITY_BENCH_READY
  log "bench ready mode=$mode (stickys stopped)"
}

capacity_bench_cleanup() {
  if [[ "${CAPACITY_SKIP_BENCH:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "$CAPACITY_BENCH_OWNED" == "1" ]]; then
    return 0
  fi
  if [[ "$CAPACITY_BENCH_READY" != "1" ]]; then
    return 0
  fi
  [[ "${CAPACITY_NO_RESTORE:-0}" == "1" ]] && return 0
  if [[ "${CAPACITY_AUTO_SYNC:-1}" == "1" ]]; then
    sync_bench_inis "$CAPACITY_SYNC_SOURCES" >/dev/null || true
  fi
  CAPACITY_BENCH_READY=0
  export CAPACITY_BENCH_READY
  restore_after_capacity || true
}
