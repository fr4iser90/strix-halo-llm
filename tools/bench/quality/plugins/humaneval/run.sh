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
DO_EVAL=1
DRY_RUN=0
USE_BENCH=1
EVAL_ONLY_DIR=""

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
  --eval                run functional correctness after generate (default)
  --no-eval             generate only (no pass@k scores)
  --eval-only DIR       score existing samples.jsonl in DIR (no generate / no bench load)
  --vendor DIR          human-eval checkout (default $VENDOR)
  --dry-run             print plan, exit
  -h, --help

Env:
  QUALITY_BASE_URL  QUALITY_MODEL  QUALITY_N  QUALITY_LIMIT
  QUALITY_SKIP_BENCH=1   same as --no-bench
  HUMAN_EVAL_EXECUTE=0   force --no-eval
  QUALITY_SYNC_SOURCES   default coder,chat (lab never bulk-synced; missing model = one section from lab)

Quants: HumanEval uses the *weight* preset (section name / GGUF), not a KV
sweep. KV (ctk/ctv) stays whatever is in models-bench.ini (usually q8_0).
Capacity already sweeps KV×c separately.

Install harness (once — also auto-run by matrix):
  ./bench quality humaneval --setup

Creates output/bench/.venv-quality and installs openai/human-eval there.
Enables functional eval (unsafe_execute) so matrix can write pass@1.
EOF
}

# Repo-local venv so NixOS nix-shell python can still import human_eval.
quality_venv_dir() {
  printf '%s\n' "$ROOT/output/bench/.venv-quality"
}

quality_venv_python() {
  printf '%s\n' "$(quality_venv_dir)/bin/python3"
}

enable_human_eval_execute() {
  local exec_py="$VENDOR/human_eval/execution.py"
  [[ -f "$exec_py" ]] || return 0
  bench_python - "$exec_py" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
orig = text
# Official gate: commented "exec(check_program, exec_globals)"
text = re.sub(
    r"(?m)^(\s*)#\s*(exec\(check_program,\s*exec_globals\))\s*$",
    r"\1\2",
    text,
)
text = re.sub(
    r"(?m)^(\s*)#\s*(exec\(check_program\))\s*$",
    r"\1\2",
    text,
)
if text != orig:
    path.write_text(text, encoding="utf-8")
    print(f"→ enabled exec(check_program) in {path}")
elif "exec(check_program" in text:
    print(f"→ execution already enabled in {path}")
else:
    print(f"→ warning: could not find exec(check_program) gate in {path}", file=sys.stderr)
PY
}

install_human_eval_into_venv() {
  local venv py pip reqs
  venv="$(quality_venv_dir)"
  py="$(quality_venv_python)"
  mkdir -p "$(dirname "$venv")"
  if [[ ! -x "$py" ]]; then
    echo "→ Creating venv $venv"
    if command -v python3 >/dev/null 2>&1; then
      python3 -m venv "$venv"
    elif command -v nix-shell >/dev/null 2>&1; then
      env -u TMPDIR nix-shell -p python3 --run "python3 -m venv $(printf '%q' "$venv")"
    else
      echo "error: need python3 or nix-shell to create $venv" >&2
      return 1
    fi
  fi
  pip="$venv/bin/pip"
  # openai/human-eval setup.py imports pkg_resources at build time → breaks on
  # Python 3.12+ editable installs. Skip -e; put clone on PYTHONPATH instead.
  echo "→ install human-eval deps into $venv (no editable install)"
  "$pip" install -U 'pip>=24' 'setuptools>=70' wheel >/dev/null
  reqs="$VENDOR/requirements.txt"
  if [[ -f "$reqs" ]]; then
    "$pip" install -r "$reqs"
  else
    "$pip" install tqdm fire numpy
  fi
  export BENCH_PYTHON="$py"
  export BENCH_PYTHON_MODE="$py"
  export PYTHONPATH="${VENDOR}${PYTHONPATH:+:$PYTHONPATH}"
}

ensure_human_eval_ready() {
  mkdir -p "$(dirname "$VENDOR")"
  if [[ ! -d "$VENDOR/.git" && ! -f "$VENDOR/setup.py" && ! -f "$VENDOR/pyproject.toml" ]]; then
    echo "→ Cloning openai/human-eval → $VENDOR"
    git clone --depth 1 https://github.com/openai/human-eval.git "$VENDOR"
  fi
  install_human_eval_into_venv
  enable_human_eval_execute
  # Prefer venv for subsequent bench_python calls in this process
  export BENCH_PYTHON
  BENCH_PYTHON="$(quality_venv_python)"
  export BENCH_PYTHON_MODE="$BENCH_PYTHON"
  export PYTHONPATH="${VENDOR}${PYTHONPATH:+:$PYTHONPATH}"
  if ! bench_python -c "import human_eval.data" 2>/dev/null; then
    echo "→ import failed — recreating venv and retrying…"
    rm -rf "$(quality_venv_dir)"
    install_human_eval_into_venv
    BENCH_PYTHON="$(quality_venv_python)"
    export BENCH_PYTHON BENCH_PYTHON_MODE="$BENCH_PYTHON"
    export PYTHONPATH="${VENDOR}${PYTHONPATH:+:$PYTHONPATH}"
  fi
  if ! bench_python -c "import human_eval.data" 2>/dev/null; then
    echo "error: human_eval still not importable after --setup" >&2
    echo "  VENDOR=$VENDOR PYTHONPATH=$PYTHONPATH BENCH_PYTHON=$BENCH_PYTHON" >&2
    return 1
  fi
  echo "→ human_eval OK via $BENCH_PYTHON (PYTHONPATH=$VENDOR)"
}

setup_harness() {
  ensure_human_eval_ready
  echo ""
  echo "Harness ready. Matrix / HumanEval will use:"
  echo "  BENCH_PYTHON=$(quality_venv_python)"
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
    --eval-only) EVAL_ONLY_DIR="$2"; DO_EVAL=1; USE_BENCH=0; shift 2 ;;
    --vendor) VENDOR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "${HUMAN_EVAL_EXECUTE:-1}" == "0" ]] && DO_EVAL=0
[[ "${QUALITY_SKIP_BENCH:-0}" == "1" ]] && USE_BENCH=0

if [[ -n "$EVAL_ONLY_DIR" ]]; then
  RUN_DIR="$EVAL_ONLY_DIR"
  SAMPLES="$RUN_DIR/samples.jsonl"
  [[ -f "$SAMPLES" ]] || { echo "error: no samples.jsonl in $RUN_DIR" >&2; exit 1; }
  # Recover model/stamp from summary if present
  if [[ -f "$RUN_DIR/summary.json" ]]; then
    MODEL="$(bench_python - "$RUN_DIR/summary.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("model", ""))
PY
)"
    STAMP="$(basename "$RUN_DIR")"
    N_SAMPLES="$(bench_python - "$RUN_DIR/summary.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("n_samples_per_task", 1))
PY
)"
    LIMIT="$(bench_python - "$RUN_DIR/summary.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("limit", 0))
PY
)"
    API="$(bench_python - "$RUN_DIR/summary.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("base_url", "http://127.0.0.1:11601/v1"))
PY
)"
  else
    STAMP="$(basename "$RUN_DIR")"
    MODEL="${MODEL:-unknown}"
    API="${BASE_URL%/}/v1"
  fi
  export PYTHONPATH="${VENDOR}${PYTHONPATH:+:$PYTHONPATH}"
  if [[ -z "${BENCH_PYTHON:-}" ]] && [[ -x "$(quality_venv_python)" ]]; then
    BENCH_PYTHON="$(quality_venv_python)"
    export BENCH_PYTHON BENCH_PYTHON_MODE="$BENCH_PYTHON"
  fi
  if ! bench_python -c "import human_eval.data" 2>/dev/null; then
    ensure_human_eval_ready || exit 1
  fi
  echo "=== HumanEval (eval-only) ==="
  echo "  dir:   $RUN_DIR"
  echo "  model: $MODEL"
  # jump to shared eval block via sourcing continuation — fall through below
  SKIP_GENERATE=1
else
  SKIP_GENERATE=0
  [[ -n "$MODEL" ]] || {
    echo "error: --model / QUALITY_MODEL required" >&2
    usage
    exit 1
  }
fi

# shellcheck source=../../lib/server.sh
source "$ROOT/tools/bench/quality/lib/server.sh"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "=== HumanEval (dry-run) ==="
  echo "  model: $MODEL"
  echo "  bench: $([[ "$USE_BENCH" -eq 1 ]] && echo yes || echo no) → ${BASE_URL:-http://127.0.0.1:11601}"
  echo "  eval-only: ${EVAL_ONLY_DIR:-no}"
  exit 0
fi

if [[ "$SKIP_GENERATE" -eq 0 ]]; then
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

  if [[ -z "${BENCH_PYTHON:-}" ]] && [[ -x "$(quality_venv_python)" ]]; then
    export BENCH_PYTHON
    BENCH_PYTHON="$(quality_venv_python)"
    export BENCH_PYTHON_MODE="$BENCH_PYTHON"
  fi

  if ! bench_python -c "import human_eval.data" 2>/dev/null; then
    echo "→ human_eval missing — running ensure_human_eval_ready…"
    ensure_human_eval_ready || {
      echo "error: human_eval not importable after auto-setup" >&2
      exit 1
    }
  fi

  [[ "${HUMAN_EVAL_EXECUTE:-1}" == "0" ]] && DO_EVAL=0

  bench_python "$PLUGIN_DIR/generate.py"

  SAMPLES="$RUN_DIR/samples.jsonl"
  [[ -f "$SAMPLES" ]] || { echo "error: no samples written" >&2; exit 1; }
fi

METRICS_JSON="{}"
if [[ "$DO_EVAL" -eq 1 ]]; then
  RESULTS_JSONL="${SAMPLES}_results.jsonl"
  # Re-score path: if results already exist (e.g. n=10 run), skip re-executing tests
  if [[ "$SKIP_GENERATE" -eq 1 && -f "$RESULTS_JSONL" ]]; then
    echo "→ Reusing existing $RESULTS_JSONL (no re-exec)…"
    [[ -f "$RUN_DIR/eval.log" ]] || : >"$RUN_DIR/eval.log"
  else
    echo "→ Evaluating functional correctness (executes model code)…"
    bench_ensure_libstdcxx || true
    set +e
    bench_python -m human_eval.evaluate_functional_correctness "$SAMPLES" \
      >"$RUN_DIR/eval.log" 2>&1
    EVAL_RC=$?
    set -e
    cat "$RUN_DIR/eval.log" || true
  fi
  METRICS_JSON="$(bench_python - "$RUN_DIR" <<'PY'
import json, glob, ast, os, re, sys
run_dir = sys.argv[1]

def coerce_metrics(obj):
    """Normalize evaluate_functional_correctness printout to plain floats."""
    if not isinstance(obj, dict):
        return {}
    out = {}
    for k, v in obj.items():
        key = str(k)
        if not key.startswith("pass@"):
            continue
        try:
            out[key] = float(v)
        except (TypeError, ValueError):
            continue
    return out

def parse_metrics_line(line: str):
    line = line.strip()
    if "pass@" not in line:
        return {}
    # Official harness often prints: {'pass@1': np.float64(0.62), 'pass@10': np.float64(0.79)}
    cleaned = re.sub(r"np\.float64\(([^)]+)\)", r"\1", line)
    cleaned = cleaned.replace("np.float(", "(")
    if cleaned.startswith("{"):
        try:
            return coerce_metrics(json.loads(cleaned.replace("'", '"')))
        except json.JSONDecodeError:
            pass
        try:
            return coerce_metrics(ast.literal_eval(cleaned))
        except (ValueError, SyntaxError):
            pass
    # Fallback: extract pass@k : number pairs
    found = {}
    for m in re.finditer(r"['\"]?(pass@\d+)['\"]?\s*:\s*(?:np\.float64\()?([0-9.eE+-]+)", line):
        try:
            found[m.group(1)] = float(m.group(2))
        except ValueError:
            pass
    return found

def pass_at_k_from_results(path: str):
    """Unbiased pass@k from samples.jsonl_results.jsonl (no numpy)."""
    import math
    from collections import defaultdict
    per_task = defaultdict(list)
    with open(path, encoding="utf-8") as f:
        for line in f:
            row = json.loads(line)
            per_task[row["task_id"]].append(bool(row.get("passed")))
    if not per_task:
        return {}

    def estimate(n, c, k):
        if n - c < k:
            return 1.0
        return 1.0 - math.comb(n - c, k) / math.comb(n, k)

    ns = [len(v) for v in per_task.values()]
    n_max = max(ns) if ns else 0
    metrics = {}
    for k in (1, 10):
        if n_max < k:
            continue
        vals = []
        for xs in per_task.values():
            n = len(xs)
            if n < k:
                continue
            c = sum(1 for p in xs if p)
            vals.append(estimate(n, c, k))
        if vals:
            metrics[f"pass@{k}"] = sum(vals) / len(vals)
    return metrics

m = {}
log = os.path.join(run_dir, "eval.log")
if os.path.isfile(log):
    for line in open(log, encoding="utf-8"):
        parsed = parse_metrics_line(line)
        if parsed:
            m = parsed

results = sorted(glob.glob(os.path.join(run_dir, "samples.jsonl_results.jsonl")))
if results:
    from_results = pass_at_k_from_results(results[0])
    # Prefer official log metrics; fill any missing k from results
    for k, v in from_results.items():
        if k not in m:
            m[k] = v
    if not m:
        m = from_results

print(json.dumps(m))
PY
)"
  if [[ "$METRICS_JSON" == "{}" || "$METRICS_JSON" == "" ]]; then
    echo "→ Official evaluate failed/empty — fallback pass@1 (no numpy)…"
    set +e
    METRICS_JSON="$(bench_python "$PLUGIN_DIR/eval_pass1.py" "$SAMPLES" 2>"$RUN_DIR/eval_fallback.log")"
    FB_RC=$?
    set -e
    if [[ "$FB_RC" -ne 0 || -z "$METRICS_JSON" || "$METRICS_JSON" == "{}" ]]; then
      echo "warning: evaluate failed — see $RUN_DIR/eval.log and eval_fallback.log" >&2
      cat "$RUN_DIR/eval_fallback.log" >&2 || true
      METRICS_JSON="{}"
    else
      echo "$METRICS_JSON" | tee -a "$RUN_DIR/eval.log"
    fi
  fi
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
echo "  Next: ./bench index"
exit 0
