#!/usr/bin/env bash
# Halogen HTTP scheduling: solo decode + dual concurrent streams (interleave-like).
# Writes scheduling/<stamp>/… so report.sh / Pages can pick recommendations up.
# np/ub INI sweeps do not apply to Halogen — this measures concurrent HTTP load.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

SCHED_OUT="${SCHED_OUT:-$PROJECT_ROOT/output/bench/scheduling}"
SCHED_BENCH_ROOT="$PROJECT_ROOT/tools/bench/scheduling"
FIXTURES="$SCHED_BENCH_ROOT/fixtures"
mkdir -p "$SCHED_OUT"

halogen_require_up
halogen_fingerprint

MODELS=()
mapfile -t MODELS < <(halogen_resolve_models)
log "sched models (${#MODELS[@]}): ${MODELS[*]}"

SHORT="$FIXTURES/prompt_short.txt"
LONG="$FIXTURES/prompt_4k.txt"
[[ -f "$SHORT" ]] || die "missing fixture $SHORT"
[[ -f "$LONG" ]] || { LONG="$SHORT"; log "warn: prompt_4k missing — using short for both"; }

for MODEL in "${MODELS[@]}"; do
  [[ -n "$MODEL" ]] || continue
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN="$SCHED_OUT/$STAMP"
  mkdir -p "$RUN"
  export SCHED_RUN_DIR="$RUN" SCHED_STAMP="$STAMP" SCHED_MODEL="$MODEL"
  export SCHED_BASE_URL="$HALOGEN_BASE_URL" SCHED_NP="2" SCHED_UB="—" SCHED_B="—"

  bench_python - "$RUN/manifest.json" <<'PY'
import json, os, sys
out = sys.argv[1]
data = {
    "stamp": os.environ.get("SCHED_STAMP", ""),
    "tag": "halogen-auto",
    "engine": "halogen-flash",
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

  # --- 01 baseline solo ---
  sdir="$RUN/01_baseline_solo"
  mkdir -p "$sdir"
  log "=== sched $MODEL :: 01_baseline_solo ==="
  if stream_once "$MODEL" "slot_a" "$SHORT" "$sdir/slot_a.jsonl" 64; then
    summarize_jsonl_sched "$sdir/slot_a.jsonl" "$sdir/slot_a_summary.json"
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

  # --- 03 interleave: decode + long prefill concurrent ---
  sdir="$RUN/03_interleave_np2"
  mkdir -p "$sdir"
  log "=== sched $MODEL :: 03_interleave_np2 ==="
  rm -f "$sdir/slot_a.jsonl.done" "$sdir/slot_b.jsonl.done"
  (
    stream_once "$MODEL" "slot_a" "$SHORT" "$sdir/slot_a.jsonl" 128
    echo $? >"$sdir/slot_a.jsonl.done"
  ) &
  pid_a=$!
  sleep 0.3
  (
    stream_once "$MODEL" "slot_b" "$LONG" "$sdir/slot_b.jsonl" 32
    echo $? >"$sdir/slot_b.jsonl.done"
  ) &
  pid_b=$!
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true
  summarize_jsonl_sched "$sdir/slot_a.jsonl" "$sdir/slot_a_summary.json" 2>/dev/null || echo '{}' >"$sdir/slot_a_summary.json"
  summarize_jsonl_sched "$sdir/slot_b.jsonl" "$sdir/slot_b_summary.json" 2>/dev/null || echo '{}' >"$sdir/slot_b_summary.json"
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

  log "sched run → $RUN"
done

# Rebuild recommendations (engine-aware report.sh)
export PROJECT_ROOT SCHED_OUT
# shellcheck source=../scheduling/lib/report.sh
source "$SCHED_BENCH_ROOT/lib/report.sh"
report_latest || true
log "sched compare → $SCHED_OUT/latest"
