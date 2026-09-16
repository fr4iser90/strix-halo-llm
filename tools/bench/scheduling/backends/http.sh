#!/usr/bin/env bash
# Scheduling suite — HTTP backend (OpenAI-compatible engines).
# Solo decode + dual concurrent streams. np/ub INI sweeps do not apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SUITE_DIR/../../.." && pwd)"
# shellcheck source=../../lib/http_openai.sh
source "$PROJECT_ROOT/tools/bench/lib/http_openai.sh"

export BENCH_ENGINE="${BENCH_ENGINE:-halogen-flash}"
BENCH_ENGINE="$(bench_engine_normalize "$BENCH_ENGINE")"
export BENCH_ENGINE
ENGINE="$BENCH_ENGINE"

SCHED_OUT="${SCHED_OUT:-$PROJECT_ROOT/output/bench/scheduling}"
SCHED_BENCH_ROOT="$PROJECT_ROOT/tools/bench/scheduling"
FIXTURES="$SCHED_BENCH_ROOT/fixtures"
mkdir -p "$SCHED_OUT"

bench_http_require_up
bench_http_fingerprint

MODELS=()
mapfile -t MODELS < <(bench_http_resolve_models)
bench_http_log "sched models (${#MODELS[@]}): ${MODELS[*]}"

SHORT="$FIXTURES/prompt_short.txt"
LONG="$FIXTURES/prompt_4k.txt"
[[ -f "$SHORT" ]] || bench_http_die "missing fixture $SHORT"
[[ -f "$LONG" ]] || { LONG="$SHORT"; bench_http_log "warn: prompt_4k missing — using short for both"; }

for MODEL in "${MODELS[@]}"; do
  [[ -n "$MODEL" ]] || continue
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN="$SCHED_OUT/$STAMP"
  mkdir -p "$RUN"
  export SCHED_RUN_DIR="$RUN" SCHED_STAMP="$STAMP" SCHED_MODEL="$MODEL"
  export SCHED_BASE_URL="$(bench_http_base_url)" SCHED_NP="2" SCHED_UB="—" SCHED_B="—"

  BENCH_ENGINE="$ENGINE" bench_python - "$RUN/manifest.json" <<'PY'
import json, os, sys
out = sys.argv[1]
data = {
    "stamp": os.environ.get("SCHED_STAMP", ""),
    "tag": "http-auto",
    "engine": os.environ.get("BENCH_ENGINE", "halogen-flash"),
    "base_url": os.environ.get("SCHED_BASE_URL", ""),
    "model": os.environ.get("SCHED_MODEL", ""),
    "np": "2",
    "ub": "—",
    "b": "—",
    "ub_list": "",
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

  sdir="$RUN/01_baseline_solo"
  mkdir -p "$sdir"
  bench_http_log "=== sched $MODEL :: 01_baseline_solo ==="
  if bench_http_stream_once "$MODEL" "slot_a" "$SHORT" "$sdir/slot_a.jsonl" 64; then
    bench_http_summarize_jsonl_sched "$sdir/slot_a.jsonl" "$sdir/slot_a_summary.json"
    cp -f "$sdir/slot_a_summary.json" "$sdir/decode_summary.json"
  else
    echo '{}' >"$sdir/slot_a_summary.json"
  fi
  bench_python - "$sdir" <<'PY'
import json, os, sys, glob
sdir = sys.argv[1]
merged = {"scenario": os.path.basename(sdir)}
for path in sorted(glob.glob(os.path.join(sdir, "*_summary.json"))):
    key = os.path.basename(path).replace("_summary.json", "")
    with open(path, encoding="utf-8") as f:
        merged[key] = json.load(f)
with open(os.path.join(sdir, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PY

  sdir="$RUN/03_interleave_np2"
  mkdir -p "$sdir"
  bench_http_log "=== sched $MODEL :: 03_interleave_np2 ==="
  rm -f "$sdir/slot_a.jsonl.done" "$sdir/slot_b.jsonl.done"
  (
    bench_http_stream_once "$MODEL" "slot_a" "$SHORT" "$sdir/slot_a.jsonl" 128
    echo $? >"$sdir/slot_a.jsonl.done"
  ) &
  pid_a=$!
  sleep 0.3
  (
    bench_http_stream_once "$MODEL" "slot_b" "$LONG" "$sdir/slot_b.jsonl" 32
    echo $? >"$sdir/slot_b.jsonl.done"
  ) &
  pid_b=$!
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true
  bench_http_summarize_jsonl_sched "$sdir/slot_a.jsonl" "$sdir/slot_a_summary.json" 2>/dev/null || echo '{}' >"$sdir/slot_a_summary.json"
  bench_http_summarize_jsonl_sched "$sdir/slot_b.jsonl" "$sdir/slot_b_summary.json" 2>/dev/null || echo '{}' >"$sdir/slot_b_summary.json"
  bench_python - "$sdir" <<'PY'
import json, os, sys, glob
sdir = sys.argv[1]
merged = {"scenario": os.path.basename(sdir)}
for path in sorted(glob.glob(os.path.join(sdir, "*_summary.json"))):
    key = os.path.basename(path).replace("_summary.json", "")
    with open(path, encoding="utf-8") as f:
        merged[key] = json.load(f)
with open(os.path.join(sdir, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PY

  bench_http_log "sched run → $RUN"
done

export PROJECT_ROOT SCHED_OUT
# shellcheck source=../lib/report.sh
source "$SCHED_BENCH_ROOT/lib/report.sh"
report_latest || true
bench_http_log "sched compare → $SCHED_OUT/latest"
