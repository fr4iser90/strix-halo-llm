#!/usr/bin/env bash
# Phase 3 matrix: cont-batching A/B, ctx sweep, fit probe per model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

MODELS=(
  Qwen3.6-35B-A3B-MTP-UD-Q4_K_M
  Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL
  Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL
  Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL
  Qwen3.8-27B-Q4_K_M-MTP
  Qwen3.8-27B-Q4_K_M-MTP-VL
)

export SCHED_SWEEP_NP="${SCHED_SWEEP_NP:-2}"
export SCHED_SWEEP_UB="${SCHED_SWEEP_UB:-128}"
export SCHED_B="${SCHED_B:-64}"
export SCHED_C_LIST="${SCHED_C_LIST:-16384,32768,65536,131072,262144}"
export SCHED_RESTART_LAB=1

LOG="${BENCH_PHASE3_LOG:-$ROOT/output/bench/scheduling/phase3-matrix-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

echo "=== sched phase3 $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
docker compose --profile lab up -d llama-lab
sleep 3

for m in "${MODELS[@]}"; do
  export SCHED_MODEL="$m"
  echo ""
  echo "======== PHASE3 MODEL: $m ========"
  ./bench sched --scenario cont_batch
  ./bench sched --scenario ctx_sweep
  ./bench sched --scenario fit_probe
done

./bench compare-sched
./bench index
echo "=== phase3 done ==="
