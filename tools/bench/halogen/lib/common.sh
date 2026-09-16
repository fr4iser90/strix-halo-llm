#!/usr/bin/env bash
# Shared Halogen Flash bench helpers (OpenAI-compatible API).
# Assumes the API is already running at HALOGEN_BASE_URL (default :8731).
# Does NOT start/stop compose — bring your own server.
set -euo pipefail

HALOGEN_BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$HALOGEN_BENCH_ROOT/../../.." && pwd)"

# shellcheck source=../../lib/python.sh
source "$PROJECT_ROOT/tools/bench/lib/python.sh"
# shellcheck source=../../lib/engine.sh
source "$PROJECT_ROOT/tools/bench/lib/engine.sh"
# shellcheck source=../../lib/engines/halogen.sh
source "$PROJECT_ROOT/tools/bench/lib/engines/halogen.sh"

export BENCH_ENGINE=halogen-flash
BENCH_ENGINE="$(bench_engine_normalize halogen-flash)"
export BENCH_ENGINE

HALOGEN_BASE_URL="${HALOGEN_BASE_URL:-http://127.0.0.1:8731}"
HALOGEN_BASE_URL="${HALOGEN_BASE_URL%/}"
export HALOGEN_BASE_URL

STREAM_CLIENT="${STREAM_CLIENT:-$PROJECT_ROOT/tools/bench/scheduling/lib/stream_client.py}"
HALOGEN_OUT="${HALOGEN_OUT:-$PROJECT_ROOT/output/bench}"

log() { printf '[bench halogen] %s\n' "$*"; }
die() { printf '[bench halogen] error: %s\n' "$*" >&2; exit 1; }

halogen_require_up() {
  local url="${1:-$HALOGEN_BASE_URL}"
  local tries="${HALOGEN_WAIT_TRIES:-60}" i=0
  while [[ "$i" -lt "$tries" ]]; do
    if curl -sfS --max-time 3 "${url}/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  die "Halogen API not reachable at ${url}/v1/models — start the server first"
}

# Print model ids from /v1/models (one per line).
halogen_list_models() {
  local url="${1:-$HALOGEN_BASE_URL}"
  curl -sfS --max-time 10 "${url}/v1/models" | bench_python - <<'PY'
import json, sys
data = json.load(sys.stdin)
for m in data.get("data") or []:
    mid = (m.get("id") or "").strip()
    if mid:
        print(mid)
PY
}

# Resolve models: HALOGEN_MODELS / MATRIX_MODELS / CAPACITY_MODELS / --model list, else API.
halogen_resolve_models() {
  local csv="${HALOGEN_MODELS:-${MATRIX_MODELS:-${CAPACITY_MODELS:-${QUALITY_MODEL:-}}}}"
  local -a out=()
  if [[ -n "$csv" ]]; then
    local IFS=',' p
    for p in $csv; do
      p="${p// /}"
      [[ -n "$p" ]] && out+=("$p")
    done
  else
    mapfile -t out < <(halogen_list_models)
  fi
  [[ ${#out[@]} -gt 0 ]] || die "no Halogen models (set --model / MATRIX_MODELS or check /v1/models)"
  printf '%s\n' "${out[@]}"
}

halogen_fingerprint() {
  local url="${1:-$HALOGEN_BASE_URL}" raw ver
  raw="$(curl -sfS --max-time 5 "${url}/health" 2>/dev/null || true)"
  if [[ -n "$raw" ]]; then
    ver="$(printf '%s' "$raw" | bench_python - <<'PY'
import json, sys
raw = sys.stdin.read().strip()
try:
    data = json.loads(raw)
    if isinstance(data, dict):
        bits = []
        for k in ("version", "api_version", "engine_version", "status"):
            if data.get(k) is not None:
                bits.append(f"{k}={data.get(k)}")
        print(" ".join(bits) if bits else json.dumps(data, separators=(",", ":"))[:200])
    else:
        print(str(data)[:200])
except Exception:
    print(raw[:200].replace("\n", " "))
PY
)"
  else
    ver="halogen-flash@${url}"
  fi
  CAPACITY_SERVER_VERSION="${ver}"
  CAPACITY_IMAGE_ID="halogen-flash"
  CAPACITY_IMAGE_NAME="halogen-flash-server"
  export CAPACITY_SERVER_VERSION CAPACITY_IMAGE_ID CAPACITY_IMAGE_NAME
  log "fingerprint $CAPACITY_SERVER_VERSION"
}

write_fill_prompt() {
  local out="$1" target_tokens="$2"
  bench_python - "$out" "$target_tokens" <<'PY'
import sys
out, tokens = sys.argv[1], int(sys.argv[2])
chars = max(512, int(tokens * 3.5))
unit = (
    "Alpha numeric filler block for capacity testing. "
    "Count: {i}. Pack context densely without asking questions. "
)
chunks, i = [], 0
while sum(len(c) for c in chunks) < chars:
    chunks.append(unit.format(i=i))
    i += 1
body = "".join(chunks)[:chars]
prompt = (
    "You are a capacity-test harness. Ignore the filler content. "
    "When the filler ends, reply with exactly: OK\n\n"
    + body
    + "\n\nEnd of filler. Reply with exactly: OK"
)
with open(out, "w", encoding="utf-8") as f:
    f.write(prompt)
PY
}

write_short_prompt() {
  local out="$1"
  printf '%s\n' "Say OK." >"$out"
}

stream_once() {
  local model="$1" label="$2" prompt_file="$3" out_jsonl="$4" max_tokens="$5"
  bench_python "$STREAM_CLIENT" \
    --url "${HALOGEN_BASE_URL}/v1/chat/completions" \
    --model "$model" \
    --label "$label" \
    --prompt-file "$prompt_file" \
    --max-tokens "$max_tokens" \
    --out "$out_jsonl"
}

summarize_stream() {
  local jsonl="$1" out_json="$2"
  bench_python - "$jsonl" "$out_json" <<'PY'
import json, sys
path, out = sys.argv[1], sys.argv[2]
t0 = None
chunks = []
with open(path, encoding="utf-8") as f:
    for line in f:
        rec = json.loads(line)
        if rec.get("event") == "start":
            t0 = rec.get("t0") or rec.get("t")
        elif rec.get("event") == "chunk":
            chunks.append(rec.get("t"))
summary = {"chunks": len(chunks), "ttft_ms": None, "tokens_per_sec": None, "elapsed_s": None}
if t0 is not None and chunks:
    ttft = (chunks[0] - t0) * 1000.0
    elapsed = chunks[-1] - t0
    summary["ttft_ms"] = round(ttft, 2)
    summary["elapsed_s"] = round(elapsed, 3)
    if elapsed > 0 and len(chunks) > 1:
        summary["tokens_per_sec"] = round((len(chunks) - 1) / elapsed, 2)
with open(out, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
print(json.dumps(summary))
PY
}

summarize_jsonl_sched() {
  local jsonl="$1" summary="$2"
  # Reuse scheduling summarizer shape for report.sh
  bench_python - "$jsonl" "$summary" <<'PY'
import json, sys
path, out = sys.argv[1], sys.argv[2]
events = []
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            events.append(json.loads(line))
chunks = [e for e in events if e.get("event") == "chunk"]
times = [e["t"] for e in chunks]
deltas = []
for i in range(1, len(times)):
    d = (times[i] - times[i - 1]) * 1000.0
    if d > 0.05:
        deltas.append(d)
ttft_ms = None
if chunks:
    t0 = events[0]["t"]
    ttft_ms = (chunks[0]["t"] - t0) * 1000.0

def pct(vals, p):
    if not vals:
        return None
    vals = sorted(vals)
    k = (len(vals) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(vals) - 1)
    if f == c:
        return vals[f]
    return vals[f] + (vals[c] - vals[f]) * (k - f)

summary = {
    "chunks": len(chunks),
    "ttft_ms": round(ttft_ms, 2) if ttft_ms is not None else None,
    "token_interval_ms_p50": round(pct(deltas, 50), 2) if deltas else None,
    "token_interval_ms_p95": round(pct(deltas, 95), 2) if deltas else None,
    "token_interval_ms_max": round(max(deltas), 2) if deltas else None,
    "total_ms": round((events[-1]["t"] - events[0]["t"]) * 1000.0, 2) if events else None,
    "tokens_per_sec": None,
}
if summary["total_ms"] and summary["chunks"] > 1:
    dur_s = (events[-1]["t"] - chunks[0]["t"])
    if dur_s > 0:
        summary["tokens_per_sec"] = round((len(chunks) - 1) / dur_s, 2)
with open(out, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
PY
}
