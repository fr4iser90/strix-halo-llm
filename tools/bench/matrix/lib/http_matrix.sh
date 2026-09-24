#!/usr/bin/env bash
# Matrix helper: run full suite set for HTTP-protocol engines (halogen-flash, …).
# Suite-primary: capacity/throughput/scheduling backends + quality via --no-bench.
#
# shellcheck shell=bash

_MATRIX_HTTP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MATRIX_ROOT="$(cd "$_MATRIX_HTTP_DIR/.." && pwd)"
# Resolve from this file — ignore stale PROJECT_ROOT from .env (e.g. $HOME).
PROJECT_ROOT="$(cd "$_MATRIX_ROOT/../../.." && pwd)"
export PROJECT_ROOT

# shellcheck source=../../lib/lifecycle.sh
source "$PROJECT_ROOT/tools/bench/lib/lifecycle.sh"
# shellcheck source=../../lib/http_openai.sh
source "$PROJECT_ROOT/tools/bench/lib/http_openai.sh"

QUALITY_RUN="${QUALITY_RUN:-$PROJECT_ROOT/tools/bench/quality/run.sh}"
BUILD_INDEX="${BUILD_INDEX:-$PROJECT_ROOT/tools/bench/build-index.sh}"

matrix_http_log() { printf '[bench matrix] %s\n' "$*"; }
matrix_http_die() { printf '[bench matrix] error: %s\n' "$*" >&2; exit 1; }

MATRIX_ONLY=()

matrix_http_suite_ok() {
  local name="$1" s
  [[ ${#MATRIX_ONLY[@]} -eq 0 ]] && return 0
  for s in "${MATRIX_ONLY[@]}"; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

matrix_http_lifecycle_begin() {
  local eng="${1:?}"
  bench_engine_prepare "$eng" || matrix_http_die "$eng prepare failed"
  BENCH_HTTP_BASE_URL="$(bench_engine_base_url "$eng")"
  export BENCH_HTTP_BASE_URL
  case "$eng" in
    halogen-flash) export HALOGEN_BASE_URL="$BENCH_HTTP_BASE_URL" ;;
    gufo) export GUFO_BASE_URL="$BENCH_HTTP_BASE_URL" ;;
  esac
  export QUALITY_BASE_URL="$BENCH_HTTP_BASE_URL" SCHED_BASE_URL="$BENCH_HTTP_BASE_URL"
  # shellcheck disable=SC2064
  trap "bench_engine_cleanup '$eng'" EXIT
}

matrix_http_lifecycle_end() {
  local eng="${1:?}"
  trap - EXIT
  bench_engine_cleanup "$eng"
}

matrix_http_run_quality() {
  local eng="$1"
  matrix_http_suite_ok quality || { matrix_http_log "skip quality"; return 0; }
  export BENCH_ENGINE="$eng"
  export QUALITY_SKIP_BENCH=1
  export QUALITY_BASE_URL="${QUALITY_BASE_URL:-$BENCH_HTTP_BASE_URL}"
  local he_run="$PROJECT_ROOT/tools/bench/quality/plugins/humaneval/run.sh"
  local n_samples="${MATRIX_N_SAMPLES:-1}"
  local limit="${MATRIX_LIMIT:-0}"
  if [[ -f "$he_run" ]]; then
    matrix_http_log "HumanEval preflight…"
    bash "$he_run" --setup || matrix_http_die "HumanEval setup failed"
    local vpy="$PROJECT_ROOT/output/bench/.venv-quality/bin/python3"
    [[ -x "$vpy" ]] && export BENCH_PYTHON="$vpy" BENCH_PYTHON_MODE="$vpy"
    export HUMAN_EVAL_EXECUTE=1
    export PYTHONPATH="${PROJECT_ROOT}/tools/bench/quality/.vendor/human-eval${PYTHONPATH:+:$PYTHONPATH}"
  fi
  local models=() m qargs=(--n "$n_samples" --no-bench --eval --base-url "$QUALITY_BASE_URL")
  [[ "$limit" -gt 0 ]] && qargs+=(--limit "$limit")
  bench_http_load_models models || matrix_http_die "no models from /v1/models"
  [[ ${#models[@]} -gt 0 ]] || matrix_http_die "no models from /v1/models"
  local failed=0
  for m in "${models[@]}"; do
    [[ -n "$m" ]] || continue
    matrix_http_log "=== quality humaneval $m ==="
    if ! BENCH_ENGINE="$eng" QUALITY_MODEL="$m" QUALITY_API_MODEL="${BENCH_HTTP_API_MODEL:-}" \
      QUALITY_SKIP_BENCH=1 HUMAN_EVAL_EXECUTE=1 \
      "$QUALITY_RUN" humaneval --model "$m" "${qargs[@]}"; then
      matrix_http_log "quality FAILED for $m"
      failed=1
    fi
  done
  "$QUALITY_RUN" compare || true
  [[ "$failed" -eq 0 ]] || matrix_http_die "HTTP HumanEval failed"
}

# matrix_http_run_full <engine> [capacity|sched|throughput|quality…]
# Suite list is required from the caller (profile enabled + --only/--skip-suite).
# Empty list = error (do not silently run everything).
matrix_http_run_full() {
  local eng
  eng="$(bench_engine_normalize "${1:?}")"
  shift || true
  MATRIX_ONLY=()
  while [[ $# -gt 0 ]]; do
    MATRIX_ONLY+=("$1")
    shift
  done
  [[ ${#MATRIX_ONLY[@]} -gt 0 ]] || matrix_http_die "matrix_http_run_full: pass at least one suite"
  export BENCH_ENGINE="$eng"
  matrix_http_log "HTTP matrix engine=$eng suites=${MATRIX_ONLY[*]} @ $(bench_engine_default_url "$eng")"
  matrix_http_lifecycle_begin "$eng"
  if [[ -x "$PROJECT_ROOT/tools/bench/probe-host.sh" ]]; then
    BENCH_ENGINE="$eng" "$PROJECT_ROOT/tools/bench/probe-host.sh" || true
  fi
  if matrix_http_suite_ok capacity; then
    matrix_http_log "=== capacity (http backend) ==="
    bash "$PROJECT_ROOT/tools/bench/capacity/backends/http.sh"
  fi
  if matrix_http_suite_ok sched || matrix_http_suite_ok scheduling; then
    matrix_http_log "=== sched (http backend) ==="
    bash "$PROJECT_ROOT/tools/bench/scheduling/backends/http.sh"
  fi
  if matrix_http_suite_ok throughput; then
    matrix_http_log "=== throughput (http backend) ==="
    bash "$PROJECT_ROOT/tools/bench/throughput/backends/http.sh"
  fi
  if matrix_http_suite_ok quality; then
    matrix_http_run_quality "$eng"
  else
    matrix_http_log "skip quality"
  fi
  [[ -x "$BUILD_INDEX" ]] && "$BUILD_INDEX" || true
  matrix_http_lifecycle_end "$eng"
  matrix_http_log "HTTP matrix done — ./bench index / ./bench publish"
}

matrix_http_run_suite() {
  local eng="$1" suite="$2"
  export BENCH_ENGINE
  BENCH_ENGINE="$(bench_engine_normalize "$eng")"
  export BENCH_ENGINE
  matrix_http_lifecycle_begin "$BENCH_ENGINE"
  case "$suite" in
    capacity) bash "$PROJECT_ROOT/tools/bench/capacity/backends/http.sh" ;;
    throughput) bash "$PROJECT_ROOT/tools/bench/throughput/backends/http.sh" ;;
    sched|scheduling) bash "$PROJECT_ROOT/tools/bench/scheduling/backends/http.sh" ;;
    quality) matrix_http_run_quality "$BENCH_ENGINE" ;;
    *) matrix_http_die "unknown suite: $suite" ;;
  esac
  matrix_http_lifecycle_end "$BENCH_ENGINE"
}
