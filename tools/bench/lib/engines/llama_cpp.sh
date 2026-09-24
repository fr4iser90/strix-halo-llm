#!/usr/bin/env bash
# Engine adapter: llama.cpp
#
# Multi-instance (separate containers):
#   sticky/coder/lab/rag  — warm daily routers
#   bench a/b             — profile bench (not restored as "daily")
#
# stop_daily: snapshot which trackable services were Running, then stop them.
# restore_daily: start exactly that snapshot (not a hardcoded sticky list).
# Optional override: LLAMA_DAILY_SERVICES=… only if no snapshot was taken.
#
# shellcheck shell=bash

[[ -n "${_LLAMA_CPP_ADAPTER_LOADED:-}" ]] && return 0
_LLAMA_CPP_ADAPTER_LOADED=1

_LLAMA_ENG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../paths.sh
source "$_LLAMA_ENG_DIR/../paths.sh"
# shellcheck source=../overload.sh
source "$_LLAMA_ENG_DIR/../overload.sh"

# Snapshot of compose service names stopped for a bench (comma-separated).
# Written by stop_daily; restore_daily uses it when LLAMA_RESTORE_SNAPSHOT_TAKEN=1.
LLAMA_RESTORE_SNAPSHOT_TAKEN="${LLAMA_RESTORE_SNAPSHOT_TAKEN:-0}"

_llama_log() {
  if declare -F bench_lifecycle_log >/dev/null 2>&1; then
    bench_lifecycle_log "$*"
  else
    printf '[bench] %s\n' "$*"
  fi
}

# Services we may stop/restore for GPU benches (not llama-bench-a/b).
_llama_trackable_services() {
  printf '%s\n' llama llama-coder llama-lab llama-embeddings llama-extractor
}

# compose service → docker container_name
_llama_container_name() {
  case "$1" in
    llama) printf '%s\n' "llama-router" ;;
    llama-coder) printf '%s\n' "llama-router-coder" ;;
    llama-lab) printf '%s\n' "llama-router-lab" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

_llama_container_running() {
  local cname
  cname="$(_llama_container_name "$1")"
  docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -qx true
}

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

# Legacy helper: explicit list from env (only if no live snapshot).
engine_llama_cpp_daily_services() {
  local s
  local -a _ds=()
  [[ -v LLAMA_DAILY_SERVICES ]] || return 0
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

# Record running trackable services, then stop them for clean GPU.
engine_llama_cpp_stop_daily() {
  local -a snap=() stop_list=()
  local s
  command -v docker >/dev/null 2>&1 || {
    LLAMA_RESTORE_SNAPSHOT=""
    LLAMA_RESTORE_SNAPSHOT_TAKEN=1
    export LLAMA_RESTORE_SNAPSHOT LLAMA_RESTORE_SNAPSHOT_TAKEN
    return 0
  }

  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if _llama_container_running "$s"; then
      snap+=("$s")
      stop_list+=("$s")
    fi
  done < <(_llama_trackable_services)

  # Persist snapshot for restore (even if empty = "nothing was up")
  if [[ ${#snap[@]} -eq 0 ]]; then
    LLAMA_RESTORE_SNAPSHOT=""
  else
    local IFS=,
    LLAMA_RESTORE_SNAPSHOT="${snap[*]}"
  fi
  LLAMA_RESTORE_SNAPSHOT_TAKEN=1
  export LLAMA_RESTORE_SNAPSHOT LLAMA_RESTORE_SNAPSHOT_TAKEN
  _llama_log "llama.cpp snapshot before stop: ${LLAMA_RESTORE_SNAPSHOT:-"(none)"}"

  if [[ ${#stop_list[@]} -eq 0 ]]; then
    return 0
  fi

  local vk="${VK_COMPOSE:-$ENGINE_LLAMA_DIR/compose.yaml}"
  _llama_log "llama.cpp stop for GPU: ${stop_list[*]}"
  bench_docker_compose "$vk" stop "${stop_list[@]}" 2>/dev/null || true
  local rocm="${ROCM_COMPOSE:-$ENGINE_LLAMA_DIR/compose.rocm.yaml}"
  if [[ -f "$rocm" ]]; then
    bench_docker_compose "$rocm" stop "${stop_list[@]}" 2>/dev/null || true
  fi
}

# Restore exactly what stop_daily snapped (or LLAMA_DAILY_SERVICES if no snapshot).
engine_llama_cpp_restore_daily() {
  [[ "${BENCH_NO_RESTORE:-0}" == "1" ]] && return 0
  local backend="${BENCH_RESTORE_BACKEND:-${CAPACITY_BACKEND:-vulkan}}"
  local vk="${VK_COMPOSE:-$ENGINE_LLAMA_DIR/compose.yaml}"
  local rocm="${ROCM_COMPOSE:-$ENGINE_LLAMA_DIR/compose.rocm.yaml}"
  local -a svc=()
  local s

  if [[ "${LLAMA_RESTORE_SNAPSHOT_TAKEN:-0}" == "1" ]]; then
    # Snapshot was taken (possibly empty)
    if [[ -n "${LLAMA_RESTORE_SNAPSHOT:-}" ]]; then
      IFS=',' read -r -a svc <<< "$LLAMA_RESTORE_SNAPSHOT"
    fi
  elif [[ -v LLAMA_DAILY_SERVICES ]]; then
    mapfile -t svc < <(engine_llama_cpp_daily_services)
  else
    _llama_log "llama.cpp restore: no snapshot and no LLAMA_DAILY_SERVICES — skip"
    return 0
  fi

  # trim empties
  local -a cleaned=()
  for s in "${svc[@]}"; do
    s="${s// /}"
    [[ -n "$s" ]] && cleaned+=("$s")
  done
  svc=("${cleaned[@]}")

  if [[ ${#svc[@]} -eq 0 ]]; then
    _llama_log "llama.cpp restore: nothing was running before stop — skip"
    return 0
  fi

  _llama_log "llama.cpp restore ($backend): ${svc[*]}"

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
      # Never call `docker compose stop` with zero services — that dumps help / stops everything.
      if [[ -f "$rocm" ]]; then
        bench_docker_compose "$rocm" stop "${svc[@]}" 2>/dev/null || true
      fi
      _llama_up_named "$vk" "${svc[@]}"
      ;;
  esac
}

engine_llama_cpp_stop_bench() {
  _llama_log "llama.cpp stop bench profile"
  _llama_compose --profile bench stop llama-bench-a llama-bench-b 2>/dev/null || true
}

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
  _llama_log "llama.cpp start bench: ${targets[*]}"
  _llama_compose --profile bench up -d "${targets[@]}"
}

engine_llama_cpp_prepare() {
  _llama_log "llama.cpp ready (restore=snapshot-of-running; override LLAMA_DAILY_SERVICES if no snapshot)"
  return 0
}

engine_llama_cpp_cleanup() {
  return 0
}
