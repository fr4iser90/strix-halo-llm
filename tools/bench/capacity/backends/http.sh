#!/usr/bin/env bash
# Capacity suite — HTTP backend (OpenAI-compatible engines).
# KV types do not apply — recorded as kv=native. Server CTX must allow the ladder.
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

CAPACITY_OUT="${CAPACITY_OUT:-$PROJECT_ROOT/output/bench/capacity}"
CELLS_LEDGER="${CAPACITY_OUT}/cells.jsonl"
C_LIST="${CAPACITY_C_LIST:-${HALOGEN_C_LIST:-32768,65536,131072,196608,262144}}"
FILL_RATIO="${CAPACITY_FILL_RATIO:-0.90}"
MAX_TOKENS="${CAPACITY_MAX_TOKENS:-32}"
SKIP_EXISTING="${CAPACITY_SKIP_EXISTING:-1}"

mkdir -p "$CAPACITY_OUT"
bench_http_require_up
bench_http_fingerprint

MODELS=()
if ! bench_http_load_models MODELS; then
  bench_http_die "no models (set --model / MATRIX_MODELS or check /v1/models)"
fi
[[ ${#MODELS[@]} -gt 0 ]] || bench_http_die "no models (set --model / MATRIX_MODELS or check /v1/models)"
bench_http_log "capacity models (${#MODELS[@]}): ${MODELS[*]}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAPACITY_RUN_DIR="$CAPACITY_OUT/$STAMP"
mkdir -p "$CAPACITY_RUN_DIR"
: >"$CAPACITY_RUN_DIR/matrix.jsonl"
export CAPACITY_STAMP="$STAMP"

bench_python - "$CAPACITY_RUN_DIR/manifest.json" "$STAMP" <<'PY'
import json, os, sys
path, stamp = sys.argv[1], sys.argv[2]
data = {
    "stamp": stamp,
    "tag": "http-kv-ctx",
    "engine": os.environ.get("BENCH_ENGINE", "halogen-flash"),
    "backend": "http",
    "model_list": os.environ.get("MATRIX_MODELS") or os.environ.get("HALOGEN_MODEL") or "",
    "url_a": os.environ.get("BENCH_HTTP_BASE_URL") or os.environ.get("HALOGEN_BASE_URL", ""),
    "kv_list": "native",
    "c_list": os.environ.get("CAPACITY_C_LIST") or os.environ.get("HALOGEN_C_LIST", ""),
    "server_version": os.environ.get("CAPACITY_SERVER_VERSION", ""),
    "image_id": os.environ.get("CAPACITY_IMAGE_ID", ""),
    "image_name": os.environ.get("CAPACITY_IMAGE_NAME", ""),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

IFS=',' read -ra C_VALUES <<< "$C_LIST"

should_skip() {
  local key="$1"
  [[ "$SKIP_EXISTING" == "1" ]] || return 1
  [[ -f "$CELLS_LEDGER" ]] || return 1
  bench_python - "$CELLS_LEDGER" "$key" "${CAPACITY_SERVER_VERSION:-}" <<'PY'
import json, sys
path, key, cur_ver = sys.argv[1:4]
best = None
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("key") == key:
                best = row
except FileNotFoundError:
    pass
if not best or best.get("skipped"):
    raise SystemExit(1)
if not best.get("ok"):
    raise SystemExit(1)
old_ver = (best.get("server_version") or "").strip()
if cur_ver and cur_ver != "unknown" and old_ver and old_ver != cur_ver:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

for MODEL in "${MODELS[@]}"; do
  [[ -n "$MODEL" ]] || continue
  for c in "${C_VALUES[@]}"; do
    c="${c// /}"
    [[ -n "$c" ]] || continue
    key="${ENGINE}|http|solo|${MODEL}|native|${c}"
    cell_dir="$CAPACITY_RUN_DIR/${MODEL}/solo_native_c${c}"
    if should_skip "$key"; then
      bench_http_log "skip $key"
      echo "{\"key\":\"$key\",\"skipped\":true,\"ok\":true,\"mode\":\"solo\",\"engine\":\"$ENGINE\",\"backend\":\"http\",\"model\":\"$MODEL\",\"kv\":\"native\",\"c\":$c}" \
        >>"$CAPACITY_RUN_DIR/matrix.jsonl"
      continue
    fi
    mkdir -p "$cell_dir"
    bench_http_log "=== $MODEL  c=$c ==="
    fill_tok="$(bench_python -c "c=int('$c'); r=float('$FILL_RATIO'); print(max(1024, int(c*r)))")"
    bench_http_write_fill_prompt "$cell_dir/fill.txt" "$fill_tok"
    ok=1
    phase="ok"
    stream_err=""
    if ! stream_err="$(bench_http_stream_once "$MODEL" "cap" "$cell_dir/fill.txt" "$cell_dir/stream.jsonl" "$MAX_TOKENS" 2>&1)"; then
      ok=0
      phase="stream"
      printf '%s\n' "$stream_err" >&2
      # Gufo / VL engines: oversized fill → context_length_exceeded ("image prompt…")
      if printf '%s' "$stream_err" | grep -qiE 'context_length_exceeded|exceeds model context|image prompt exceeds'; then
        phase="ctx_exceeded"
        bench_http_log "context exceeded at c=$c — stop ladder for $MODEL"
        BENCH_ENGINE="$ENGINE" bench_python - "$cell_dir" "$key" "$MODEL" "$c" "$ok" "$phase" "$fill_tok" \
          "$CAPACITY_RUN_DIR/matrix.jsonl" "$CELLS_LEDGER" <<'PY'
import json, os, sys
cell_dir, key, model, c, ok, phase, fill_tok, matrix_path, ledger_path = sys.argv[1:10]
fill_n = int(fill_tok) if str(fill_tok).isdigit() else 0
row = {
    "key": key, "mode": "solo", "engine": os.environ.get("BENCH_ENGINE", ""),
    "backend": "http", "model": model, "kv": "native", "c": int(c),
    "fill_tokens": fill_n, "ok": False, "phase": phase, "skipped": False,
    "server_version": os.environ.get("CAPACITY_SERVER_VERSION", ""),
    "image_id": os.environ.get("CAPACITY_IMAGE_ID", ""),
    "image_name": os.environ.get("CAPACITY_IMAGE_NAME", ""),
}
line = json.dumps(row, ensure_ascii=False)
with open(os.path.join(cell_dir, "summary.json"), "w", encoding="utf-8") as f:
    f.write(line + "\n")
for path in (matrix_path, ledger_path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")
print(f"done  {key} ok=False phase={phase}")
PY
        break
      fi
    fi
    bench_http_summarize_stream "$cell_dir/stream.jsonl" "$cell_dir/stream_summary.json" >/dev/null || true

    BENCH_ENGINE="$ENGINE" bench_python - "$cell_dir" "$key" "$MODEL" "$c" "$ok" "$phase" "$fill_tok" \
      "$CAPACITY_RUN_DIR/matrix.jsonl" "$CELLS_LEDGER" <<'PY'
import json, os, sys
cell_dir, key, model, c, ok, phase, fill_tok, matrix_path, ledger_path = sys.argv[1:10]
fill_n = int(fill_tok) if str(fill_tok).isdigit() else 0
row = {
    "key": key,
    "mode": "solo",
    "engine": os.environ.get("BENCH_ENGINE", "halogen-flash"),
    "backend": "http",
    "model": model,
    "kv": "native",
    "c": int(c),
    "fill_tokens": fill_n,
    "ok": ok == "1",
    "phase": phase,
    "skipped": False,
    "server_version": os.environ.get("CAPACITY_SERVER_VERSION", ""),
    "image_id": os.environ.get("CAPACITY_IMAGE_ID", ""),
    "image_name": os.environ.get("CAPACITY_IMAGE_NAME", ""),
}
stream_path = os.path.join(cell_dir, "stream_summary.json")
if os.path.isfile(stream_path):
    with open(stream_path, encoding="utf-8") as f:
        stream = json.load(f)
    row["stream"] = stream
    ttft_ms = stream.get("ttft_ms")
    if ttft_ms and ttft_ms > 0 and fill_n > 0:
        row["prefill_s"] = round(ttft_ms / 1000.0, 3)
        row["prefill_tok_s"] = round(fill_n / (ttft_ms / 1000.0), 2)
    if stream.get("elapsed_s") is not None:
        row["elapsed_s"] = stream["elapsed_s"]
with open(os.path.join(cell_dir, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(row, f, indent=2)
    f.write("\n")
line = json.dumps(row, ensure_ascii=False)
with open(matrix_path, "a", encoding="utf-8") as f:
    f.write(line + "\n")
os.makedirs(os.path.dirname(ledger_path), exist_ok=True)
with open(ledger_path, "a", encoding="utf-8") as f:
    f.write(line + "\n")
extra = ""
if row.get("prefill_tok_s") is not None:
    extra = f" prefill={row.get('prefill_s')}s {row.get('prefill_tok_s')} t/s"
print(f"done  {key} ok={row['ok']} phase={phase}{extra}")
PY
  done
done

mkdir -p "$CAPACITY_OUT/latest"
cp -f "$CAPACITY_RUN_DIR/manifest.json" "$CAPACITY_OUT/latest/manifest.json" 2>/dev/null || true
bench_http_log "capacity → $CELLS_LEDGER (run $CAPACITY_RUN_DIR)"
