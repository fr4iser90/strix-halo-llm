#!/usr/bin/env bash
# Generic inference-engine lifecycle for benches.
#
# Each engine adapter lives in tools/bench/lib/engines/<name>.sh and defines:
#   engine_<prefix>_prepare         # start server, free GPU, wait ready
#   engine_<prefix>_cleanup         # stop server, restore stickys
#   engine_<prefix>_base_url        # echo base URL
#   engine_<prefix>_max_instances   # optional; default via overload.sh
#   engine_<prefix>_stop_daily      # optional; free GPU / stop warm routers
#   engine_<prefix>_restore_daily   # optional; bring warm routers back
#   engine_<prefix>_start_bench N   # optional; llama multi-instance bench
#
# prefix = engine id with '.' and '-' → '_'  (halogen-flash → halogen_flash)
#
# Public API:
#   bench_engine_prepare [engine]
#   bench_engine_cleanup [engine]
#   bench_engine_base_url [engine]
#   bench_engine_stop_stickys / bench_engine_restore_stickys  # → adapters
#   bench_engine_with_lifecycle <engine> -- <command…>
#
# Env:
#   BENCH_ENGINE_SKIP_LIFECYCLE=1  — never start/stop (BYO server)
#   BENCH_ENGINE_KEEP=1            — leave engine containers up after cleanup
#   BENCH_NO_RESTORE=1             — do not restore sticky routers / peer engines
#   ENGINE_FORCE_OVERLOAD=1        — skip MemAvailable / solo peer checks
#   LLAMA_DAILY_SERVICES=llama,llama-coder  — which stickys to restore
#
# Solo GPU prepare: evicts live foreign peers (halogen↔gufo), snapshots them,
# restores after cleanup (same idea as llama stop_daily / restore_daily).
#
# shellcheck shell=bash

[[ -n "${_BENCH_LIFECYCLE_LOADED:-}" ]] && return 0
_BENCH_LIFECYCLE_LOADED=1

_BENCH_LIFECYCLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PROJECT_ROOT:=$(cd "$_BENCH_LIFECYCLE_DIR/../../.." && pwd)}"
# shellcheck source=paths.sh
source "$_BENCH_LIFECYCLE_DIR/paths.sh"
# shellcheck source=engine.sh
source "$_BENCH_LIFECYCLE_DIR/engine.sh"
# shellcheck source=python.sh
source "$_BENCH_LIFECYCLE_DIR/python.sh"
# shellcheck source=overload.sh
source "$_BENCH_LIFECYCLE_DIR/overload.sh"

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
    gufo) printf '%s\n' "$_BENCH_LIFECYCLE_DIR/engines/gufo.sh" ;;
    piper) printf '%s\n' "$_BENCH_LIFECYCLE_DIR/engines/piper.sh" ;;
    whisper) printf '%s\n' "$_BENCH_LIFECYCLE_DIR/engines/whisper.sh" ;;
    *)
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

# Free GPU: prefer active/target engine adapter, else llama.cpp (warm stickys).
bench_engine_stop_stickys() {
  local eng="${1:-${BENCH_ENGINE_ACTIVE:-llama.cpp}}"
  command -v docker >/dev/null 2>&1 || return 0
  if bench_engine_call "$eng" stop_daily 2>/dev/null; then
    return 0
  fi
  # Fallback: llama daily routers
  bench_engine_call "llama.cpp" stop_daily 2>/dev/null || true
}

bench_engine_restore_stickys() {
  [[ "${BENCH_NO_RESTORE:-0}" == "1" ]] && return 0
  local eng="${1:-llama.cpp}"
  if bench_engine_call "$eng" restore_daily 2>/dev/null; then
    return 0
  fi
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
  # Solo GPU engines: stop foreign halogen/gufo first (snapshot for restore).
  if bench_engine_is_gpu_llm "$eng" 2>/dev/null; then
    bench_engine_evict_peers "$eng" || true
  fi
  bench_engine_call "$eng" prepare || {
    bench_engine_restore_peers || true
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
  # Restore halogen/gufo that prepare evicted (after this engine is down).
  bench_engine_restore_peers || true
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
