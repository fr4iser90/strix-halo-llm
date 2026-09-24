#!/usr/bin/env bash
# Engine adapter: halogen-flash
# Implements lifecycle hooks used by tools/bench/lib/lifecycle.sh
#
# Required for compose:
#   HALOGEN_MODELS=/path/to/weights   # directory with .hgn + tokenizer/ (NOT model API ids)
#
# Optional:
#   HALOGEN_BASE_URL=http://127.0.0.1:8731
#   HALOGEN_COMPOSE=/abs/path/to/compose.yaml   # default: engines/halogen-flash/compose.yaml
#   HALOGEN_COMPOSE_DIR=/abs/workdir for compose # default: dirname(compose file)
#   HALOGEN_WAIT_TRIES=1200           # default ~20m (engine weight load)
#   BENCH_ENGINE_KEEP=1               # leave containers up after bench
#   BENCH_ENGINE_SKIP_LIFECYCLE=1     # BYO — do not compose up/down
#
# Weights live under MODELS tree, e.g. ~/data/models/hgn/qwen38flash or ./models/hgn/…
# Compose glue: engines/halogen-flash/ (image from GHCR — do not vendor upstream source).
# If Docker errors "unable to find group render": HALOGEN_GROUP_ADD=video (default)
#   or a numeric GID from `getent group video` / `ls -l /dev/dri`.
# shellcheck shell=bash

# shellcheck source=../engine.sh
_HALOGEN_ENG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_HALOGEN_ENG_DIR/../engine.sh"
# shellcheck source=../paths.sh
source "$_HALOGEN_ENG_DIR/../paths.sh"
# shellcheck source=../overload.sh
source "$_HALOGEN_ENG_DIR/../overload.sh"

HALOGEN_BASE_URL="${HALOGEN_BASE_URL:-http://127.0.0.1:8731}"
HALOGEN_BASE_URL="${HALOGEN_BASE_URL%/}"
export HALOGEN_BASE_URL

HALOGEN_COMPOSE="${HALOGEN_COMPOSE:-$ENGINE_HALOGEN_DIR/compose.yaml}"
HALOGEN_WAIT_TRIES="${HALOGEN_WAIT_TRIES:-1200}"

halogen_health() {
  local url="${1:-$HALOGEN_BASE_URL}"
  curl -fsS --max-time 5 "${url%/}/health" 2>/dev/null || return 1
}

halogen_prepare_quality_env() {
  export BENCH_ENGINE=halogen-flash
  BENCH_ENGINE="$(bench_engine_normalize halogen-flash)"
  export BENCH_ENGINE
  export QUALITY_SKIP_BENCH=1
  export QUALITY_BASE_URL="${QUALITY_BASE_URL:-$HALOGEN_BASE_URL}"
  export SCHED_BASE_URL="${SCHED_BASE_URL:-$HALOGEN_BASE_URL}"
}

engine_halogen_flash_base_url() {
  printf '%s\n' "${HALOGEN_BASE_URL:-http://127.0.0.1:8731}"
}

# Solo only — second halogen (or halogen+llama) OOMs on Strix Halo GTT.
engine_halogen_flash_max_instances() {
  printf '%s\n' "${HALOGEN_MAX_INSTANCES:-1}"
}

engine_halogen_flash_stop_daily() {
  # No warm multi-sticky; nothing of our own to stop.
  return 0
}

engine_halogen_flash_restore_daily() {
  return 0
}

# Resolve weights directory for compose HALOGEN_MODELS=.
engine_halogen_flash_models_dir() {
  local d candidates=()
  if [[ -n "${HALOGEN_MODELS:-}" && -d "${HALOGEN_MODELS}" ]]; then
    printf '%s\n' "$(cd "$HALOGEN_MODELS" && pwd)"
    return 0
  fi
  if [[ -n "${HALOGEN_MODELS:-}" && ! -d "${HALOGEN_MODELS}" ]]; then
    printf '[bench halogen] warn: HALOGEN_MODELS=%s is not a directory — searching defaults\n' \
      "$HALOGEN_MODELS" >&2
  fi
  candidates=(
    "${HOME}/data/models/hgn/qwen38flash"
    "${PROJECT_ROOT:-}/models/hgn/qwen38flash"
    "${PROJECT_ROOT:-}/halogen-models"
    "${HOME}/Documents/halogen-flash-server/models"
    "${HOME}/halogen-models"
  )
  for d in "${candidates[@]}"; do
    [[ -d "$d" ]] || continue
    if [[ -d "$d/tokenizer" ]] || compgen -G "$d"'/*.hgn' >/dev/null 2>&1; then
      printf '%s\n' "$(cd "$d" && pwd)"
      return 0
    fi
  done
  for d in "${candidates[@]}"; do
    [[ -d "$d" ]] || continue
    printf '%s\n' "$(cd "$d" && pwd)"
    return 0
  done
  return 1
}

engine_halogen_flash_compose_cmd() {
  local root="${PROJECT_ROOT:?PROJECT_ROOT required}"
  local file="${HALOGEN_COMPOSE:-$ENGINE_HALOGEN_DIR/compose.yaml}"
  if [[ "$file" != /* ]]; then
    file="${root}/${file}"
  fi
  [[ -f "$file" ]] || {
    printf 'error: missing compose file %s (set HALOGEN_COMPOSE)\n' "$file" >&2
    return 1
  }
  printf '%s\n' "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
}

engine_halogen_flash_compose_dir() {
  local compose
  if [[ -n "${HALOGEN_COMPOSE_DIR:-}" && -d "${HALOGEN_COMPOSE_DIR}" ]]; then
    printf '%s\n' "$(cd "$HALOGEN_COMPOSE_DIR" && pwd)"
    return 0
  fi
  compose="$(engine_halogen_flash_compose_cmd)" || return 1
  printf '%s\n' "$(dirname "$compose")"
}

engine_halogen_flash_prepare() {
  local compose compose_dir models_dir url
  url="$(engine_halogen_flash_base_url)"
  export HALOGEN_BASE_URL="$url"

  if curl -sfS --max-time 3 "${url}/v1/models" >/dev/null 2>&1; then
    bench_lifecycle_log "halogen-flash already up at $url — reusing (borrowed)"
    export BENCH_ENGINE_BORROWED=1
    export QUALITY_BASE_URL="$url" SCHED_BASE_URL="$url" QUALITY_SKIP_BENCH=1
    return 0
  fi

  command -v docker >/dev/null 2>&1 || {
    printf 'error: docker not found — cannot start halogen-flash\n' >&2
    return 1
  }

  models_dir="$(engine_halogen_flash_models_dir)" || {
    printf 'error: set HALOGEN_MODELS to the weights directory (…/hgn/<pack> with .hgn + tokenizer/)\n' >&2
    return 1
  }
  export HALOGEN_MODELS="$models_dir"
  compose="$(engine_halogen_flash_compose_cmd)" || return 1
  compose_dir="$(engine_halogen_flash_compose_dir)" || return 1

  # Free GTT first, then overload checks (peers / MemAvailable)
  if declare -F bench_engine_stop_stickys >/dev/null 2>&1; then
    bench_engine_stop_stickys llama.cpp
  fi
  bench_engine_guard_start "halogen-flash" 1 || return 1

  bench_lifecycle_log "halogen-flash compose up (file=$compose HALOGEN_MODELS=$models_dir)"
  local envf=()
  [[ -f "${PROJECT_ROOT}/.env" ]] && envf=(--env-file "${PROJECT_ROOT}/.env")
  (cd "$compose_dir" && HALOGEN_MODELS="$models_dir" docker compose "${envf[@]}" -f "$(basename "$compose")" up -d) || {
    printf 'error: docker compose up failed for %s\n' "$compose" >&2
    printf 'hint: check HALOGEN_MODELS, GPU devices, and group_add (Docker needs video/render, not keep-groups)\n' >&2
    printf 'hint: docker compose -f %s logs\n' "$compose" >&2
    return 1
  }
  export BENCH_ENGINE_BORROWED=0

  if ! bench_engine_wait_ready "$url" "${HALOGEN_WAIT_TRIES}"; then
    printf 'error: halogen-flash not ready at %s after %ss — check: docker compose -f %s logs\n' \
      "$url" "$HALOGEN_WAIT_TRIES" "$compose" >&2
    return 1
  fi

  export QUALITY_BASE_URL="$url" SCHED_BASE_URL="$url" QUALITY_SKIP_BENCH=1
  bench_lifecycle_log "halogen-flash ready"
}

engine_halogen_flash_cleanup() {
  local compose compose_dir

  if [[ "${BENCH_ENGINE_BORROWED:-0}" == "1" ]]; then
    bench_lifecycle_log "halogen-flash was borrowed — not stopping"
    return 0
  fi

  compose="$(engine_halogen_flash_compose_cmd 2>/dev/null)" || compose=""
  compose_dir="$(engine_halogen_flash_compose_dir 2>/dev/null)" || compose_dir="${PROJECT_ROOT:-.}"

  if [[ "${BENCH_ENGINE_KEEP:-0}" == "1" ]]; then
    bench_lifecycle_log "BENCH_ENGINE_KEEP=1 — leaving halogen-flash up"
  elif [[ -n "$compose" && -f "$compose" ]]; then
    bench_lifecycle_log "halogen-flash compose stop"
    (cd "$compose_dir" && docker compose -f "$(basename "$compose")" stop 2>/dev/null) || true
  fi

  if declare -F bench_engine_restore_stickys >/dev/null 2>&1; then
    bench_engine_restore_stickys llama.cpp
  fi
}
