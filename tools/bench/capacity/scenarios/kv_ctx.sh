#!/usr/bin/env bash
# Solo KV×ctx matrix: auto-sync bench INIs, all models (or --model), KV×c cells.
set -euo pipefail

CAPACITY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$CAPACITY_ROOT/lib/common.sh"

KV_LIST="${CAPACITY_KV_LIST}"
C_LIST="${CAPACITY_C_LIST}"

ensure_synced() {
  if [[ "${CAPACITY_AUTO_SYNC:-1}" == "1" ]]; then
    log "auto-sync models-bench.ini from: $CAPACITY_SYNC_SOURCES"
    sync_bench_inis "$CAPACITY_SYNC_SOURCES"
  fi
}

cleanup_kv_ctx() {
  # Re-sync restores bench INIs from sticky/lab sources (undo ctk/c patches)
  if [[ "${CAPACITY_AUTO_SYNC:-1}" == "1" ]]; then
    sync_bench_inis "$CAPACITY_SYNC_SOURCES" >/dev/null || true
  fi
  [[ "${CAPACITY_NO_RESTORE:-0}" == "1" ]] || restore_after_capacity
}
trap cleanup_kv_ctx EXIT

ensure_synced

# Resolve model list (--model / CAPACITY_MODELS / --no-vl)
MODELS=()
mapfile -t MODELS < <(resolve_bench_models)
[[ ${#MODELS[@]} -gt 0 ]] || die "no models in models-bench.ini — check sync sources / GGUFs / --model"

export CAPACITY_MODEL_LIST
CAPACITY_MODEL_LIST="$(IFS=,; echo "${MODELS[*]}")"
log "models (${#MODELS[@]}): $CAPACITY_MODEL_LIST"

prepare_capacity_gpu
start_bench_a
detect_server_fingerprint
probe_kv_cache_types
filter_kv_list_inplace "${CAPACITY_KV_LIST}"
KV_LIST="$CAPACITY_KV_LIST"
init_capacity_run "kv-ctx"
IFS=',' read -ra KV_VALUES <<< "$KV_LIST"
IFS=',' read -ra C_VALUES <<< "$C_LIST"
q4_min_c="${CAPACITY_Q4_MIN_C:-131072}"

# Plan cells (ledger/q4 skips classified up front — ETA only counts must-run)
capacity_progress_build_plan "solo" "$CAPACITY_MODEL_LIST" "$KV_LIST" "$C_LIST" "$q4_min_c"
capacity_progress_init

run_cell() {
  local MODEL="$1" kv="$2" c="$3"
  local key cell_dir fill_tok ok=1 phase="ok" t0 t1 dt
  local snap_before snap_after peak
  key="$(cell_key solo "$MODEL" "$kv" "$c")"
  cell_dir="$CAPACITY_RUN_DIR/${MODEL}/solo_${kv}_c${c}"

  capacity_progress_begin "$key"

  if should_skip_cell "$key"; then
    log "skip $key"
    echo "{\"key\":\"$key\",\"skipped\":true,\"ok\":true,\"mode\":\"solo\",\"model\":\"$MODEL\",\"kv\":\"$kv\",\"c\":$c}" \
      >>"$CAPACITY_RUN_DIR/matrix.jsonl"
    capacity_progress_end skip
    return 0
  fi

  if [[ "$kv" == q4_0 || "$kv" == q4_1 || "$kv" == iq4_nl ]] && [[ "$c" -lt "$q4_min_c" ]]; then
    log "skip $key (q4-family below min c=$q4_min_c)"
    echo "{\"key\":\"$key\",\"skipped\":true,\"reason\":\"q4_min_c\",\"ok\":true,\"mode\":\"solo\",\"model\":\"$MODEL\",\"kv\":\"$kv\",\"c\":$c}" \
      >>"$CAPACITY_RUN_DIR/matrix.jsonl"
    capacity_progress_end skip
    return 0
  fi

  mkdir -p "$cell_dir"
  log "start $key"
  log "=== $MODEL  kv=$kv  c=$c ==="

  patch_bench_section "$CAPACITY_INI_A" "$MODEL" "$kv" "$c"
  restart_bench_a

  if ! ensure_model_on_url "$CAPACITY_URL_A" "$MODEL" "$key"; then
    ok=0
    phase="load"
  fi

  snap_before="$(mem_snapshot)"
  printf '%s\n' "$snap_before" >"$cell_dir/mem_before.json"

  if [[ "$ok" -eq 1 ]]; then
    fill_tok="$(awk -v c="$c" -v r="$CAPACITY_FILL_RATIO" 'BEGIN{v=int(c*r); if(v<1024)v=1024; print v}')"
    write_fill_prompt "$cell_dir/fill.txt" "$fill_tok"
    metrics_start "$cell_dir/metrics.csv"
    t0="$(date +%s%3N 2>/dev/null || date +%s000)"
    if stream_once "$CAPACITY_URL_A" "$MODEL" "solo" "$cell_dir/fill.txt" "$cell_dir/stream.jsonl" "$CAPACITY_MAX_TOKENS"; then
      phase="ok"
    else
      ok=0
      phase="stream"
    fi
    t1="$(date +%s%3N 2>/dev/null || date +%s000)"
    metrics_stop
    dt="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", (b-a)/1000.0}')"
    summarize_stream "$cell_dir/stream.jsonl" "$cell_dir/stream_summary.json" >/dev/null || true
  else
    dt="null"
  fi

  snap_after="$(mem_snapshot)"
  printf '%s\n' "$snap_after" >"$cell_dir/mem_after.json"
  peak="$(metrics_peak_from_csv "$cell_dir/metrics.csv")"

  bench_python - "$cell_dir" "$key" "$MODEL" "$kv" "$c" "$ok" "$phase" \
    "$snap_before" "$snap_after" "$peak" "$dt" "$CAPACITY_BACKEND" \
    "$CAPACITY_RUN_DIR/matrix.jsonl" "$CELLS_LEDGER" <<'PY'
import json, os, sys
(
    cell_dir, key, model, kv, c, ok, phase,
    snap_before, snap_after, peak, dt, backend,
    matrix_path, ledger_path,
) = sys.argv[1:15]
row = {
    "key": key,
    "mode": "solo",
    "backend": backend,
    "model": model,
    "kv": kv,
    "c": int(c),
    "ok": ok == "1",
    "phase": phase,
    "elapsed_s": None if dt == "null" else float(dt),
    "mem_before": json.loads(snap_before),
    "mem_after": json.loads(snap_after),
    "metrics_peak": json.loads(peak),
    "skipped": False,
    "server_version": os.environ.get("CAPACITY_SERVER_VERSION", ""),
    "image_id": os.environ.get("CAPACITY_IMAGE_ID", ""),
    "image_name": os.environ.get("CAPACITY_IMAGE_NAME", ""),
}
stream_path = os.path.join(cell_dir, "stream_summary.json")
if os.path.isfile(stream_path):
    with open(stream_path, encoding="utf-8") as f:
        row["stream"] = json.load(f)
with open(os.path.join(cell_dir, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(row, f, indent=2)
    f.write("\n")
line = json.dumps(row, ensure_ascii=False)
with open(matrix_path, "a", encoding="utf-8") as f:
    f.write(line + "\n")
os.makedirs(os.path.dirname(ledger_path), exist_ok=True)
with open(ledger_path, "a", encoding="utf-8") as f:
    f.write(line + "\n")
print(f"done  {key} ok={row['ok']} phase={phase}")
PY
  capacity_progress_end run
}

for MODEL in "${MODELS[@]}"; do
  [[ -n "$MODEL" ]] || continue
  log "######## model $MODEL ########"
  for kv in "${KV_VALUES[@]}"; do
    kv="${kv// /}"
    [[ -n "$kv" ]] || continue
    for c in "${C_VALUES[@]}"; do
      c="${c// /}"
      [[ -n "$c" ]] || continue
      run_cell "$MODEL" "$kv" "$c"
    done
  done
done

bench_python - "$CAPACITY_RUN_DIR" <<'PY'
import json, os, sys
run_dir = sys.argv[1]
rows = []
with open(os.path.join(run_dir, "matrix.jsonl"), encoding="utf-8") as f:
    for line in f:
        if line.strip():
            rows.append(json.loads(line))
lines = ["# Capacity KV×ctx", ""]
by_model = {}
for r in rows:
    by_model.setdefault(r["model"], []).append(r)
for model, mrows in sorted(by_model.items()):
    kvs = sorted({r["kv"] for r in mrows})
    cs = sorted({r["c"] for r in mrows})
    by = {(r["kv"], r["c"]): r for r in mrows}
    lines += [f"## {model}", "", "| c \\ kv | " + " | ".join(kvs) + " |", "| --- | " + " | ".join(["---:"] * len(kvs)) + " |"]
    for c in cs:
        cells = []
        for kv in kvs:
            r = by.get((kv, c))
            if not r:
                cells.append("—")
            elif r.get("skipped"):
                cells.append("skip")
            elif not r.get("ok"):
                cells.append(f"FAIL:{r.get('phase')}")
            else:
                gtt = (r.get("metrics_peak") or {}).get("gtt_used_mb") or (r.get("mem_after") or {}).get("gtt_used_mb")
                cells.append(str(gtt) if gtt is not None else "?")
        lines.append(f"| {c} | " + " | ".join(cells) + " |")
    lines.append("")
path = os.path.join(run_dir, "compare.md")
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print(path)
PY

mkdir -p "$CAPACITY_OUT/latest"
cp -a "$CAPACITY_RUN_DIR/compare.md" "$CAPACITY_OUT/latest/compare.md"
cp -a "$CAPACITY_RUN_DIR/manifest.json" "$CAPACITY_OUT/latest/manifest.json"
cp -a "$CAPACITY_RUN_DIR/matrix.jsonl" "$CAPACITY_OUT/latest/matrix.jsonl"

log "done kv-ctx → $CAPACITY_RUN_DIR (${#MODELS[@]} model(s))"
