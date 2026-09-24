#!/usr/bin/env bash
# Shared repo / engine / models paths for benches and helpers.
# Source after PROJECT_ROOT is set (or let this file derive it).
# shellcheck shell=bash

_BENCH_PATHS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PROJECT_ROOT:=$(cd "$_BENCH_PATHS_DIR/../../.." && pwd)}"

# Engine glue (compose + presets) lives under engines/<name>/
ENGINE_LLAMA_DIR="${ENGINE_LLAMA_DIR:-$PROJECT_ROOT/engines/llama-cpp}"
ENGINE_HALOGEN_DIR="${ENGINE_HALOGEN_DIR:-$PROJECT_ROOT/engines/halogen-flash}"
ENGINE_GUFO_DIR="${ENGINE_GUFO_DIR:-$PROJECT_ROOT/engines/gufo}"
ENGINE_PIPER_DIR="${ENGINE_PIPER_DIR:-$PROJECT_ROOT/engines/piper}"
ENGINE_WHISPER_DIR="${ENGINE_WHISPER_DIR:-$PROJECT_ROOT/engines/whisper-cpp}"

# Weights parent: gguf/ · hgn/ · stt/ · tts/
# Default without .env: ~/data/models if it exists, else <repo>/models
if [[ -z "${MODELS_ROOT:-}" ]]; then
  if [[ -d "${HOME}/data/models" ]]; then
    MODELS_ROOT="${HOME}/data/models"
  else
    MODELS_ROOT="${PROJECT_ROOT}/models"
  fi
fi
MODELS_DIR="${MODELS_DIR:-$MODELS_ROOT/gguf}"
TTS_MODELS="${TTS_MODELS:-$MODELS_ROOT/tts}"
STT_MODELS="${STT_MODELS:-$MODELS_ROOT/stt}"
# Halogen pack (optional until ./stack up halogen)
HALOGEN_MODELS="${HALOGEN_MODELS:-$MODELS_ROOT/hgn/qwen38flash}"
# Gufo mounts gguf root
GUFO_MODELS="${GUFO_MODELS:-$MODELS_DIR}"

# Home-stack defaults without .env (Gufo Flash-Next Q4 + embeddings + voice — no sticky)
: "${STACK_ENGINES:=gufo,llama,piper,whisper}"
: "${LLAMA_SERVICES:=llama-embeddings}"
: "${SMOKE_ENGINES:=gufo,piper,whisper}"
: "${GUFO_MODEL:=/models/chat/large/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf}"
: "${GUFO_CONTEXT:=262144}"
: "${GUFO_EXTRA_ARGS:=--context ${GUFO_CONTEXT}}"
export GUFO_MODEL GUFO_CONTEXT GUFO_EXTRA_ARGS
# LLAMA_DAILY_SERVICES: optional override only — restore prefers live snapshot from stop_daily

# Live llama.ini presets next to compose (templates: engines/llama-cpp/presets/ini/)
LLAMA_INI_DIR="${LLAMA_INI_DIR:-$ENGINE_LLAMA_DIR}"

# Compose defaults (bench routers = profile "bench" in the same file)
VK_COMPOSE="${VK_COMPOSE:-$ENGINE_LLAMA_DIR/compose.yaml}"
ROCM_COMPOSE="${ROCM_COMPOSE:-$ENGINE_LLAMA_DIR/compose.rocm.yaml}"
BENCH_COMPOSE="${BENCH_COMPOSE:-$VK_COMPOSE}"
HALOGEN_COMPOSE="${HALOGEN_COMPOSE:-$ENGINE_HALOGEN_DIR/compose.yaml}"
GUFO_COMPOSE="${GUFO_COMPOSE:-$ENGINE_GUFO_DIR/compose.yaml}"

: "${CAPACITY_INI_A:=$LLAMA_INI_DIR/models-bench.ini}"
: "${CAPACITY_INI_B:=$LLAMA_INI_DIR/models-bench-b.ini}"

# Run docker compose for a file under engines/*, loading repo-root .env and MODELS_*.
# First arg = primary compose file. Further -f siblings rewritten to basenames.
bench_docker_compose() {
  local file="${1:?compose file}"
  shift
  local dir base envf=() args=()
  [[ -f "$file" ]] || {
    printf 'error: compose file not found: %s\n' "$file" >&2
    return 1
  }
  dir="$(cd "$(dirname "$file")" && pwd)"
  base="$(basename "$file")"
  [[ -f "${PROJECT_ROOT}/.env" ]] && envf=(--env-file "${PROJECT_ROOT}/.env")
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-f" && -n "${2:-}" ]]; then
      if [[ -f "$2" ]] && [[ "$(cd "$(dirname "$2")" && pwd)" == "$dir" ]]; then
        args+=(-f "$(basename "$2")")
      else
        args+=(-f "$2")
      fi
      shift 2
    else
      args+=("$1")
      shift
    fi
  done
  (cd "$dir" && \
    MODELS_ROOT="${MODELS_ROOT}" \
    MODELS_DIR="${MODELS_DIR}" \
    TTS_MODELS="${TTS_MODELS}" \
    STT_MODELS="${STT_MODELS}" \
    docker compose "${envf[@]}" -f "$base" "${args[@]}")
}

export PROJECT_ROOT ENGINE_LLAMA_DIR ENGINE_HALOGEN_DIR ENGINE_GUFO_DIR
export ENGINE_PIPER_DIR ENGINE_WHISPER_DIR
export MODELS_ROOT MODELS_DIR TTS_MODELS STT_MODELS LLAMA_INI_DIR
export HALOGEN_MODELS GUFO_MODELS
export STACK_ENGINES LLAMA_SERVICES SMOKE_ENGINES
export VK_COMPOSE ROCM_COMPOSE BENCH_COMPOSE
export HALOGEN_COMPOSE GUFO_COMPOSE
export CAPACITY_INI_A CAPACITY_INI_B
