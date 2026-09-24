#!/usr/bin/env bash
# Engine adapter: gufo (OpenAI-compatible gufo serve)
#
# Required:
#   GUFO_MODELS=/path/to/gguf/tree   # mounted at /models
#   GUFO_MODEL=/models/….gguf        # path inside container (set in compose or .env)
#
# Optional:
#   GUFO_BASE_URL=http://127.0.0.1:8080
#   GUFO_COMPOSE=engines/gufo/compose.yaml
#   GUFO_PUBLISH_PORT=8080
#   BENCH_ENGINE_KEEP=1 / BENCH_ENGINE_SKIP_LIFECYCLE=1
# shellcheck shell=bash

_GUFO_ENG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../engine.sh
source "$_GUFO_ENG_DIR/../engine.sh"
# shellcheck source=../paths.sh
source "$_GUFO_ENG_DIR/../paths.sh"
# shellcheck source=../overload.sh
source "$_GUFO_ENG_DIR/../overload.sh"

GUFO_BASE_URL="${GUFO_BASE_URL:-http://127.0.0.1:${GUFO_PUBLISH_PORT:-8080}}"
GUFO_BASE_URL="${GUFO_BASE_URL%/}"
export GUFO_BASE_URL

GUFO_COMPOSE="${GUFO_COMPOSE:-$ENGINE_GUFO_DIR/compose.yaml}"
GUFO_WAIT_TRIES="${GUFO_WAIT_TRIES:-1200}"

engine_gufo_base_url() {
  printf '%s\n' "${GUFO_BASE_URL:-http://127.0.0.1:8080}"
}

# Solo until proven otherwise — multi-gufo / gufo+llama risk unknown OOM.
engine_gufo_max_instances() {
  printf '%s\n' "${GUFO_MAX_INSTANCES:-1}"
}

engine_gufo_stop_daily() { return 0; }
engine_gufo_restore_daily() { return 0; }

engine_gufo_models_dir() {
  local d candidates=()
  if [[ -n "${GUFO_MODELS:-}" && -d "${GUFO_MODELS}" ]]; then
    printf '%s\n' "$(cd "$GUFO_MODELS" && pwd)"
    return 0
  fi
  candidates=(
    "${HOME}/data/models/gguf"
    "${HOME}/data/models/gufo"
    "${PROJECT_ROOT:-}/models/gguf"
    "${PROJECT_ROOT:-}/models"
  )
  for d in "${candidates[@]}"; do
    [[ -d "$d" ]] || continue
    printf '%s\n' "$(cd "$d" && pwd)"
    return 0
  done
  return 1
}

engine_gufo_compose_cmd() {
  local root="${PROJECT_ROOT:?PROJECT_ROOT required}"
  local file="${GUFO_COMPOSE:-$ENGINE_GUFO_DIR/compose.yaml}"
  if [[ "$file" != /* ]]; then
    file="${root}/${file}"
  fi
  [[ -f "$file" ]] || {
    printf 'error: missing compose file %s (set GUFO_COMPOSE)\n' "$file" >&2
    return 1
  }
  printf '%s\n' "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
}

engine_gufo_prepare() {
  local compose compose_dir models_dir url
  url="$(engine_gufo_base_url)"
  export GUFO_BASE_URL="$url"

  if curl -sfS --max-time 3 "${url}/v1/models" >/dev/null 2>&1 \
    || curl -sfS --max-time 3 "${url}/ready" >/dev/null 2>&1; then
    bench_lifecycle_log "gufo already up at $url — reusing (borrowed)"
    export BENCH_ENGINE_BORROWED=1
    export QUALITY_BASE_URL="$url" SCHED_BASE_URL="$url" QUALITY_SKIP_BENCH=1
    return 0
  fi

  command -v docker >/dev/null 2>&1 || {
    printf 'error: docker not found — cannot start gufo\n' >&2
    return 1
  }

  models_dir="$(engine_gufo_models_dir)" || {
    printf 'error: set GUFO_MODELS to the host directory mounted at /models\n' >&2
    return 1
  }
  export GUFO_MODELS="$models_dir"
  compose="$(engine_gufo_compose_cmd)" || return 1
  compose_dir="$(dirname "$compose")"

  if declare -F bench_engine_stop_stickys >/dev/null 2>&1; then
    bench_engine_stop_stickys llama.cpp
  fi
  bench_engine_guard_start "gufo" 1 || return 1

  bench_lifecycle_log "gufo compose up (file=$compose GUFO_MODELS=$models_dir)"
  local envf=()
  [[ -f "${PROJECT_ROOT}/.env" ]] && envf=(--env-file "${PROJECT_ROOT}/.env")
  (cd "$compose_dir" && GUFO_MODELS="$models_dir" docker compose "${envf[@]}" -f "$(basename "$compose")" up -d) || {
    printf 'error: docker compose up failed for %s\n' "$compose" >&2
    printf 'hint: set GUFO_MODEL / GUFO_MODELS; Docker needs group_add video/render (not keep-groups)\n' >&2
    return 1
  }
  export BENCH_ENGINE_BORROWED=0

  # Prefer /ready (503 until loaded); fall back to /v1/models
  local i=0
  while [[ "$i" -lt "${GUFO_WAIT_TRIES}" ]]; do
    if curl -sfS --max-time 5 "${url}/ready" >/dev/null 2>&1 \
      || curl -sfS --max-time 5 "${url}/v1/models" >/dev/null 2>&1; then
      export QUALITY_BASE_URL="$url" SCHED_BASE_URL="$url" QUALITY_SKIP_BENCH=1
      bench_lifecycle_log "gufo ready"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  printf 'error: gufo not ready at %s after %ss\n' "$url" "$GUFO_WAIT_TRIES" >&2
  return 1
}

engine_gufo_cleanup() {
  local compose compose_dir

  if [[ "${BENCH_ENGINE_BORROWED:-0}" == "1" ]]; then
    bench_lifecycle_log "gufo was borrowed — not stopping"
    return 0
  fi

  compose="$(engine_gufo_compose_cmd 2>/dev/null)" || compose=""
  compose_dir="$(dirname "${compose:-.}")"

  if [[ "${BENCH_ENGINE_KEEP:-0}" == "1" ]]; then
    bench_lifecycle_log "BENCH_ENGINE_KEEP=1 — leaving gufo up"
  elif [[ -n "$compose" && -f "$compose" ]]; then
    bench_lifecycle_log "gufo compose stop"
    (cd "$compose_dir" && docker compose -f "$(basename "$compose")" stop 2>/dev/null) || true
  fi

  if declare -F bench_engine_restore_stickys >/dev/null 2>&1; then
    bench_engine_restore_stickys llama.cpp
  fi
}
