#!/usr/bin/env bash
# Full scheduling matrix: all target models × auto + ub sweep.
# Usage: ./tools/bench/scheduling/run-full-matrix.sh
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

export SCHED_NP=2
export SCHED_B=64
export SCHED_UB=32
export SCHED_UB_LIST="${SCHED_UB_LIST:-32,64,128,256}"
export SCHED_NP_LIST="${SCHED_NP_LIST:-1,2,4}"
export SCHED_B_LIST="${SCHED_B_LIST:-32,64,128,256}"
export SCHED_SWEEP_UB="${SCHED_SWEEP_UB:-128}"
export SCHED_SWEEP_NP="${SCHED_SWEEP_NP:-2}"

LOG="${BENCH_MATRIX_LOG:-$ROOT/output/bench/scheduling/full-matrix-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$(dirname "$LOG")"
# tee breaks bash job control (wait) — log via script or subshell instead
exec >>"$LOG" 2>&1

echo "=== sched full matrix $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "models=${#MODELS[@]} np=$SCHED_NP ub_list=$SCHED_UB_LIST"
echo "log=$LOG"

echo "restart lab with np=2 ini"
docker compose --profile lab up -d llama-lab
sleep 5

for m in "${MODELS[@]}"; do
  export SCHED_MODEL="$m"
  echo ""
  echo "======== MODEL: $m ========"
  ./bench sched --auto
  SCHED_RESTART_LAB=1 ./bench sched --scenario ub_sweep
  SCHED_RESTART_LAB=1 ./bench sched --scenario np_sweep
  SCHED_RESTART_LAB=1 ./bench sched --scenario b_sweep
done

./bench index
echo "=== full matrix done ==="
