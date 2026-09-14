#!/usr/bin/env bash
# Resume matrix: skip models that already have auto + all sweeps.
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

export SCHED_NP=2 SCHED_B=64 SCHED_UB=32
export SCHED_UB_LIST="${SCHED_UB_LIST:-32,64,128,256}"
export SCHED_NP_LIST="${SCHED_NP_LIST:-1,2,4}"
export SCHED_B_LIST="${SCHED_B_LIST:-32,64,128,256}"
export SCHED_SWEEP_UB="${SCHED_SWEEP_UB:-128}"
export SCHED_SWEEP_NP="${SCHED_SWEEP_NP:-2}"

LOG="${BENCH_MATRIX_LOG:-$ROOT/output/bench/scheduling/full-matrix-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

sweep_valid() {
  local summary="$1"
  [[ -f "$summary" ]] || return 1
  grep -qE '"chunks": [1-9]' "$summary" 2>/dev/null
}

sweep_merge_valid() {
  local summary="$1"
  [[ -f "$summary" ]] || return 1
  grep -q '"runs"' "$summary" 2>/dev/null && grep -qE '"chunks": [1-9]' "$summary" 2>/dev/null
}

model_has_auto() {
  local model="$1" run
  for run in "$ROOT/output/bench/scheduling"/20*/; do
    [[ -f "$run/manifest.json" ]] || continue
    grep -q "\"model\"[[:space:]]*:[[:space:]]*\"$model\"" "$run/manifest.json" 2>/dev/null || continue
    sweep_valid "$run/03_interleave_np2/summary.json" && return 0
  done
  return 1
}

model_has_sweep() {
  local model="$1" sweep="$2" run
  for run in "$ROOT/output/bench/scheduling"/20*/; do
    [[ -f "$run/manifest.json" ]] || continue
    grep -q "\"model\"[[:space:]]*:[[:space:]]*\"$model\"" "$run/manifest.json" 2>/dev/null || continue
    sweep_merge_valid "$run/${sweep}/summary.json" && return 0
  done
  return 1
}

model_done() {
  local model="$1"
  model_has_auto "$model" \
    && model_has_sweep "$model" "04_ub_sweep" \
    && model_has_sweep "$model" "05_np_sweep" \
    && model_has_sweep "$model" "06_b_sweep"
}

echo "=== sched matrix resume $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "using llama-bench-a via ./bench sched (lab router not used)"

for m in "${MODELS[@]}"; do
  if model_done "$m"; then
    echo "skip complete: $m"
    continue
  fi
  export SCHED_MODEL="$m"
  echo ""
  echo "======== MODEL: $m ========"
  model_has_auto "$m" || ./bench sched --auto
  model_has_sweep "$m" "04_ub_sweep" || SCHED_RESTART_BENCH=1 ./bench sched --scenario ub_sweep
  model_has_sweep "$m" "05_np_sweep" || SCHED_RESTART_BENCH=1 ./bench sched --scenario np_sweep
  model_has_sweep "$m" "06_b_sweep" || SCHED_RESTART_BENCH=1 ./bench sched --scenario b_sweep
done

./bench index
echo "=== matrix resume done ==="
