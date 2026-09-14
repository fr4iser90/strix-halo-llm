#!/usr/bin/env bash
# Compat wrapper — prefer ./bench throughput or tools/bench/throughput/run.sh
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run.sh" "$@"
