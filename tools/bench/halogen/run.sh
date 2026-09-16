#!/usr/bin/env bash
# Halogen Flash full bench entry — HTTP suites (no llama-bench-a).
#
#   ./bench halogen matrix --model MODEL
#   BENCH_ENGINE=halogen-flash ./bench matrix --profile full-halogen --model MODEL
#
# Server must already be up at HALOGEN_BASE_URL (default http://127.0.0.1:8731).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT/../../.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

QUALITY="$PROJECT_ROOT/tools/bench/quality/run.sh"
BUILD_INDEX="$PROJECT_ROOT/tools/bench/build-index.sh"

usage() {
  cat <<'EOF'
Usage: ./bench halogen <command> [opts]

Commands:
  matrix       capacity + sched + throughput + HumanEval (Halogen HTTP)
  capacity     context ladder → capacity/cells.jsonl
  throughput   PP/TG via HTTP streaming
  sched        solo + concurrent streams
  quality      HumanEval against Halogen
  help

Env:
  HALOGEN_BASE_URL   default http://127.0.0.1:8731
  MATRIX_MODELS / HALOGEN_MODELS / --model   API model id(s)
  HALOGEN_C_LIST / CAPACITY_C_LIST          context ladder

Examples:
  ./bench halogen matrix --model Qwen3.8-Flash-Next
  HALOGEN_BASE_URL=http://127.0.0.1:8731 ./bench halogen throughput --model …

EOF
}

MODELS_CSV=""
ONLY=()
LIMIT=0
N_SAMPLES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    help|-h|--help) usage; exit 0 ;;
    matrix|capacity|throughput|sched|quality)
      CMD="$1"; shift; break ;;
    --model)
      shift
      MODELS_CSV="${MODELS_CSV:+$MODELS_CSV,}${1:?}"
      shift
      ;;
    *)
      # allow: ./bench halogen matrix --model X
      if [[ -z "${CMD:-}" ]]; then
        CMD="$1"; shift; continue
      fi
      break
      ;;
  esac
done

# parse remaining flags after command
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) shift; MODELS_CSV="${MODELS_CSV:+$MODELS_CSV,}${1:?}"; shift ;;
    --only) shift; ONLY+=("${1:?}"); shift ;;
    --limit) shift; LIMIT="${1:?}"; shift ;;
    --n) shift; N_SAMPLES="${1:?}"; shift ;;
    --base-url) shift; HALOGEN_BASE_URL="${1:?}"; export HALOGEN_BASE_URL; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

CMD="${CMD:-matrix}"
[[ -n "$MODELS_CSV" ]] && export HALOGEN_MODELS="$MODELS_CSV" MATRIX_MODELS="$MODELS_CSV"

suite_ok() {
  local name="$1"
  [[ ${#ONLY[@]} -eq 0 ]] && return 0
  local s
  for s in "${ONLY[@]}"; do
    [[ "$s" == "$name" ]] && return 0
  done
  return 1
}

run_quality_halogen() {
  suite_ok quality || { log "skip quality"; return 0; }
  halogen_require_up
  export BENCH_ENGINE=halogen-flash
  export QUALITY_SKIP_BENCH=1
  export QUALITY_BASE_URL="$HALOGEN_BASE_URL"
  # HumanEval venv/harness (same as matrix)
  local he_run="$PROJECT_ROOT/tools/bench/quality/plugins/humaneval/run.sh"
  if [[ -f "$he_run" ]]; then
    log "HumanEval preflight…"
    bash "$he_run" --setup || die "HumanEval setup failed"
    local vpy="$PROJECT_ROOT/output/bench/.venv-quality/bin/python3"
    [[ -x "$vpy" ]] && export BENCH_PYTHON="$vpy" BENCH_PYTHON_MODE="$vpy"
    export HUMAN_EVAL_EXECUTE=1
    export PYTHONPATH="${PROJECT_ROOT}/tools/bench/quality/.vendor/human-eval${PYTHONPATH:+:$PYTHONPATH}"
  fi
  local models=() m qargs=(--n "$N_SAMPLES" --no-bench --eval --base-url "$HALOGEN_BASE_URL")
  [[ "$LIMIT" -gt 0 ]] && qargs+=(--limit "$LIMIT")
  mapfile -t models < <(halogen_resolve_models)
  local failed=0
  for m in "${models[@]}"; do
    [[ -n "$m" ]] || continue
    log "=== quality humaneval $m ==="
    if ! BENCH_ENGINE=halogen-flash QUALITY_MODEL="$m" QUALITY_SKIP_BENCH=1 HUMAN_EVAL_EXECUTE=1 \
      "$QUALITY" humaneval --model "$m" "${qargs[@]}"; then
      log "quality FAILED for $m"
      failed=1
    fi
  done
  "$QUALITY" compare || true
  [[ "$failed" -eq 0 ]] || die "Halogen HumanEval failed"
}

run_matrix_halogen() {
  log "Halogen full matrix @ $HALOGEN_BASE_URL"
  halogen_require_up
  if [[ -x "$PROJECT_ROOT/tools/bench/probe-host.sh" ]]; then
    BENCH_ENGINE=halogen-flash "$PROJECT_ROOT/tools/bench/probe-host.sh" || true
  fi
  if suite_ok capacity; then
    log "=== halogen capacity ==="
    bash "$ROOT/capacity.sh"
  fi
  if suite_ok sched; then
    log "=== halogen sched ==="
    bash "$ROOT/sched.sh"
  fi
  if suite_ok throughput; then
    log "=== halogen throughput ==="
    bash "$ROOT/throughput.sh"
  fi
  run_quality_halogen
  [[ -x "$BUILD_INDEX" ]] && "$BUILD_INDEX" || true
  log "Halogen matrix done — ./bench index / ./bench publish"
}

case "$CMD" in
  matrix) run_matrix_halogen ;;
  capacity) bash "$ROOT/capacity.sh" ;;
  throughput) bash "$ROOT/throughput.sh" ;;
  sched) bash "$ROOT/sched.sh" ;;
  quality) run_quality_halogen ;;
  *) usage; exit 1 ;;
esac
