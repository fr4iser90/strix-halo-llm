#!/usr/bin/env bash
# Engine adapter: halogen-flash
# Implements lifecycle hooks used by tools/bench/lib/lifecycle.sh
#
# Required for compose:
#   HALOGEN_MODELS=/path/to/weights   # directory with .hgn + tokenizer/ (NOT model API ids)
#
# Optional:
#   HALOGEN_BASE_URL=http://127.0.0.1:8731
#   HALOGEN_COMPOSE=compose.halogen-flash-server.yaml
#   HALOGEN_WAIT_TRIES=1200           # default ~20m (engine weight load)
#   BENCH_ENGINE_KEEP=1               # leave containers up after bench
#   BENCH_ENGINE_SKIP_LIFECYCLE=1     # BYO — do not compose up/down
#
# shellcheck shell=bash

# shellcheck source=../engine.sh
_HALOGEN_ENG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_HALOGEN_ENG_DIR/../engine.sh"

HALOGEN_BASE_URL="${HALOGEN_BASE_URL:-http://127.0.0.1:8731}"
HALOGEN_BASE_URL="${HALOGEN_BASE_URL%/}"
export HALOGEN_BASE_URL

HALOGEN_COMPOSE="${HALOGEN_COMPOSE:-compose.halogen-flash-server.yaml}"
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

# Resolve weights directory for compose HALOGEN_MODELS=.
engine_halogen_flash_models_dir() {
  local d candidates=()
  if [[ -n "${HALOGEN_MODELS:-}" && -d "${HALOGEN_MODELS}" ]]; then
    printf '%s\n' "$(cd "$HALOGEN_MODELS" && pwd)"
    return 0
  fi
  # If set but not a directory, ignore (likely mistaken model-id CSV from older docs)
  if [[ -n "${HALOGEN_MODELS:-}" && ! -d "${HALOGEN_MODELS}" ]]; then
    printf '[bench halogen] warn: HALOGEN_MODELS=%s is not a directory — searching defaults\n' \
      "$HALOGEN_MODELS" >&2
  fi
  candidates=(
    "${PROJECT_ROOT:-}/halogen-models"
    "${PROJECT_ROOT:-}/../halogen-flash-server/models"
    "${HOME}/Documents/halogen-flash-server/models"
    "${HOME}/halogen-models"
  )
  for d in "${candidates[@]}"; do
    [[ -d "$d" ]] || continue
    # Prefer dirs that look like a Halogen weights tree
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
  local file="${root}/${HALOGEN_COMPOSE}"
  [[ -f "$file" ]] || {
    printf 'error: missing %s\n' "$file" >&2
    return 1
  }
  printf '%s\n' "$file"
}

engine_halogen_flash_prepare() {
  local root="${PROJECT_ROOT:?PROJECT_ROOT required}"
  local compose models_dir url
  url="$(engine_halogen_flash_base_url)"
  export HALOGEN_BASE_URL="$url"

  # Already serving? Borrow — cleanup must not stop or restore stickys.
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
    printf 'error: set HALOGEN_MODELS to the weights directory (…/models with .hgn + tokenizer/)\n' >&2
    return 1
  }
  export HALOGEN_MODELS="$models_dir"
  compose="$(engine_halogen_flash_compose_cmd)" || return 1

  # Free GPU
  if declare -F bench_engine_stop_stickys >/dev/null 2>&1; then
    bench_engine_stop_stickys
  fi

  bench_lifecycle_log "halogen-flash compose up (HALOGEN_MODELS=$models_dir)"
  (cd "$root" && HALOGEN_MODELS="$models_dir" docker compose -f "$compose" up -d) || {
    printf 'error: docker compose up failed for %s\n' "$compose" >&2
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
  local root="${PROJECT_ROOT:?PROJECT_ROOT required}"
  local compose

  if [[ "${BENCH_ENGINE_BORROWED:-0}" == "1" ]]; then
    bench_lifecycle_log "halogen-flash was borrowed — not stopping"
    return 0
  fi

  compose="$(engine_halogen_flash_compose_cmd 2>/dev/null)" || compose=""

  if [[ "${BENCH_ENGINE_KEEP:-0}" == "1" ]]; then
    bench_lifecycle_log "BENCH_ENGINE_KEEP=1 — leaving halogen-flash up"
  elif [[ -n "$compose" && -f "$compose" ]]; then
    bench_lifecycle_log "halogen-flash compose stop"
    (cd "$root" && docker compose -f "$compose" stop 2>/dev/null) || true
  fi

  if declare -F bench_engine_restore_stickys >/dev/null 2>&1; then
    bench_engine_restore_stickys
  fi
}
