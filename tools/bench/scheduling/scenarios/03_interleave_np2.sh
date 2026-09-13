#!/usr/bin/env bash
# 03: Concurrent decode (slot A) + long prefill (slot B) — needs np>=2.
set -euo pipefail
SCENARIO="03_interleave_np2"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/metrics.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

preflight
if [[ -n "${SCHED_NP:-}" && "${SCHED_NP}" =~ ^[0-9]+$ && "$SCHED_NP" -lt 2 ]]; then
  log "warning: SCHED_NP=$SCHED_NP — interleaving needs np>=2 in models-lab.ini"
fi

log "scenario $SCENARIO — concurrent decode + prefill"

metrics_start "$sdir/metrics.csv"
pid_b="$(stream_chat_bg "slot_b" "$(fixture_path prompt_4k.txt)" "$sdir/slot_b.jsonl" 64)"
sleep 0.5
stream_chat "slot_a" "$(fixture_path prompt_short.txt)" "$sdir/slot_a.jsonl" 64
wait_stream_bg "$sdir/slot_b.jsonl" "$pid_b"
metrics_stop

summarize_jsonl "$sdir/slot_a.jsonl" "$sdir/slot_a_summary.json"
summarize_jsonl "$sdir/slot_b.jsonl" "$sdir/slot_b_summary.json"
write_scenario_summary "$SCENARIO"
log "done $SCENARIO → $sdir/summary.json"
