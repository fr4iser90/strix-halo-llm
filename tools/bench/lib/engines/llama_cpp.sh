#!/usr/bin/env bash
# Engine adapter: llama.cpp
#
# Multi-instance (separate containers) — only this engine supports warm stickys:
#   daily:  llama (:11535) + llama-coder (:11538)  [optional lab/rag via profiles]
#   bench:  llama-bench-a (:11601) + llama-bench-b (:11602)  [profile bench]
#
# Other GPU LLMs (halogen/gufo) stay max_instances=1 (OOM risk).
# shellcheck shell=bash

[[ -n "${_LLAMA_CPP_ADAPTER_LOADED:-}" ]] && return 0
_LLAMA_CPP_ADAPTER_LOADED=1

_LLAMA_ENG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../paths.sh
source "$_LLAMA_ENG_DIR/../paths.sh"
# shellcheck source=../overload.sh
source "$_LLAMA_ENG_DIR/../overload.sh"

# Which daily services to restore after benches (comma-separated).
# Empty string = restore nothing. Unset → sticky+coder.
# Halogen-home default: LLAMA_DAILY_SERVICES=llama-embeddings
if [[ ! -v LLAMA_DAILY_SERVICES ]]; then
  LLAMA_DAILY_SERVICES=llama,llama-coder
fi

_llama_profiles_for_services() {
  local s
  local -a out=()
  for s in "$@"; do
    case "$s" in
      llama-embeddings|llama-extractor) out+=(--profile rag) ;;
      llama-lab) out+=(--profile lab) ;;
      llama-bench-a|llama-bench-b) out+=(--profile bench) ;;
    esac
  done
  local -a uniq=() p
  for p in "${out[@]}"; do
    [[ " ${uniq[*]} " == *" $p "* ]] && continue
    uniq+=("$p")
  done
  printf '%s\n' "${uniq[@]}"
}

_llama_up_named() {
  local vk="${1:?}"
  shift
  local -a svc=("$@") profiles=()
  [[ ${#svc[@]} -eq 0 ]] && return 0
  mapfile -t profiles < <(_llama_profiles_for_services "${svc[@]}")
  if [[ ${#profiles[@]} -gt 0 ]]; then
    bench_docker_compose "$vk" "${profiles[@]}" up -d "${svc[@]}" || true
  else
    bench_docker_compose "$vk" up -d "${svc[@]}" || true
  fi
}

engine_llama_cpp_base_url() {
  printf '%s\n' "${CAPACITY_URL_A:-${QUALITY_BASE_URL:-http://127.0.0.1:11601}}"
}

engine_llama_cpp_max_instances() {
  printf '%s\n' "${LLAMA_MAX_INSTANCES:-4}"
}

engine_llama_cpp_daily_services() {
  local s
  local -a _ds=()
  IFS=',' read -r -a _ds <<< "${LLAMA_DAILY_SERVICES}"
  for s in "${_ds[@]}"; do
    s="${s// /}"
    [[ -n "$s" ]] && printf '%s\n' "$s"
  done
}

engine_llama_cpp_bench_services() {
  printf '%s\n' "llama-bench-a"
  printf '%s\n' "llama-bench-b"
}

# Compose helper: primary file; optional -f when BENCH_COMPOSE differs.
_llama_compose() {
  local vk="${VK_COMPOSE:-$ENGINE_LLAMA_DIR/compose.yaml}"
  local bench="${BENCH_COMPOSE:-$vk}"
  if [[ "$bench" == "$vk" ]] || [[ "$(basename "$bench")" == "$(basename "$vk")" ]]; then
    bench_docker_compose "$vk" "$@"
  elif [[ -f "$bench" ]]; then
    bench_docker_compose "$vk" -f "$bench" "$@"
  else
    bench_docker_compose "$vk" "$@"
  fi
}

engine_llama_cpp_stop_daily() {
  local -a svc=()
  mapfile -t svc < <(engine_llama_cpp_daily_services)
  # Always free sticky chat/coder if present (GTT)
  svc+=(llama llama-coder)
  if declare -F bench_lifecycle_log >/dev/null 2>&1; then
    bench_lifecycle_log "llama.cpp stop daily: ${svc[*]}"
  else
    printf '[bench] llama.cpp stop daily: %s\n' "${svc[*]}"
  fi
  local vk="${VK_COMPOSE:-$ENGINE_LLAMA_DIR/compose.yaml}"
  bench_docker_compose "$vk" stop "${svc[@]}" 2>/dev/null || true
  local rocm="${ROCM_COMPOSE:-$ENGINE_LLAMA_DIR/compose.rocm.yaml}"
  if [[ -f "$rocm" ]]; then
    bench_docker_compose "$rocm" stop "${svc[@]}" 2>/dev/null || true
  fi
}

engine_llama_cpp_restore_daily() {
  [[ "${BENCH_NO_RESTORE:-0}" == "1" ]] && return 0
  local backend="${BENCH_RESTORE_BACKEND:-${CAPACITY_BACKEND:-vulkan}}"
  local vk="${VK_COMPOSE:-$ENGINE_LLAMA_DIR/compose.yaml}"
  local rocm="${ROCM_COMPOSE:-$ENGINE_LLAMA_DIR/compose.rocm.yaml}"
  local -a svc=()
  mapfile -t svc < <(engine_llama_cpp_daily_services)
  if [[ ${#svc[@]} -eq 0 ]]; then
    if declare -F bench_lifecycle_log >/dev/null 2>&1; then
      bench_lifecycle_log "llama.cpp restore daily: (none — LLAMA_DAILY_SERVICES empty)"
    fi
    return 0
  fi

  if declare -F bench_lifecycle_log >/dev/null 2>&1; then
    bench_lifecycle_log "llama.cpp restore daily ($backend): ${svc[*]}"
  fi

  case "$backend" in
    rocm)
      [[ -f "$rocm" ]] || return 0
      bench_docker_compose "$vk" stop llama llama-coder llama-embeddings llama-extractor 2>/dev/null || true
      _llama_up_named "$rocm" "${svc[@]}"
      ;;
    both|all)
      _llama_up_named "$vk" "${svc[@]}"
      [[ -f "$rocm" ]] && _llama_up_named "$rocm" "${svc[@]}"
      ;;
    *)
      if [[ -f "$rocm" ]]; then
        bench_docker_compose "$rocm" stop 2>/dev/null || true
      fi
      _llama_up_named "$vk" "${svc[@]}"
      ;;
  esac
}

engine_llama_cpp_stop_bench() {
  if declare -F bench_lifecycle_log >/dev/null 2>&1; then
    bench_lifecycle_log "llama.cpp stop bench profile"
  fi
  _llama_compose --profile bench stop llama-bench-a llama-bench-b 2>/dev/null || true
}

# Start N bench routers (1 or 2). Stops daily stickys first for clean GPU.
engine_llama_cpp_start_bench() {
  local n="${1:-1}"
  local -a targets=()

  bench_engine_guard_start "llama.cpp" "$n" || return 1

  case "$n" in
    1) targets=(llama-bench-a) ;;
    2) targets=(llama-bench-a llama-bench-b) ;;
    *)
      printf 'error: llama bench instances must be 1 or 2 (got %s)\n' "$n" >&2
      return 1
      ;;
  esac

  engine_llama_cpp_stop_daily
  if declare -F bench_lifecycle_log >/dev/null 2>&1; then
    bench_lifecycle_log "llama.cpp start bench: ${targets[*]}"
  fi
  _llama_compose --profile bench up -d "${targets[@]}"
}

engine_llama_cpp_prepare() {
  if declare -F bench_lifecycle_log >/dev/null 2>&1; then
    bench_lifecycle_log "llama.cpp ready (LLAMA_DAILY_SERVICES=$LLAMA_DAILY_SERVICES; bench=profile)"
  fi
  return 0
}

engine_llama_cpp_cleanup() {
  return 0
}
