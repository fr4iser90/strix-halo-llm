#!/usr/bin/env bash
# Throughput suite entry — PP/TG via llama-bench (native) or HTTP backend.
#
#   ./bench throughput …
#   ./bench throughput --engine halogen-flash
#   tools/bench/throughput/run.sh …
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../lib/engine.sh
source "$PROJECT_ROOT/tools/bench/lib/engine.sh"

# Peel --engine before native llama-bench arg parsing.
_THR_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      shift
      BENCH_ENGINE="$(bench_engine_normalize "${1:?}")"
      export BENCH_ENGINE
      shift
      ;;
    *)
      _THR_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${_THR_ARGS[@]}"

if [[ "$(bench_engine_protocol)" == "http" ]]; then
  exec bash "$SCRIPT_DIR/backends/http.sh" "$@"
fi

# shellcheck source=lib/llama_bench.sh
source "$SCRIPT_DIR/lib/llama_bench.sh"
