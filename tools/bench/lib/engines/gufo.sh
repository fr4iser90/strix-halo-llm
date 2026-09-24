#!/usr/bin/env bash
# Engine adapter: gufo (OpenAI-compatible gufo serve)
#
# Required:
#   GUFO_MODELS=/path/to/gguf/tree   # mounted at /models (auto: ~/data/models/gguf)
#   GUFO_MODEL=/models/….gguf        # path inside container
#
# Optional:
#   GUFO_CONTEXT=262144 / GUFO_EXTRA_ARGS=--context 262144
#   GUFO_BASE_URL=http://127.0.0.1:8080
#   BENCH_ENGINE_BORROW=1   # reuse running gufo (default: always recreate for benches)
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

# Ensure GUFO_MODELS (+ context args) for any docker compose invoke.
engine_gufo_export_compose_env() {
  local models_dir
  models_dir="$(engine_gufo_models_dir)" || {
    printf 'error: set GUFO_MODELS to the host gguf root mounted at /models\n' >&2
    return 1
  }
  export GUFO_MODELS="$models_dir"
  : "${GUFO_MODEL:=/models/chat/large/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf}"
  : "${GUFO_CONTEXT:=262144}"
  : "${GUFO_SESSIONS:=4}"
  # Capacity ladder needs server context ≥ max c. Never leave EXTRA_ARGS empty.
  if [[ -z "${GUFO_EXTRA_ARGS:-}" ]]; then
    GUFO_EXTRA_ARGS="--context ${GUFO_CONTEXT}"
  elif [[ "$GUFO_EXTRA_ARGS" != *--context* ]]; then
    GUFO_EXTRA_ARGS="--context ${GUFO_CONTEXT} ${GUFO_EXTRA_ARGS}"
  fi
  export GUFO_MODEL GUFO_CONTEXT GUFO_SESSIONS GUFO_EXTRA_ARGS
  export GUFO_SPECULATIVE="${GUFO_SPECULATIVE:-}"
  export GUFO_DFLASH_MODEL="${GUFO_DFLASH_MODEL:-}"
}

engine_gufo_compose() {
  local compose compose_dir
  local -a envf=()
  engine_gufo_export_compose_env || return 1
  compose="$(engine_gufo_compose_cmd)" || return 1
  compose_dir="$(dirname "$compose")"
  [[ -f "${PROJECT_ROOT}/.env" ]] && envf=(--env-file "${PROJECT_ROOT}/.env")
  # Shell env wins over .env for MODEL / EXTRA_ARGS / MODELS (bench must control context).
  (cd "$compose_dir" && \
    GUFO_MODELS="$GUFO_MODELS" \
    GUFO_MODEL="$GUFO_MODEL" \
    GUFO_SESSIONS="${GUFO_SESSIONS:-4}" \
    GUFO_SPECULATIVE="${GUFO_SPECULATIVE:-}" \
    GUFO_DFLASH_MODEL="${GUFO_DFLASH_MODEL:-}" \
    GUFO_EXTRA_ARGS="$GUFO_EXTRA_ARGS" \
    docker compose "${envf[@]}" -f "$(basename "$compose")" "$@")
}

# Map container /models/… → host file under GUFO_MODELS; fail early if missing.
engine_gufo_assert_weights() {
  local models_dir="${1:?}"
  local cpath="${GUFO_MODEL:-/models/chat/large/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf}"
  local rel host
  rel="${cpath#/models/}"
  rel="${rel#/}"
  host="${models_dir}/${rel}"
  export GUFO_MODEL="$cpath"
  if [[ ! -f "$host" ]]; then
    printf 'error: GUFO_MODEL missing on host\n' >&2
    printf '  container: %s\n' "$cpath" >&2
    printf '  expected:  %s\n' "$host" >&2
    printf '  GUFO_MODELS=%s (must be the gguf/ root)\n' "$models_dir" >&2
    printf 'hint: ./model-dl.sh download Qwen3.8-Flash-Next-UD-Q4_K_XL  →  gguf/chat/large/\n' >&2
    printf 'hint: or set GUFO_MODEL=/models/chat/large/<file>.gguf in .env\n' >&2
    return 1
  fi
  if [[ -n "${GUFO_DFLASH_MODEL:-}" ]]; then
    rel="${GUFO_DFLASH_MODEL#/models/}"
    rel="${rel#/}"
    host="${models_dir}/${rel}"
    if [[ ! -f "$host" ]]; then
      printf 'warning: GUFO_DFLASH_MODEL missing (%s) — starting AR only\n' "$host" >&2
      unset GUFO_DFLASH_MODEL GUFO_SPECULATIVE
      export -n GUFO_DFLASH_MODEL GUFO_SPECULATIVE 2>/dev/null || true
      GUFO_DFLASH_MODEL=""
      GUFO_SPECULATIVE=""
      export GUFO_DFLASH_MODEL GUFO_SPECULATIVE
    fi
  fi
  bench_lifecycle_log "gufo weights OK: $cpath${GUFO_SPECULATIVE:+ speculative=$GUFO_SPECULATIVE}"
}

engine_gufo_wait_ready() {
  local url="${1:?}" i=0
  while [[ "$i" -lt "${GUFO_WAIT_TRIES}" ]]; do
    if curl -sfS --max-time 5 "${url}/ready" >/dev/null 2>&1 \
      || curl -sfS --max-time 5 "${url}/v1/models" >/dev/null 2>&1; then
      export QUALITY_BASE_URL="$url" SCHED_BASE_URL="$url" QUALITY_SKIP_BENCH=1
      bench_lifecycle_log "gufo ready (GUFO_EXTRA_ARGS=$GUFO_EXTRA_ARGS)"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  printf 'error: gufo not ready at %s after %ss\n' "$url" "$GUFO_WAIT_TRIES" >&2
  return 1
}

engine_gufo_prepare() {
  local url models_dir
  url="$(engine_gufo_base_url)"
  export GUFO_BASE_URL="$url"

  command -v docker >/dev/null 2>&1 || {
    printf 'error: docker not found — cannot start gufo\n' >&2
    return 1
  }

  engine_gufo_export_compose_env || return 1
  models_dir="$GUFO_MODELS"
  engine_gufo_assert_weights "$models_dir" || return 1

  # Default: never borrow. An already-up Gufo often has a tiny default context
  # and capacity/sched then fail with context_length_exceeded. Opt-in only:
  #   BENCH_ENGINE_BORROW=1 ./bench matrix --engine gufo
  if [[ "${BENCH_ENGINE_BORROW:-0}" == "1" ]] \
    && { curl -sfS --max-time 3 "${url}/v1/models" >/dev/null 2>&1 \
      || curl -sfS --max-time 3 "${url}/ready" >/dev/null 2>&1; }; then
    bench_lifecycle_log "gufo already up at $url — reusing (BENCH_ENGINE_BORROW=1)"
    export BENCH_ENGINE_BORROWED=1
    export QUALITY_BASE_URL="$url" SCHED_BASE_URL="$url" QUALITY_SKIP_BENCH=1
    return 0
  fi

  if curl -sfS --max-time 3 "${url}/v1/models" >/dev/null 2>&1 \
    || curl -sfS --max-time 3 "${url}/ready" >/dev/null 2>&1; then
    bench_lifecycle_log "gufo already up — stopping to recreate with GUFO_EXTRA_ARGS=$GUFO_EXTRA_ARGS"
    engine_gufo_compose stop 2>/dev/null || true
    engine_gufo_compose down 2>/dev/null || true
  fi

  if declare -F bench_engine_stop_stickys >/dev/null 2>&1; then
    bench_engine_stop_stickys llama.cpp
  fi
  bench_engine_guard_start "gufo" 1 || return 1

  bench_lifecycle_log "gufo compose up --force-recreate (GUFO_MODEL=$GUFO_MODEL sessions=$GUFO_SESSIONS GUFO_EXTRA_ARGS=$GUFO_EXTRA_ARGS)"
  engine_gufo_compose up -d --force-recreate || {
    printf 'error: docker compose up failed for gufo\n' >&2
    printf 'hint: set GUFO_MODEL / GUFO_MODELS; Docker needs group_add video/render\n' >&2
    return 1
  }
  export BENCH_ENGINE_BORROWED=0
  engine_gufo_wait_ready "$url"
}

engine_gufo_cleanup() {
  if [[ "${BENCH_ENGINE_BORROWED:-0}" == "1" ]]; then
    bench_lifecycle_log "gufo was borrowed — not stopping"
    return 0
  fi

  if [[ "${BENCH_ENGINE_KEEP:-0}" == "1" ]]; then
    bench_lifecycle_log "BENCH_ENGINE_KEEP=1 — leaving gufo up"
  else
    bench_lifecycle_log "gufo compose stop"
    engine_gufo_compose stop 2>/dev/null || true
  fi

  if declare -F bench_engine_restore_stickys >/dev/null 2>&1; then
    bench_engine_restore_stickys llama.cpp
  fi
}
