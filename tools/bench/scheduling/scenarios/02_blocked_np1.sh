#!/usr/bin/env bash
# 02: Long prefill first, then decode (np=1 worst case).
set -euo pipefail
SCENARIO="02_blocked_np1"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/metrics.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

preflight
log "scenario $SCENARIO — prefill then decode (sequential)"

metrics_start "$sdir/metrics.csv"
stream_chat "slot_b" "$(fixture_path prompt_4k.txt)" "$sdir/slot_b.jsonl" 32
stream_chat "slot_a" "$(fixture_path prompt_short.txt)" "$sdir/slot_a.jsonl" 64
metrics_stop

summarize_jsonl "$sdir/slot_a.jsonl" "$sdir/slot_a_summary.json"
summarize_jsonl "$sdir/slot_b.jsonl" "$sdir/slot_b_summary.json"
write_scenario_summary "$SCENARIO"
log "done $SCENARIO → $sdir/summary.json"
