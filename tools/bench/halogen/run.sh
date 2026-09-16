#!/usr/bin/env bash
# Compat shim — Halogen is an engine adapter, not a suite domain.
# Prefer: ./bench matrix --engine halogen-flash
#         ./bench capacity --engine halogen-flash …
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT/../../.." && pwd)"
# shellcheck source=../lib/lifecycle.sh
source "$PROJECT_ROOT/tools/bench/lib/lifecycle.sh"
# shellcheck source=../matrix/lib/http_matrix.sh
source "$PROJECT_ROOT/tools/bench/matrix/lib/http_matrix.sh"

usage() {
  cat <<'EOF'
Usage: ./bench halogen <command> [opts]   (compat shim)

Prefer suite-primary CLI:
  ./bench matrix --profile full --engine halogen-flash
  ./bench capacity http --engine halogen-flash
  ./bench throughput --engine halogen-flash
  ./bench sched --engine halogen-flash

Commands (shim):
  matrix | capacity | throughput | sched | quality | help

Env:
  HALOGEN_MODELS     weights directory for compose
  MATRIX_MODELS / --model   API model id(s)
  BENCH_ENGINE_SKIP_LIFECYCLE=1 · BENCH_ENGINE_KEEP=1
EOF
}

CMD=""
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
      if [[ -z "$CMD" ]]; then
        CMD="$1"; shift; continue
      fi
      break
      ;;
  esac
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) shift; MODELS_CSV="${MODELS_CSV:+$MODELS_CSV,}${1:?}"; shift ;;
    --only) shift; ONLY+=("${1:?}"); shift ;;
    --limit) shift; LIMIT="${1:?}"; shift ;;
    --n) shift; N_SAMPLES="${1:?}"; shift ;;
    --base-url) shift; HALOGEN_BASE_URL="${1:?}"; export HALOGEN_BASE_URL BENCH_HTTP_BASE_URL="$HALOGEN_BASE_URL"; shift ;;
    --keep) BENCH_ENGINE_KEEP=1; export BENCH_ENGINE_KEEP; shift ;;
    --no-lifecycle) BENCH_ENGINE_SKIP_LIFECYCLE=1; export BENCH_ENGINE_SKIP_LIFECYCLE; shift ;;
    *) printf 'error: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

CMD="${CMD:-matrix}"
[[ -n "$MODELS_CSV" ]] && export MATRIX_MODELS="$MODELS_CSV" HALOGEN_MODEL="$MODELS_CSV"
export BENCH_ENGINE=halogen-flash
export MATRIX_N_SAMPLES="$N_SAMPLES" MATRIX_LIMIT="$LIMIT"
MATRIX_ONLY=("${ONLY[@]}")
export MATRIX_ONLY

case "$CMD" in
  matrix) matrix_http_run_full halogen-flash "${ONLY[@]}" ;;
  capacity|throughput|sched|quality) matrix_http_run_suite halogen-flash "$CMD" ;;
  *) usage; exit 1 ;;
esac
