#!/usr/bin/env bash
# Compat: halogen suite scripts moved to suite backends.
#   → tools/bench/capacity/backends/http.sh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export BENCH_ENGINE="${BENCH_ENGINE:-halogen-flash}"
exec bash "$PROJECT_ROOT/tools/bench/capacity/backends/http.sh" "$@"
