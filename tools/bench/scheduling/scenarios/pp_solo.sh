#!/usr/bin/env bash
# Solo long-prefill PP probe (max_tokens=1 → measures prompt processing time).
set -euo pipefail
SCENARIO="pp_solo"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/metrics.sh"

if [[ -n "${SCENARIO_DIR_NAME:-}" && -n "${SCHED_RUN_DIR:-}" ]]; then
  sdir="$SCHED_RUN_DIR"
else
  sdir="$(scenario_dir "${SCENARIO_DIR_NAME:-pp_solo}")"
fi
mkdir -p "$sdir"

preflight
log "scenario pp_solo — solo prefill PP probe"

prompt_file="$(fixture_path prompt_4k.txt)"
prompt_chars="$(wc -c <"$prompt_file" | tr -d ' ')"
# Rough token estimate for PP tok/s (good enough for A/B compare).
est_tokens="$(bench_python - "$prompt_chars" <<'PY'
import sys
print(max(1, int(int(sys.argv[1]) / 3.5)))
PY
)"

metrics_start "$sdir/metrics.csv"
stream_chat "prefill" "$prompt_file" "$sdir/prefill.jsonl" 1
metrics_stop

summarize_jsonl "$sdir/prefill.jsonl" "$sdir/prefill_summary.json"
bench_python - "$sdir/prefill_summary.json" "$sdir/summary.json" "$est_tokens" <<'PY'
import json, sys
summ_path, out_path, est = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(summ_path, encoding="utf-8") as f:
    s = json.load(f)
ttft = s.get("ttft_ms")
pp_tok_s = None
if ttft and ttft > 0:
    pp_tok_s = round(est / (ttft / 1000.0), 2)
data = {
    "scenario": "pp_solo",
    "est_prompt_tokens": est,
    "ttft_ms": ttft,
    "pp_tok_s": pp_tok_s,
    "prefill": s,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
log "done pp_solo → $sdir/summary.json (pp≈$(grep pp_tok_s "$sdir/summary.json" | head -1))"
