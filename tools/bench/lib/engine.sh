#!/usr/bin/env bash
# Shared inference-engine identity for benches (llama.cpp vs halogen-flash vs …).
#
# Canonical CLI (matrix):
#   ./bench matrix --profile full --engine llama.cpp
#   ./bench matrix --profile full --engine halogen-flash --model …
#
# Env BENCH_ENGINE is the same knob (set by --engine or profile).
# `backend` (vulkan/rocm/cpu) stays the GPU path under llama.cpp.
#
# shellcheck shell=bash
: "${BENCH_ENGINE:=llama.cpp}"

# Normalize known aliases → canonical id.
bench_engine_normalize() {
  local raw="${1:-${BENCH_ENGINE:-llama.cpp}}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr ' _' '--' | sed 's/--*/-/g')"
  case "$raw" in
    ""|llama|llamacpp|llama-cpp|llama.cpp) printf '%s\n' "llama.cpp" ;;
    halogen|halogen-flash|halogenflash|flash-server|peonist-halogen)
      printf '%s\n' "halogen-flash"
      ;;
    *)
      printf '%s\n' "$raw"
      ;;
  esac
}

BENCH_ENGINE="$(bench_engine_normalize "${BENCH_ENGINE:-llama.cpp}")"
export BENCH_ENGINE

# Space-separated known engines (extend when adding a new adapter).
bench_engine_known() {
  printf '%s\n' "llama.cpp halogen-flash"
}

bench_engine_is_known() {
  local eng want
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  for want in $(bench_engine_known); do
    [[ "$eng" == "$want" ]] && return 0
  done
  return 1
}

# Human label for UI / logs.
bench_engine_label() {
  case "$(bench_engine_normalize "${1:-$BENCH_ENGINE}")" in
    llama.cpp) printf '%s\n' "llama.cpp" ;;
    halogen-flash) printf '%s\n' "Halogen Flash" ;;
    *) printf '%s\n' "$(bench_engine_normalize "${1:-$BENCH_ENGINE}")" ;;
  esac
}

# Default OpenAI-compatible base URL for an engine (no trailing /v1).
bench_engine_default_url() {
  case "$(bench_engine_normalize "${1:-$BENCH_ENGINE}")" in
    halogen-flash) printf '%s\n' "${HALOGEN_BASE_URL:-http://127.0.0.1:8731}" ;;
    *) printf '%s\n' "${QUALITY_BASE_URL:-http://127.0.0.1:11601}" ;;
  esac
}

# Infer engine from a base URL when BENCH_ENGINE was left default.
bench_engine_from_url() {
  local url="${1:-}"
  case "$url" in
    *:8731*|*:8731/*) printf '%s\n' "halogen-flash" ;;
    *) printf '%s\n' "llama.cpp" ;;
  esac
}

# Capacity cell key: keep legacy 5-part keys for llama.cpp so old ledgers resume.
# Other engines: engine|backend|mode|model|kv|c
bench_engine_cell_key_prefix() {
  local eng
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  if [[ "$eng" == "llama.cpp" ]]; then
    printf ''
  else
    printf '%s|' "$eng"
  fi
}

# Apply Halogen-friendly quality defaults when targeting that engine.
bench_engine_apply_quality_defaults() {
  local eng
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-llama.cpp}")"
  if [[ "$eng" == "halogen-flash" ]]; then
    export QUALITY_SKIP_BENCH="${QUALITY_SKIP_BENCH:-1}"
    if [[ -z "${QUALITY_BASE_URL:-}" || "${QUALITY_BASE_URL}" == *"11601"* ]]; then
      export QUALITY_BASE_URL="$(bench_engine_default_url halogen-flash)"
    fi
  fi
}

# Resolve final engine: CLI --engine > explicit BENCH_ENGINE env > profile > llama.cpp
bench_engine_resolve() {
  local cli="${1:-}"
  local profile="${2:-}"
  local env_e="${BENCH_ENGINE:-}"
  local pick="llama.cpp"
  if [[ -n "$cli" ]]; then
    pick="$cli"
  elif [[ -n "$env_e" && "$env_e" != "llama.cpp" ]]; then
    pick="$env_e"
  elif [[ -n "$profile" ]]; then
    pick="$profile"
  elif [[ -n "$env_e" ]]; then
    pick="$env_e"
  fi
  pick="$(bench_engine_normalize "$pick")"
  if ! bench_engine_is_known "$pick"; then
    printf 'error: unknown engine %s (known: %s)\n' "$pick" "$(bench_engine_known)" >&2
    return 1
  fi
  printf '%s\n' "$pick"
}
