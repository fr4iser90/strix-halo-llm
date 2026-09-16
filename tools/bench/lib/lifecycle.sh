#!/usr/bin/env bash
# Generic inference-engine lifecycle for benches.
#
# Each engine adapter lives in tools/bench/lib/engines/<name>.sh and defines:
#   engine_<prefix>_prepare    # start server, free GPU, wait ready
#   engine_<prefix>_cleanup    # stop server, restore stickys
#   engine_<prefix>_base_url   # echo base URL (optional; falls back to engine.sh)
#
# prefix = engine id with '.' and '-' → '_'  (halogen-flash → halogen_flash)
#
# Public API:
#   bench_engine_prepare [engine]
#   bench_engine_cleanup [engine]
#   bench_engine_base_url [engine]
#   bench_engine_with_lifecycle <engine> -- <command…>   # prepare; trap cleanup; run
#
# Env:
#   BENCH_ENGINE_SKIP_LIFECYCLE=1  — never start/stop (BYO server)
#   BENCH_ENGINE_KEEP=1            — leave engine containers up after cleanup
#   BENCH_NO_RESTORE=1             — do not restore sticky routers
#
# shellcheck shell=bash

_BENCH_LIFECYCLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine.sh
source "$_BENCH_LIFECYCLE_DIR/engine.sh"
# shellcheck source=python.sh
source "$_BENCH_LIFECYCLE_DIR/python.sh"

: "${PROJECT_ROOT:=$(cd "$_BENCH_LIFECYCLE_DIR/../.." && pwd)}"

BENCH_ENGINE_READY="${BENCH_ENGINE_READY:-0}"
BENCH_ENGINE_OWNED="${BENCH_ENGINE_OWNED:-0}"
BENCH_ENGINE_ACTIVE="${BENCH_ENGINE_ACTIVE:-}"

bench_lifecycle_log() { printf '[bench lifecycle] %s\n' "$*"; }

# llama.cpp → llama_cpp ; halogen-flash → halogen_flash
bench_engine_fn_prefix() {
  local eng
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  printf '%s\n' "$eng" | tr '.-' '_'
}

# Map canonical id → adapter filename under engines/
bench_engine_adapter_file() {
  local eng
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  case "$eng" in
    llama.cpp) printf '%s\n' "$_BENCH_LIFECYCLE_DIR/engines/llama_cpp.sh" ;;
    halogen-flash) printf '%s\n' "$_BENCH_LIFECYCLE_DIR/engines/halogen.sh" ;;
    *)
      # Convention: engines/<id-with-dashes>.sh
      printf '%s\n' "$_BENCH_LIFECYCLE_DIR/engines/${eng}.sh"
      ;;
  esac
}

bench_engine_load_adapter() {
  local eng path
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  path="$(bench_engine_adapter_file "$eng")"
  [[ -f "$path" ]] || {
    printf 'error: no lifecycle adapter for engine=%s (expected %s)\n' "$eng" "$path" >&2
    return 1
  }
  # shellcheck disable=SC1090
  source "$path"
}

bench_engine_call() {
  # bench_engine_call <engine> <verb> [args…]
  local eng="$1" verb="$2"
  shift 2
  local pref fn
  pref="$(bench_engine_fn_prefix "$eng")"
  fn="engine_${pref}_${verb}"
  bench_engine_load_adapter "$eng" || return 1
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$@"
  else
    return 2
  fi
}

# Shared: free GPU by stopping sticky routers (configs untouched).
bench_engine_stop_stickys() {
  local vk="${VK_COMPOSE:-$PROJECT_ROOT/compose.yaml}"
  command -v docker >/dev/null 2>&1 || return 0
  [[ -f "$vk" ]] || return 0
  bench_lifecycle_log "stop sticky routers for clean GPU (lab untouched)"
  (cd "$PROJECT_ROOT" && docker compose -f "$vk" stop llama llama-coder llama-embeddings llama-extractor 2>/dev/null) || true
  # Also stop llama-bench if leftover from a prior suite
  if [[ -f "${BENCH_COMPOSE:-$PROJECT_ROOT/compose.bench.yaml}" ]]; then
    (cd "$PROJECT_ROOT" && docker compose -f "$vk" -f "${BENCH_COMPOSE:-$PROJECT_ROOT/compose.bench.yaml}" --profile bench stop llama-bench-a llama-bench-b 2>/dev/null) || true
  fi
}

bench_engine_restore_stickys() {
  [[ "${BENCH_NO_RESTORE:-0}" == "1" ]] && return 0
  # shellcheck source=routers.sh
  source "$_BENCH_LIFECYCLE_DIR/routers.sh"
  bench_restore_daily || true
}

bench_engine_wait_ready() {
  local url="${1:?}"
  local tries="${2:-120}"
  local i=0
  url="${url%/}"
  bench_lifecycle_log "wait ready ${url}/v1/models (tries=$tries)"
  while [[ "$i" -lt "$tries" ]]; do
    if curl -sfS --max-time 5 "${url}/v1/models" >/dev/null 2>&1; then
      bench_lifecycle_log "ready at $url"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

bench_engine_base_url() {
  local eng
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  if bench_engine_call "$eng" base_url 2>/dev/null; then
    return 0
  fi
  bench_engine_default_url "$eng"
}

bench_engine_prepare() {
  local eng
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  export BENCH_ENGINE="$eng"
  if [[ "${BENCH_ENGINE_SKIP_LIFECYCLE:-0}" == "1" ]]; then
    bench_lifecycle_log "BENCH_ENGINE_SKIP_LIFECYCLE=1 — BYO server @ $(bench_engine_base_url "$eng")"
    return 0
  fi
  if [[ "$BENCH_ENGINE_READY" == "1" && "$BENCH_ENGINE_ACTIVE" == "$eng" ]]; then
    return 0
  fi
  bench_lifecycle_log "prepare engine=$eng"
  bench_engine_call "$eng" prepare || {
    printf 'error: engine_%s_prepare failed (or missing)\n' "$(bench_engine_fn_prefix "$eng")" >&2
    return 1
  }
  BENCH_ENGINE_READY=1
  BENCH_ENGINE_OWNED=1
  BENCH_ENGINE_ACTIVE="$eng"
  export BENCH_ENGINE_READY BENCH_ENGINE_OWNED BENCH_ENGINE_ACTIVE
}

bench_engine_cleanup() {
  local eng
  eng="$(bench_engine_normalize "${1:-${BENCH_ENGINE_ACTIVE:-$BENCH_ENGINE}}")"
  if [[ "${BENCH_ENGINE_SKIP_LIFECYCLE:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${BENCH_ENGINE_OWNED:-0}" != "1" ]]; then
    return 0
  fi
  if [[ "$BENCH_ENGINE_READY" != "1" ]]; then
    return 0
  fi
  bench_lifecycle_log "cleanup engine=$eng"
  bench_engine_call "$eng" cleanup || true
  BENCH_ENGINE_READY=0
  BENCH_ENGINE_OWNED=0
  BENCH_ENGINE_ACTIVE=""
  export BENCH_ENGINE_READY BENCH_ENGINE_OWNED BENCH_ENGINE_ACTIVE
}

# prepare → trap cleanup → run command
bench_engine_with_lifecycle() {
  local eng="$1"
  shift
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  bench_engine_prepare "$eng" || return 1
  # shellcheck disable=SC2064
  trap "bench_engine_cleanup '$eng'" EXIT
  "$@"
  local rc=$?
  trap - EXIT
  bench_engine_cleanup "$eng"
  return "$rc"
}
