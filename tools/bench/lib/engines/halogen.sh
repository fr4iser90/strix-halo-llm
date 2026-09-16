#!/usr/bin/env bash
# Halogen Flash Server helpers for benches (OpenAI-compatible API on :8731).
#
# Compose: compose.halogen-flash-server.yaml
#   HALOGEN_MODELS=~/halogen-models podman-compose -f compose.halogen-flash-server.yaml up -d
#
# Quality (HumanEval) against a running Halogen API:
#   BENCH_ENGINE=halogen-flash ./bench quality humaneval \
#     --model <api-model-id> --no-bench --base-url http://127.0.0.1:8731
#
# Or rely on defaults once BENCH_ENGINE=halogen-flash is set (QUALITY_SKIP_BENCH=1,
# base URL → :8731). Throughput via llama-bench does not apply to Halogen —
# use quality / scheduling stream client instead.
#
# shellcheck shell=bash

# shellcheck source=../engine.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/engine.sh"

HALOGEN_BASE_URL="${HALOGEN_BASE_URL:-http://127.0.0.1:8731}"
export HALOGEN_BASE_URL

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
