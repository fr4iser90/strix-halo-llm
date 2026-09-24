#!/usr/bin/env bash
# Engine adapter: piper (TTS)
# Same lifecycle contract as halogen/gufo: prepare / cleanup / base_url
# shellcheck shell=bash

_PIPER_ENG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../engine.sh
source "$_PIPER_ENG_DIR/../engine.sh"
# shellcheck source=../paths.sh
source "$_PIPER_ENG_DIR/../paths.sh"

PIPER_BASE_URL="${PIPER_BASE_URL:-http://127.0.0.1:${PIPER_PUBLISH_PORT:-9001}}"
PIPER_BASE_URL="${PIPER_BASE_URL%/}"
export PIPER_BASE_URL

PIPER_COMPOSE="${PIPER_COMPOSE:-$ENGINE_PIPER_DIR/compose.yaml}"
PIPER_WAIT_TRIES="${PIPER_WAIT_TRIES:-120}"

engine_piper_base_url() {
  printf '%s\n' "${PIPER_BASE_URL:-http://127.0.0.1:9001}"
}

engine_piper_max_instances() {
  printf '%s\n' "1"
}

engine_piper_compose_cmd() {
  local root="${PROJECT_ROOT:?}"
  local file="${PIPER_COMPOSE:-$ENGINE_PIPER_DIR/compose.yaml}"
  [[ "$file" != /* ]] && file="${root}/${file}"
  [[ -f "$file" ]] || { printf 'error: missing %s\n' "$file" >&2; return 1; }
  printf '%s\n' "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
}

engine_piper_prepare() {
  local url compose compose_dir
  url="$(engine_piper_base_url)"
  export PIPER_BASE_URL="$url"

  if curl -sfS --max-time 3 "${url}/health" >/dev/null 2>&1 \
    || curl -sfS --max-time 3 "${url}/" >/dev/null 2>&1; then
    bench_lifecycle_log "piper already up at $url — borrowed"
    export BENCH_ENGINE_BORROWED=1
    return 0
  fi

  command -v docker >/dev/null 2>&1 || {
    printf 'error: docker not found\n' >&2
    return 1
  }
  [[ -d "${TTS_MODELS:-}" ]] || {
    printf 'error: set TTS_MODELS (piper voices dir)\n' >&2
    return 1
  }

  compose="$(engine_piper_compose_cmd)" || return 1
  compose_dir="$(dirname "$compose")"
  bench_lifecycle_log "piper compose up TTS_MODELS=$TTS_MODELS"
  local envf=()
  [[ -f "${PROJECT_ROOT}/.env" ]] && envf=(--env-file "${PROJECT_ROOT}/.env")
  (cd "$compose_dir" && TTS_MODELS="$TTS_MODELS" docker compose "${envf[@]}" -f "$(basename "$compose")" up -d --build) || return 1
  export BENCH_ENGINE_BORROWED=0

  local i=0
  while [[ "$i" -lt "${PIPER_WAIT_TRIES}" ]]; do
    if curl -sfS --max-time 3 "${url}/health" >/dev/null 2>&1 \
      || curl -sfS --max-time 3 "${url}/" >/dev/null 2>&1; then
      bench_lifecycle_log "piper ready"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  printf 'error: piper not ready at %s\n' "$url" >&2
  return 1
}

engine_piper_cleanup() {
  local compose compose_dir
  if [[ "${BENCH_ENGINE_BORROWED:-0}" == "1" ]]; then
    bench_lifecycle_log "piper borrowed — not stopping"
    return 0
  fi
  if [[ "${BENCH_ENGINE_KEEP:-0}" == "1" ]]; then
    bench_lifecycle_log "BENCH_ENGINE_KEEP=1 — leaving piper up"
    return 0
  fi
  compose="$(engine_piper_compose_cmd 2>/dev/null)" || return 0
  compose_dir="$(dirname "$compose")"
  bench_lifecycle_log "piper compose stop"
  (cd "$compose_dir" && docker compose -f "$(basename "$compose")" stop 2>/dev/null) || true
}
