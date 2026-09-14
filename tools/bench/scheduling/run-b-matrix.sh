#!/usr/bin/env bash
# b_sweep (06) for listed models on bench-a — fills b ★ in dashboard.
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
export SCHED_B_LIST="${SCHED_B_LIST:-32,64,128,256}"
export SCHED_RESTART_BENCH=1

LOG="${BENCH_B_LOG:-$ROOT/output/bench/scheduling/b-matrix-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

echo "=== b_sweep matrix $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "using llama-bench-a via ./bench sched (lab router not used)"

for m in "${MODELS[@]}"; do
  export SCHED_MODEL="$m"
  echo ""
  echo "======== B SWEEP: $m ========"
  ./bench sched --scenario b_sweep
done

./bench compare-sched
./bench index
echo "=== b_sweep matrix done ==="
