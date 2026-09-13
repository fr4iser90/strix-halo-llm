#!/usr/bin/env bash
# Template for a new quality suite.
# Copy: cp -a _template ../mysuite && edit DESCRIPTION + this file
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$(basename "$PLUGIN_DIR")"
ROOT="${PROJECT_ROOT:-}"
# plugins/<suite> → quality → bench → tools → repo
[[ -n "$ROOT" ]] || ROOT="$(cd "$PLUGIN_DIR/../../../../.." && pwd)"
OUT_ROOT="${QUALITY_OUT:-$ROOT/output/bench/quality}"
BASE_URL="${QUALITY_BASE_URL:-http://127.0.0.1:11601}"
MODEL="${QUALITY_MODEL:-}"
USE_BENCH=1

usage() {
  cat <<EOF
Usage: ./bench quality ${SUITE} --model NAME [options]
  --model NAME
  --base-url URL     implies --no-bench
  --no-bench         matrix-owned lifecycle / advanced
  -h, --help

Always prefer llama-bench-a (:11601). Never sticky routers.
Implement scoring, then write \$QUALITY_OUT/${SUITE}/<stamp>/summary.json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --model) MODEL="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; USE_BENCH=0; shift 2 ;;
    --no-bench) USE_BENCH=0; shift ;;
    *) echo "unknown: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$MODEL" ]] || { usage; exit 1; }

# shellcheck source=../../lib/server.sh
source "$ROOT/tools/bench/quality/lib/server.sh"
if [[ "$USE_BENCH" -eq 1 && "${QUALITY_SKIP_BENCH:-0}" != "1" ]]; then
  quality_bench_load "$MODEL"
  BASE_URL="$QUALITY_BASE_URL"
  trap quality_bench_cleanup EXIT
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUT_ROOT/$SUITE/$STAMP"
mkdir -p "$RUN_DIR"

# TODO: call your harness, then write summary.json
cat >"$RUN_DIR/summary.json" <<EOF
{
  "suite": "$SUITE",
  "model": "$MODEL",
  "base_url": "${BASE_URL%/}/v1",
  "stamp": "$STAMP",
  "n_tasks": 0,
  "n_samples_per_task": 1,
  "metrics": {},
  "notes": "template — replace with real metrics"
}
EOF

echo "✓ template stub → $RUN_DIR/summary.json (implement me)"
