#!/usr/bin/env bash
# HumanEval quality plugin — generate + optional evaluate.
#
# Upstream: https://github.com/openai/human-eval
#
# Flow:
#   1) Ensure openai/human-eval is importable (pip or .vendor clone)
#   2) Generate completions against QUALITY_BASE_URL (llama-server)
#   3) Optionally run evaluate_functional_correctness (executes model code!)
#
# Security: evaluation runs model-generated code. Prefer a sandbox / VM.
# Official harness disables execution until you edit execution.py — see README.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUALITY_DIR="$(cd "$PLUGIN_DIR/../.." && pwd)"
ROOT="${PROJECT_ROOT:-}"
[[ -n "$ROOT" ]] || ROOT="$(cd "$QUALITY_DIR/../../.." && pwd)"

# shellcheck source=../../../lib/python.sh
source "$ROOT/tools/bench/lib/python.sh"

OUT_ROOT="${QUALITY_OUT:-$ROOT/output/bench/quality}"
SUITE="humaneval"
VENDOR="${HUMAN_EVAL_VENDOR:-$QUALITY_DIR/.vendor/human-eval}"

BASE_URL="${QUALITY_BASE_URL:-http://127.0.0.1:11601}"
MODEL="${QUALITY_MODEL:-}"
N_SAMPLES="${QUALITY_N:-1}"
LIMIT="${QUALITY_LIMIT:-0}"          # 0 = all 164 tasks
MAX_TOKENS="${QUALITY_MAX_TOKENS:-512}"
TEMPERATURE="${QUALITY_TEMPERATURE:-0.2}"
TIMEOUT="${QUALITY_TIMEOUT:-120}"
DO_EVAL=0
DRY_RUN=0
INSTALL_HINT=1
USE_BENCH=1

usage() {
  cat <<EOF
Usage: ./bench quality humaneval [options]

Runs against llama-bench-a (:11601) by default — NEVER sticky routers.
Stickys are stopped for a clean GPU (same policy as capacity).

Options:
  --model NAME          API model id (INI section / GGUF weight preset). Or QUALITY_MODEL=
  --base-url URL        override endpoint (implies --no-bench unless URL is bench-a)
  --no-bench            do not start/stop bench-a (you manage the server; QUALITY_SKIP_BENCH=1)
  --n N                 samples per task (default $N_SAMPLES) — pass@k needs n≥k
  --limit N             only first N tasks (smoke test; 0 = all)
  --max-tokens N        completion budget (default $MAX_TOKENS)
  --temperature F       sampling temperature (default $TEMPERATURE)
  --timeout SEC         HTTP timeout per completion (default $TIMEOUT)
  --eval                after generate, run functional correctness
  --no-eval             generate only (default)
  --vendor DIR          human-eval checkout (default $VENDOR)
  --dry-run             print plan, exit
  -h, --help

Env:
  QUALITY_BASE_URL  QUALITY_MODEL  QUALITY_N  QUALITY_LIMIT
  QUALITY_SKIP_BENCH=1   same as --no-bench
  HUMAN_EVAL_EXECUTE=1   same as --eval

Quants: HumanEval uses the *weight* preset (section name / GGUF), not a KV
sweep. KV (ctk/ctv) stays whatever is in models-bench.ini (usually q8_0).
Capacity already sweeps KV×c separately.

Install harness (once):
  ./bench quality humaneval --setup

Eval note: openai/human-eval comments out unsafe_execute until you opt in.
See $VENDOR/human_eval/execution.py after --setup.
EOF
}

setup_harness() {
  mkdir -p "$(dirname "$VENDOR")"
  if [[ ! -d "$VENDOR/.git" ]]; then
    echo "→ Cloning openai/human-eval → $VENDOR"
    git clone --depth 1 https://github.com/openai/human-eval.git "$VENDOR"
  else
    echo "→ human-eval already at $VENDOR"
  fi
  echo ""
  echo "Install into the active Python (or nix-shell -p python3Packages.pip):"
  echo "  pip install -e $(printf '%q' "$VENDOR")"
  echo ""
  echo "Before --eval: uncomment the call in human_eval/execution.py"
  echo "  (official safety gate — reads the disclaimer first)."
  echo "Docs: https://github.com/openai/human-eval"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --setup) setup_harness; exit 0 ;;
    --model) MODEL="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; USE_BENCH=0; shift 2 ;;
    --no-bench) USE_BENCH=0; shift ;;
    --n) N_SAMPLES="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --temperature) TEMPERATURE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --eval) DO_EVAL=1; shift ;;
    --no-eval) DO_EVAL=0; shift ;;
    --vendor) VENDOR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "${HUMAN_EVAL_EXECUTE:-0}" == "1" ]] && DO_EVAL=1
[[ "${QUALITY_SKIP_BENCH:-0}" == "1" ]] && USE_BENCH=0

[[ -n "$MODEL" ]] || {
  echo "error: --model / QUALITY_MODEL required" >&2
  usage
  exit 1
}

# shellcheck source=../../lib/server.sh
source "$ROOT/tools/bench/quality/lib/server.sh"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "=== HumanEval (dry-run) ==="
  echo "  model: $MODEL"
  echo "  bench: $([[ "$USE_BENCH" -eq 1 ]] && echo yes || echo no) → ${BASE_URL:-http://127.0.0.1:11601}"
  exit 0
fi

  if [[ "$USE_BENCH" -eq 1 ]]; then
  export QUALITY_SKIP_BENCH=0
  if ! quality_bench_load "$MODEL"; then
    echo "error: could not load $MODEL on bench-a" >&2
    exit 1
  fi
  BASE_URL="$QUALITY_BASE_URL"
  trap quality_bench_cleanup EXIT
else
  export QUALITY_SKIP_BENCH=1
  quality_log "no-bench mode → $BASE_URL"
fi

# Normalize base URL to …/v1
API="$BASE_URL"
[[ "$API" == */v1 ]] || API="${API%/}/v1"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUT_ROOT/$SUITE/$STAMP"
mkdir -p "$RUN_DIR"

echo "=== HumanEval ==="
echo "  model:    $MODEL"
echo "  api:      $API"
echo "  n:        $N_SAMPLES"
echo "  limit:    ${LIMIT:-all}"
echo "  eval:     $DO_EVAL"
echo "  out:      $RUN_DIR"
echo ""

export PYTHONPATH="${VENDOR}${PYTHONPATH:+:$PYTHONPATH}"
export QUALITY_API="$API"
export QUALITY_MODEL="$MODEL"
export QUALITY_N="$N_SAMPLES"
export QUALITY_LIMIT="$LIMIT"
export QUALITY_MAX_TOKENS="$MAX_TOKENS"
export QUALITY_TEMPERATURE="$TEMPERATURE"
export QUALITY_TIMEOUT="$TIMEOUT"
export QUALITY_RUN_DIR="$RUN_DIR"
export HUMAN_EVAL_VENDOR="$VENDOR"

if ! bench_python -c "import human_eval.data" 2>/dev/null; then
  echo "error: human_eval not importable." >&2
  echo "Run: ./bench quality humaneval --setup && pip install -e $VENDOR" >&2
  exit 1
fi

bench_python "$PLUGIN_DIR/generate.py"

SAMPLES="$RUN_DIR/samples.jsonl"
[[ -f "$SAMPLES" ]] || { echo "error: no samples written" >&2; exit 1; }

METRICS_JSON="{}"
if [[ "$DO_EVAL" -eq 1 ]]; then
  echo "→ Evaluating functional correctness (executes model code)…"
  set +e
  bench_python -m human_eval.evaluate_functional_correctness "$SAMPLES" \
    >"$RUN_DIR/eval.log" 2>&1
  EVAL_RC=$?
  set -e
  cat "$RUN_DIR/eval.log"
  if [[ "$EVAL_RC" -ne 0 ]]; then
    echo "warning: evaluate failed (enable unsafe_execute in human_eval/execution.py — see openai/human-eval README)" >&2
  fi
  METRICS_JSON="$(bench_python - "$RUN_DIR" <<'PY'
import json, glob, ast, os, sys
run_dir = sys.argv[1]
m = {}
log = os.path.join(run_dir, "eval.log")
if os.path.isfile(log):
    for line in open(log, encoding="utf-8"):
        line = line.strip()
        if "pass@" in line and line.startswith("{"):
            try:
                m = json.loads(line)
            except json.JSONDecodeError:
                try:
                    m = ast.literal_eval(line)
                except (ValueError, SyntaxError):
                    pass
results = glob.glob(os.path.join(run_dir, "samples.jsonl_results.jsonl"))
if not m and results:
    passed = total = 0
    with open(results[0], encoding="utf-8") as f:
        for line in f:
            row = json.loads(line)
            total += 1
            if row.get("passed"):
                passed += 1
    if total:
        m = {"pass@1": passed / total}
print(json.dumps(m))
PY
)"
fi

# summary.json
bench_python - "$RUN_DIR" "$SUITE" "$MODEL" "$API" "$STAMP" "$N_SAMPLES" "$LIMIT" "$METRICS_JSON" <<'PY'
import json, os, sys
run_dir, suite, model, api, stamp, n, limit, metrics_s = sys.argv[1:9]
try:
    metrics = json.loads(metrics_s)
except json.JSONDecodeError:
    metrics = {}
n_tasks = 0
with open(os.path.join(run_dir, "samples.jsonl"), encoding="utf-8") as f:
    tasks = set()
    for line in f:
        tasks.add(json.loads(line)["task_id"])
    n_tasks = len(tasks)
summary = {
    "suite": suite,
    "model": model,
    "base_url": api,
    "stamp": stamp,
    "n_tasks": n_tasks,
    "n_samples_per_task": int(n),
    "limit": int(limit),
    "metrics": metrics,
    "notes": "HumanEval — https://github.com/openai/human-eval",
}
with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
print(json.dumps(summary, indent=2))
PY

# Refresh merge
"$QUALITY_DIR/run.sh" compare >/dev/null || true
echo ""
echo "✓ HumanEval run complete → $RUN_DIR"
echo "  summary: $RUN_DIR/summary.json"
echo "  Next: ./bench publish"
