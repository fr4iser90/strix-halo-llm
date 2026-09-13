#!/usr/bin/env bash
# 11: Dual-model capacity — chat (sticky) + coder (lab) under filled KV + stress.
# Sweeps c × (np_chat:np_coder), monitors GTT / MemAvailable, recommends max safe cell.
#
# Env:
#   COEXIST_CHAT_MODEL COEXIST_CODER_MODEL
#   COEXIST_CHAT_URL (default :11535) COEXIST_CODER_URL (default :11537)
#   COEXIST_C_LIST          default 262144  (native model max; >256k needs YaRN/rope — not default)
#   COEXIST_NP_PAIRS        default 4:4
#   COEXIST_FILL_RATIO      default 0.85 of (c/np) tokens per slot
#   COEXIST_GTT_LIMIT_PCT   default 92
#   COEXIST_MEM_FLOOR_MB    default 8192
#   COEXIST_STRESS_TOKENS   default 64
#
# Next production validation (embeddings must stay up via prepare_coexist_gpu):
#   COEXIST_C_LIST=262144 COEXIST_NP_PAIRS=4:4 ./bench sched --scenario coexist_capacity
# Higher-c sweep only if rope/YaRN configured: COEXIST_C_LIST=262144,327680,393216
set -euo pipefail
SCENARIO="11_coexist_capacity"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/ini_patch.sh"
source "$SCHED_BENCH_ROOT/lib/metrics.sh"
source "$SCHED_BENCH_ROOT/lib/coexist.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

CHAT_INI="${COEXIST_CHAT_INI:-$PROJECT_ROOT/models.ini}"
CODER_INI="${COEXIST_CODER_INI:-$PROJECT_ROOT/models-lab.ini}"
CHAT_MODEL="${COEXIST_CHAT_MODEL}"
CODER_MODEL="${COEXIST_CODER_MODEL}"
export COEXIST_CHAT_MODEL COEXIST_CODER_MODEL
C_LIST="${COEXIST_C_LIST:-262144}"
NP_PAIRS="${COEXIST_NP_PAIRS:-4:4}"
FILL_RATIO="${COEXIST_FILL_RATIO:-0.85}"
STRESS_TOKENS="${COEXIST_STRESS_TOKENS:-64}"

# Snapshot keys to restore after the matrix
chat_np0="$(get_ini_section_key "$CHAT_INI" "$CHAT_MODEL" "np")"
chat_c0="$(get_ini_section_key "$CHAT_INI" "$CHAT_MODEL" "c")"
coder_np0="$(get_ini_section_key "$CODER_INI" "$CODER_MODEL" "np")"
coder_c0="$(get_ini_section_key "$CODER_INI" "$CODER_MODEL" "c")"

restore_coexist_ini() {
  [[ -n "$chat_np0" ]] && patch_ini_section "$CHAT_INI" "$CHAT_MODEL" "np" "$chat_np0" || true
  [[ -n "$chat_c0" ]] && patch_ini_section "$CHAT_INI" "$CHAT_MODEL" "c" "$chat_c0" || true
  [[ -n "$coder_np0" ]] && patch_ini_section "$CODER_INI" "$CODER_MODEL" "np" "$coder_np0" || true
  [[ -n "$coder_c0" ]] && patch_ini_section "$CODER_INI" "$CODER_MODEL" "c" "$coder_c0" || true
}
trap restore_coexist_ini EXIT

prepare_coexist_gpu

IFS=',' read -ra C_VALUES <<< "$C_LIST"
IFS=',' read -ra PAIR_VALUES <<< "$NP_PAIRS"

short_prompt="$(fixture_path prompt_short.txt)"
runs_jsonl="$sdir/cells.jsonl"
: >"$runs_jsonl"

run_cell() {
  local c="$1" np_chat="$2" np_coder="$3"
  local cell="c${c}_chat${np_chat}_coder${np_coder}"
  local cell_dir="$sdir/$cell"
  mkdir -p "$cell_dir"
  log "=== cell $cell ==="

  patch_ini_section "$CHAT_INI" "$CHAT_MODEL" "c" "$c"
  patch_ini_section "$CHAT_INI" "$CHAT_MODEL" "np" "$np_chat"
  patch_ini_section "$CODER_INI" "$CODER_MODEL" "c" "$c"
  patch_ini_section "$CODER_INI" "$CODER_MODEL" "np" "$np_coder"

  restart_sticky
  restart_lab_only

  # Reload presets after restart
  curl -sfS "$COEXIST_CHAT_URL/models?reload=1" >/dev/null || true
  curl -sfS "$COEXIST_CODER_URL/models?reload=1" >/dev/null || true

  if ! ensure_model_on_url "$COEXIST_CHAT_URL" "$CHAT_MODEL"; then
    log "FAIL $cell — chat load failed"
    echo "{\"cell\":\"$cell\",\"c\":$c,\"np_chat\":$np_chat,\"np_coder\":$np_coder,\"ok\":false,\"phase\":\"load_chat\"}" >>"$runs_jsonl"
    return 0
  fi
  if ! ensure_model_on_url "$COEXIST_CODER_URL" "$CODER_MODEL"; then
    log "FAIL $cell — coder load failed"
    echo "{\"cell\":\"$cell\",\"c\":$c,\"np_chat\":$np_chat,\"np_coder\":$np_coder,\"ok\":false,\"phase\":\"load_coder\"}" >>"$runs_jsonl"
    return 0
  fi

  local snap_load
  snap_load="$(coexist_mem_snapshot)"
  printf '%s\n' "$snap_load" >"$cell_dir/mem_after_load.json"
  if coexist_over_budget "$snap_load"; then
    log "FAIL $cell — over budget after load: $snap_load"
    echo "{\"cell\":\"$cell\",\"c\":$c,\"np_chat\":$np_chat,\"np_coder\":$np_coder,\"ok\":false,\"phase\":\"load_budget\",\"mem\":$snap_load}" >>"$runs_jsonl"
    return 0
  fi

  # Per-slot fill target (classic split approximation; unified still stresses shared pool)
  local fill_chat_tok fill_coder_tok
  fill_chat_tok="$(awk -v c="$c" -v np="$np_chat" -v r="$FILL_RATIO" 'BEGIN{v=int((c/np)*r); if(v<1024)v=1024; print v}')"
  fill_coder_tok="$(awk -v c="$c" -v np="$np_coder" -v r="$FILL_RATIO" 'BEGIN{v=int((c/np)*r); if(v<1024)v=1024; print v}')"

  write_fill_prompt "$cell_dir/fill_chat.txt" "$fill_chat_tok"
  write_fill_prompt "$cell_dir/fill_coder.txt" "$fill_coder_tok"

  metrics_start "$cell_dir/metrics.csv"
  local ok=1 phase="fill" pids=() i outf

  # Fill all chat slots then all coder slots (sequential groups, concurrent within model)
  for ((i=0; i<np_chat; i++)); do
    outf="$cell_dir/fill_chat_${i}.jsonl"
    pids+=("$(stream_chat_url_bg "$COEXIST_CHAT_URL" "$CHAT_MODEL" "fill_chat_$i" "$cell_dir/fill_chat.txt" "$outf" 8)")
  done
  for ((i=0; i<np_chat; i++)); do
    if ! wait_stream_bg_soft "$cell_dir/fill_chat_${i}.jsonl" "${pids[$i]}"; then
      ok=0
      phase="fill_chat"
      break
    fi
  done
  pids=()

  if [[ "$ok" -eq 1 ]]; then
    for ((i=0; i<np_coder; i++)); do
      outf="$cell_dir/fill_coder_${i}.jsonl"
      pids+=("$(stream_chat_url_bg "$COEXIST_CODER_URL" "$CODER_MODEL" "fill_coder_$i" "$cell_dir/fill_coder.txt" "$outf" 8)")
    done
    for ((i=0; i<np_coder; i++)); do
      if ! wait_stream_bg_soft "$cell_dir/fill_coder_${i}.jsonl" "${pids[$i]}"; then
        ok=0
        phase="fill_coder"
        break
      fi
    done
  fi

  local snap_fill
  snap_fill="$(coexist_mem_snapshot)"
  printf '%s\n' "$snap_fill" >"$cell_dir/mem_after_fill.json"
  if [[ "$ok" -eq 1 ]] && coexist_over_budget "$snap_fill"; then
    ok=0
    phase="fill_budget"
  fi

  # Stress: all slots decode concurrently (short prompt, more tokens)
  pids=()
  if [[ "$ok" -eq 1 ]]; then
    phase="stress"
    for ((i=0; i<np_chat; i++)); do
      outf="$cell_dir/stress_chat_${i}.jsonl"
      pids+=("$(stream_chat_url_bg "$COEXIST_CHAT_URL" "$CHAT_MODEL" "stress_chat_$i" "$short_prompt" "$outf" "$STRESS_TOKENS")")
    done
    local base_coder=${#pids[@]}
    for ((i=0; i<np_coder; i++)); do
      outf="$cell_dir/stress_coder_${i}.jsonl"
      pids+=("$(stream_chat_url_bg "$COEXIST_CODER_URL" "$CODER_MODEL" "stress_coder_$i" "$short_prompt" "$outf" "$STRESS_TOKENS")")
    done
    for ((i=0; i<np_chat; i++)); do
      if ! wait_stream_bg_soft "$cell_dir/stress_chat_${i}.jsonl" "${pids[$i]}"; then
        ok=0
        phase="stress_chat"
        break
      fi
    done
    if [[ "$ok" -eq 1 ]]; then
      for ((i=0; i<np_coder; i++)); do
        if ! wait_stream_bg_soft "$cell_dir/stress_coder_${i}.jsonl" "${pids[$((base_coder+i))]}"; then
          ok=0
          phase="stress_coder"
          break
        fi
      done
    fi
  fi

  # Aggregate stress tok/s via summaries (filled below)
  metrics_stop

  local peak snap_end
  snap_end="$(coexist_mem_snapshot)"
  printf '%s\n' "$snap_end" >"$cell_dir/mem_after_stress.json"
  peak="$(coexist_metrics_peak "$cell_dir/metrics.csv")"
  if [[ "$ok" -eq 1 ]] && coexist_over_budget "$snap_end"; then
    ok=0
    phase="stress_budget"
  fi

  for ((i=0; i<np_chat; i++)); do
    [[ -f "$cell_dir/stress_chat_${i}.jsonl" ]] || continue
    summarize_jsonl "$cell_dir/stress_chat_${i}.jsonl" "$cell_dir/stress_chat_${i}_summary.json" || true
  done
  for ((i=0; i<np_coder; i++)); do
    [[ -f "$cell_dir/stress_coder_${i}.jsonl" ]] || continue
    summarize_jsonl "$cell_dir/stress_coder_${i}.jsonl" "$cell_dir/stress_coder_${i}_summary.json" || true
  done

  bench_python - "$cell_dir" "$np_chat" "$np_coder" "$cell" "$c" "$ok" "$phase" "$snap_load" "$snap_fill" "$snap_end" "$peak" "$runs_jsonl" <<'PY'
import json, os, sys, statistics
(
    cell_dir, npc, npk, cell, c, ok, phase,
    snap_load, snap_fill, snap_end, peak, out_path,
) = sys.argv[1:13]
npc, npk, c, ok = int(npc), int(npk), int(c), ok == "1"

def tps_list(prefix, n):
    vals = []
    for i in range(n):
        path = os.path.join(cell_dir, f"{prefix}_{i}_summary.json")
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        t = d.get("tokens_per_sec")
        if t is not None:
            vals.append(float(t))
    return vals

chat_tps = tps_list("stress_chat", npc)
coder_tps = tps_list("stress_coder", npk)
entry = {
    "cell": cell,
    "c": c,
    "np_chat": npc,
    "np_coder": npk,
    "slots_total": npc + npk,
    "ok": ok,
    "phase": phase if not ok else "pass",
    "mem_load": json.loads(snap_load),
    "mem_fill": json.loads(snap_fill),
    "mem_end": json.loads(snap_end),
    "metrics_peak": json.loads(peak),
    "chat_tps_mean": round(statistics.mean(chat_tps), 2) if chat_tps else None,
    "coder_tps_mean": round(statistics.mean(coder_tps), 2) if coder_tps else None,
}
with open(os.path.join(cell_dir, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(entry, f, indent=2)
    f.write("\n")
with open(out_path, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry) + "\n")
print(("PASS" if ok else "FAIL") + f" {cell} phase={entry['phase']} gtt_peak={entry['metrics_peak'].get('gtt_used_mb')}")
PY
}

for c in "${C_VALUES[@]}"; do
  c="${c// /}"
  [[ -n "$c" ]] || continue
  for pair in "${PAIR_VALUES[@]}"; do
    pair="${pair// /}"
    [[ -n "$pair" ]] || continue
    np_chat="${pair%%:*}"
    np_coder="${pair##*:}"
    [[ "$np_chat" =~ ^[0-9]+$ && "$np_coder" =~ ^[0-9]+$ ]] || die "bad NP pair: $pair (want chat:coder)"
    run_cell "$c" "$np_chat" "$np_coder"
  done
done

bench_python - "$sdir" <<'PY'
import json, os, sys
sdir = sys.argv[1]
rows = []
path = os.path.join(sdir, "cells.jsonl")
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))

passed = [r for r in rows if r.get("ok")]
# Prefer more total slots, then higher c, then higher mean tok/s
def score(r):
    tps = (r.get("chat_tps_mean") or 0) + (r.get("coder_tps_mean") or 0)
    return (r.get("slots_total") or 0, r.get("c") or 0, tps)

best = max(passed, key=score) if passed else None
out = {
    "scenario": "11_coexist_capacity",
    "chat_model": os.environ.get("COEXIST_CHAT_MODEL"),
    "coder_model": os.environ.get("COEXIST_CODER_MODEL"),
    "runs": rows,
    "recommended": None,
}
if best:
    out["recommended"] = {
        "c": best["c"],
        "np_chat": best["np_chat"],
        "np_coder": best["np_coder"],
        "cell": best["cell"],
        "chat_tps_mean": best.get("chat_tps_mean"),
        "coder_tps_mean": best.get("coder_tps_mean"),
        "gtt_peak_mb": (best.get("metrics_peak") or {}).get("gtt_used_mb"),
        "mem_avail_min_mb": (best.get("metrics_peak") or {}).get("mem_avail_mb_min"),
    }
with open(os.path.join(sdir, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
if best:
    print(f"recommended: c={best['c']} np_chat={best['np_chat']} np_coder={best['np_coder']}")
else:
    print("recommended: none (all cells failed)")
PY

log "done $SCENARIO → $sdir/summary.json"
