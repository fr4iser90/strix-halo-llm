#!/usr/bin/env bash
# 01: Solo decode baseline (no concurrent prefill).
set -euo pipefail
SCENARIO="01_baseline_solo"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/metrics.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

preflight
log "scenario $SCENARIO — solo decode"

metrics_start "$sdir/metrics.csv"
stream_chat "slot_a" "$(fixture_path prompt_short.txt)" "$sdir/slot_a.jsonl" 64
metrics_stop

summarize_jsonl "$sdir/slot_a.jsonl" "$sdir/slot_a_summary.json"
cp "$sdir/slot_a_summary.json" "$sdir/decode_summary.json"
write_scenario_summary "$SCENARIO"
log "done $SCENARIO → $sdir/summary.json"
