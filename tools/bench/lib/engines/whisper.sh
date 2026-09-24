#!/usr/bin/env bash
# Engine adapter: whisper (STT / whisper.cpp server)
# Same lifecycle contract as halogen/gufo/piper.
# shellcheck shell=bash

_WHISPER_ENG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../engine.sh
source "$_WHISPER_ENG_DIR/../engine.sh"
# shellcheck source=../paths.sh
source "$_WHISPER_ENG_DIR/../paths.sh"

WHISPER_BASE_URL="${WHISPER_BASE_URL:-http://127.0.0.1:${WHISPER_PUBLISH_PORT:-9000}}"
WHISPER_BASE_URL="${WHISPER_BASE_URL%/}"
export WHISPER_BASE_URL

WHISPER_COMPOSE="${WHISPER_COMPOSE:-$ENGINE_WHISPER_DIR/compose.yaml}"
WHISPER_WAIT_TRIES="${WHISPER_WAIT_TRIES:-600}"

engine_whisper_base_url() {
  printf '%s\n' "${WHISPER_BASE_URL:-http://127.0.0.1:9000}"
}

engine_whisper_max_instances() {
  printf '%s\n' "1"
}

engine_whisper_compose_cmd() {
  local root="${PROJECT_ROOT:?}"
  local file="${WHISPER_COMPOSE:-$ENGINE_WHISPER_DIR/compose.yaml}"
  [[ "$file" != /* ]] && file="${root}/${file}"
  [[ -f "$file" ]] || { printf 'error: missing %s\n' "$file" >&2; return 1; }
  printf '%s\n' "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
}

engine_whisper_prepare() {
  local url compose compose_dir
  url="$(engine_whisper_base_url)"
  export WHISPER_BASE_URL="$url"

  if curl -sfS --max-time 3 "${url}/" >/dev/null 2>&1; then
    bench_lifecycle_log "whisper already up at $url — borrowed"
    export BENCH_ENGINE_BORROWED=1
    return 0
  fi

  command -v docker >/dev/null 2>&1 || {
    printf 'error: docker not found\n' >&2
    return 1
  }
  [[ -d "${STT_MODELS:-}" ]] || {
    printf 'error: set STT_MODELS (whisper model dir)\n' >&2
    return 1
  }
  STT_MODELS="$(cd "$STT_MODELS" && pwd)"
  : "${WHISPER_MODEL:=ggml-large-v3.bin}"
  [[ -f "${STT_MODELS}/${WHISPER_MODEL}" ]] || {
    printf 'error: whisper weights missing: %s/%s\n' "$STT_MODELS" "$WHISPER_MODEL" >&2
    return 1
  }

  compose="$(engine_whisper_compose_cmd)" || return 1
  compose_dir="$(dirname "$compose")"
  bench_lifecycle_log "whisper compose up STT_MODELS=$STT_MODELS model=$WHISPER_MODEL"
  local envf=()
  [[ -f "${PROJECT_ROOT}/.env" ]] && envf=(--env-file "${PROJECT_ROOT}/.env")
  (cd "$compose_dir" && \
    STT_MODELS="$STT_MODELS" WHISPER_MODEL="$WHISPER_MODEL" \
    docker compose "${envf[@]}" -f "$(basename "$compose")" up -d --build --force-recreate) || return 1
  export BENCH_ENGINE_BORROWED=0

  local i=0
  while [[ "$i" -lt "${WHISPER_WAIT_TRIES}" ]]; do
    if curl -sfS --max-time 3 "${url}/" >/dev/null 2>&1; then
      bench_lifecycle_log "whisper ready"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  printf 'error: whisper not ready at %s\n' "$url" >&2
  return 1
}

engine_whisper_cleanup() {
  local compose compose_dir
  if [[ "${BENCH_ENGINE_BORROWED:-0}" == "1" ]]; then
    bench_lifecycle_log "whisper borrowed — not stopping"
    return 0
  fi
  if [[ "${BENCH_ENGINE_KEEP:-0}" == "1" ]]; then
    bench_lifecycle_log "BENCH_ENGINE_KEEP=1 — leaving whisper up"
    return 0
  fi
  compose="$(engine_whisper_compose_cmd 2>/dev/null)" || return 0
  compose_dir="$(dirname "$compose")"
  bench_lifecycle_log "whisper compose stop"
  (cd "$compose_dir" && docker compose -f "$(basename "$compose")" stop 2>/dev/null) || true
}
