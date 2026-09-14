#!/usr/bin/env bash
# Dual capacity: two concurrent servers (bench-a + bench-b) ≈ sticky chat + coder.
# Context sizes auto-scale from host GTT/RAM unless CAPACITY_DUAL_C is set.
#
#   ./bench capacity dual
#   CAPACITY_DUAL_C=131072 ./bench capacity dual
#   CAPACITY_DUAL_C=32768,65536,131072 ./bench capacity dual --kv q5_0,q4_0
set -euo pipefail

CAPACITY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$CAPACITY_ROOT/lib/common.sh"

# Auto-skip on small hosts (same defaults as matrix profiles). Override:
#   CAPACITY_FORCE_DUAL=1 ./bench capacity dual
#   CAPACITY_DUAL_SKIP_BELOW_RAM_GIB=0 CAPACITY_DUAL_SKIP_BELOW_GTT_GIB=0 …
CAPACITY_DUAL_SKIP_BELOW_RAM_GIB="${CAPACITY_DUAL_SKIP_BELOW_RAM_GIB:-64}"
CAPACITY_DUAL_SKIP_BELOW_GTT_GIB="${CAPACITY_DUAL_SKIP_BELOW_GTT_GIB:-48}"
if reason="$(dual_host_too_small)"; then
  log "skip dual: $reason (set CAPACITY_FORCE_DUAL=1 to run anyway)"
  exit 0
fi

KV_LIST="${CAPACITY_DUAL_KV_LIST:-${CAPACITY_KV_LIST:-q8_0,q5_0,q4_0}}"
C_LIST="$(resolve_dual_c_list)"
export CAPACITY_DUAL_C_LIST="$C_LIST"

cleanup_dual() {
  capacity_bench_cleanup
}
trap cleanup_dual EXIT

capacity_bench_prepare dual

MODELS=()
mapfile -t MODELS < <(resolve_bench_models)
[[ ${#MODELS[@]} -gt 0 ]] || die "no models in models-bench.ini"

export CAPACITY_MODEL_LIST
CAPACITY_MODEL_LIST="$(IFS=,; echo "${MODELS[*]}")"
log "models (${#MODELS[@]}): $CAPACITY_MODEL_LIST"
log "dual c list: $C_LIST"

detect_server_fingerprint
probe_kv_cache_types
filter_kv_list_inplace "$KV_LIST"
KV_LIST="$CAPACITY_KV_LIST"
init_capacity_run "dual"
IFS=',' read -ra KV_VALUES <<< "$KV_LIST"
IFS=',' read -ra C_VALUES <<< "$C_LIST"

# Plan cells (ledger skips up front; q4 min-c not applied in dual)
capacity_progress_build_plan "dual" "$CAPACITY_MODEL_LIST" "$KV_LIST" "$C_LIST" 0
capacity_progress_init

run_dual_cell() {
  local MODEL="$1" kv="$2" C_VAL="$3"
  local key cell_dir fill_tok ok=1 phase="ok"
  local snap_load snap_end peak pid_a pid_b
  key="$(cell_key dual "$MODEL" "$kv" "$C_VAL")"
  cell_dir="$CAPACITY_RUN_DIR/${MODEL}/dual_${kv}_c${C_VAL}"

  capacity_progress_begin "$key"

  if should_skip_cell "$key"; then
    log "skip $key"
    echo "{\"key\":\"$key\",\"skipped\":true,\"ok\":true,\"mode\":\"dual\",\"model\":\"$MODEL\",\"kv\":\"$kv\",\"c\":$C_VAL}" \
      >>"$CAPACITY_RUN_DIR/matrix.jsonl"
    capacity_progress_end skip
    return 0
  fi

  mkdir -p "$cell_dir"
  log "start $key"
  log "=== dual $MODEL kv=$kv c=$C_VAL ==="

  patch_bench_section "$CAPACITY_INI_A" "$MODEL" "$kv" "$C_VAL"
  patch_bench_section "$CAPACITY_INI_B" "$MODEL" "$kv" "$C_VAL"
  restart_bench_ab

  if ! ensure_model_on_url "$CAPACITY_URL_A" "$MODEL" "$key (a)"; then
    ok=0; phase="load_a"
  elif ! ensure_model_on_url "$CAPACITY_URL_B" "$MODEL" "$key (b)"; then
    ok=0; phase="load_b"
  fi

  snap_load="$(mem_snapshot)"
  printf '%s\n' "$snap_load" >"$cell_dir/mem_after_load.json"

  if [[ "$ok" -eq 1 ]]; then
    fill_tok="$(awk -v c="$C_VAL" -v r="$CAPACITY_FILL_RATIO" 'BEGIN{v=int(c*r); if(v<1024)v=1024; print v}')"
    write_fill_prompt "$cell_dir/fill.txt" "$fill_tok"
    metrics_start "$cell_dir/metrics.csv"
    stream_once "$CAPACITY_URL_A" "$MODEL" "a" "$cell_dir/fill.txt" "$cell_dir/stream_a.jsonl" "$CAPACITY_MAX_TOKENS" &
    pid_a=$!
    stream_once "$CAPACITY_URL_B" "$MODEL" "b" "$cell_dir/fill.txt" "$cell_dir/stream_b.jsonl" "$CAPACITY_MAX_TOKENS" &
    pid_b=$!
    if ! wait "$pid_a"; then ok=0; phase="stream_a"; fi
    if ! wait "$pid_b"; then ok=0; phase="stream_b"; fi
    metrics_stop
    summarize_stream "$cell_dir/stream_a.jsonl" "$cell_dir/stream_a_summary.json" >/dev/null || true
    summarize_stream "$cell_dir/stream_b.jsonl" "$cell_dir/stream_b_summary.json" >/dev/null || true
  fi

  snap_end="$(mem_snapshot)"
  printf '%s\n' "$snap_end" >"$cell_dir/mem_after.json"
  peak="$(metrics_peak_from_csv "$cell_dir/metrics.csv")"

  bench_python - "$cell_dir" "$key" "$MODEL" "$kv" "$C_VAL" "$ok" "$phase" \
    "$snap_load" "$snap_end" "$peak" "$CAPACITY_BACKEND" \
    "$CAPACITY_RUN_DIR/matrix.jsonl" "$CELLS_LEDGER" <<'PY'
import json, os, sys
(
    cell_dir, key, model, kv, c, ok, phase,
    snap_load, snap_end, peak, backend,
    matrix_path, ledger_path,
) = sys.argv[1:14]
row = {
    "key": key,
    "mode": "dual",
    "backend": backend,
    "model": model,
    "kv": kv,
    "c": int(c),
    "ok": ok == "1",
    "phase": phase,
    "mem_after_load": json.loads(snap_load),
    "mem_after": json.loads(snap_end),
    "metrics_peak": json.loads(peak),
    "skipped": False,
    "server_version": os.environ.get("CAPACITY_SERVER_VERSION", ""),
    "image_id": os.environ.get("CAPACITY_IMAGE_ID", ""),
    "image_name": os.environ.get("CAPACITY_IMAGE_NAME", ""),
}
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
  # Ascending c: stop this model+kv ladder on first hard fail (save time on small hosts)
  if [[ "$ok" -ne 1 && "${CAPACITY_DUAL_STOP_ON_FAIL:-1}" == "1" ]]; then
    log "stop ladder for $MODEL kv=$kv after fail at c=$C_VAL"
    return 2
  fi
  return 0
}

for MODEL in "${MODELS[@]}"; do
  [[ -n "$MODEL" ]] || continue
  for kv in "${KV_VALUES[@]}"; do
    kv="${kv// /}"
    [[ -n "$kv" ]] || continue
    for c in "${C_VALUES[@]}"; do
      c="${c// /}"
      [[ -n "$c" ]] || continue
      rc=0
      run_dual_cell "$MODEL" "$kv" "$c" || rc=$?
      if [[ "$rc" -eq 2 ]]; then
        capacity_progress_skip_rest_of_ladder "$MODEL" "$kv" "dual"
        break
      fi
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
lines = [
    "# Capacity dual (2× servers)",
    "",
    f"c list: {os.environ.get('CAPACITY_DUAL_C_LIST', '—')}",
    "",
    "| model | kv | c | ok | phase | GTT peak MiB | mem avail MiB |",
    "| --- | --- | ---: | --- | --- | ---: | ---: |",
]
for r in rows:
    if r.get("skipped"):
        lines.append(f"| {r['model']} | {r['kv']} | {r.get('c','—')} | skip | — | — | — |")
        continue
    peak = (r.get("metrics_peak") or {}).get("gtt_used_mb")
    mem = (r.get("mem_after") or {}).get("mem_avail_mb")
    lines.append(
        f"| {r['model']} | {r['kv']} | {r.get('c')} | {r.get('ok')} | {r.get('phase')} | "
        f"{peak or '—'} | {mem or '—'} |"
    )
path = os.path.join(run_dir, "compare.md")
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(path)
PY

mkdir -p "$CAPACITY_OUT/latest"
cp -a "$CAPACITY_RUN_DIR/compare.md" "$CAPACITY_OUT/latest/compare.md"
cp -a "$CAPACITY_RUN_DIR/manifest.json" "$CAPACITY_OUT/latest/manifest.json"
cp -a "$CAPACITY_RUN_DIR/matrix.jsonl" "$CAPACITY_OUT/latest/matrix.jsonl"

log "done dual → $CAPACITY_RUN_DIR (c=$C_LIST)"
