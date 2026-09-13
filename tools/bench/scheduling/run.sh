#!/usr/bin/env bash
# Scheduling / rolling-prefill suite — invoked via ./bench sched …
set -euo pipefail

SCHED_BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCHED_BENCH_ROOT
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/report.sh"

AUTO=0
LIST_ONLY=0
COMPARE_ONLY=0
SCENARIOS=()
MATRIX=""
RESTORE_ON_EXIT=1

usage() {
  cat <<'EOF'
Usage: ./bench sched [options]

Decode latency while concurrent long prefill (bench-a :11601).
Stops stickys/lab, syncs models-bench.ini, restores after (unless --no-restore).
Coexist scenarios still use sticky + lab :11537.

Options:
  --list              list scenarios / matrices
  --auto              run 01 + 02 + 03
  --matrix FILE       matrix yaml under tools/bench/scheduling/matrix/
  --scenario NAME     one scenario (baseline_solo, interleave_np2, …)
  --compare           rebuild output/bench/scheduling/latest/compare.md
  --restart-bench     with sweeps: patch models-bench.ini + restart bench-a
  --restart-lab       alias for --restart-bench (compat)
  --no-restore        skip auto-restore (stickys stay stopped)

Env:
  SCHED_MODEL SCHED_NP SCHED_UB SCHED_B SCHED_UB_LIST SCHED_NP_LIST SCHED_B_LIST SCHED_C_LIST
  SCHED_MTP_LIST          (default off,1,2,3,4 — for mtp_sweep)
  COEXIST_CHAT_MODEL COEXIST_CODER_MODEL COEXIST_C_LIST COEXIST_NP_PAIRS
  SCHED_SWEEP_UB SCHED_SWEEP_NP  (fixed params during cross-sweeps)
  SCHED_BASE_URL (default http://127.0.0.1:11601)
  SCHED_NO_RESTORE=1  same as --no-restore

Examples:
  ./bench sched --auto
  SCHED_NP=2 SCHED_UB=32 ./bench sched --scenario interleave_np2
  ./bench sched --matrix qwen36_vl.yaml
  SCHED_RESTART_LAB=1 ./bench sched --scenario ub_sweep
  SCHED_RESTART_LAB=1 ./bench sched --scenario np_sweep
  SCHED_RESTART_LAB=1 ./bench sched --scenario b_sweep
  SCHED_MODEL=Qwen3.8-27B-Q4_K_M-MTP ./bench sched --scenario mtp_sweep
  COEXIST_CODER_MODEL=Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL ./bench sched --scenario coexist_capacity

EOF
}

list_scenarios() {
  local f
  for f in "$SCHED_BENCH_ROOT"/scenarios/*.sh; do
    printf '  %s\n' "$(basename "$f" .sh)"
  done
}

resolve_scenario() {
  local name="$1" path=""
  if [[ -f "$SCHED_BENCH_ROOT/scenarios/${name}.sh" ]]; then
    path="$SCHED_BENCH_ROOT/scenarios/${name}.sh"
  else
    for f in "$SCHED_BENCH_ROOT"/scenarios/*"$name"*.sh; do
      [[ -f "$f" ]] || continue
      path="$f"
      break
    done
  fi
  [[ -n "$path" ]] || die "unknown scenario: $name (try --list)"
  printf '%s\n' "$path"
}

run_scenario() {
  bash "$1"
}

load_matrix() {
  local file="$1"
  [[ -f "$file" ]] || file="$SCHED_BENCH_ROOT/matrix/$file"
  [[ -f "$file" ]] || die "matrix not found: $1"
  bench_python - "$file" <<'PY'
import sys
path = sys.argv[1]
data = {}
current = None
for raw in open(path, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.endswith(":") and not line.startswith("-"):
        current = line[:-1].strip()
        data[current] = []
        continue
    if line.startswith("- "):
        if current is None:
            continue
        data.setdefault(current, []).append(line[2:].strip())
        continue
    if ":" in line:
        k, v = line.split(":", 1)
        data[k.strip()] = v.strip()
key_map = {"model": "SCHED_MODEL", "np": "SCHED_NP", "b": "SCHED_B", "ub": "SCHED_UB", "ub_list": "SCHED_UB_LIST"}
for k, env in key_map.items():
    if k in data and not isinstance(data[k], list):
        print(f"export {env}={data[k]!r}")
if "scenarios" in data:
    items = " ".join(f'"{s}"' for s in data["scenarios"])
    print(f"SCENARIOS=({items})")
PY
}

cleanup() {
  restore_routers
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) LIST_ONLY=1 ;;
    --auto) AUTO=1 ;;
    --compare) COMPARE_ONLY=1 ;;
    --no-restore) RESTORE_ON_EXIT=0; export SCHED_NO_RESTORE=1 ;;
    --matrix)
      shift
      [[ $# -gt 0 ]] || die "--matrix needs a file"
      MATRIX="$1"
      ;;
    --scenario)
      shift
      [[ $# -gt 0 ]] || die "--scenario needs a name"
      SCENARIOS+=("$1")
      ;;
    --restart-lab|--restart-bench) export SCHED_RESTART_LAB=1; export SCHED_RESTART_BENCH=1 ;;
    -*) die "unknown option: $1" ;;
    *) SCENARIOS+=("$1") ;;
  esac
  shift
done

if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo "Scenarios:"
  list_scenarios
  echo ""
  echo "Matrices:"
  ls -1 "$SCHED_BENCH_ROOT/matrix/" 2>/dev/null || true
  exit 0
fi

if [[ "$COMPARE_ONLY" -eq 1 ]]; then
  report_latest || true
  [[ -f "$PROJECT_ROOT/tools/bench/build-index.sh" ]] && bash "$PROJECT_ROOT/tools/bench/build-index.sh" || true
  exit 0
fi

trap cleanup EXIT

if [[ -n "$MATRIX" ]]; then
  eval "$(load_matrix "$MATRIX")"
  AUTO=0
fi

if [[ "$AUTO" -eq 1 && ${#SCENARIOS[@]} -eq 0 ]]; then
  SCENARIOS=(01_baseline_solo 02_blocked_np1 03_interleave_np2)
fi

[[ ${#SCENARIOS[@]} -gt 0 ]] || { usage; exit 1; }

# Coexist capacity keeps sticky + lab both loaded.
COEXIST=0
for name in "${SCENARIOS[@]}"; do
  case "$name" in
    *coexist*|11_coexist_capacity) COEXIST=1 ;;
  esac
done

if [[ "$COEXIST" -eq 1 ]]; then
  export SCHED_COEXIST=1
  source "$SCHED_BENCH_ROOT/lib/coexist.sh"
  prepare_coexist_gpu
  init_run "sched-coexist"
  # Skip single-model preflight; scenario loads both itself.
else
  sched_bench_prepare
  sched_bench_load "$SCHED_MODEL" || die "failed to load $SCHED_MODEL on bench-a"
  init_run "sched-bench"
  preflight
fi

for name in "${SCENARIOS[@]}"; do
  path="$(resolve_scenario "$name")"
  log "=== $(basename "$path") ==="
  run_scenario "$path"
done

report_run
log "finished → $(run_dir)"
