#!/usr/bin/env bash
# Throughput suite entry — PP/TG via llama-bench.
#
#   ./bench throughput …
#   tools/bench/throughput/run.sh …
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=lib/llama_bench.sh
source "$SCRIPT_DIR/lib/llama_bench.sh"
