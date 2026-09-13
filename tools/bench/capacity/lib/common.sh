#!/usr/bin/env bash
# Shared helpers for capacity benches (KV×ctx + dual).
# Stickys stay config-untouched; GPU may be freed by stopping them for clean curves.
set -euo pipefail

CAPACITY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$CAPACITY_ROOT/../../.." && pwd)"

# shellcheck source=../../lib/python.sh
source "$PROJECT_ROOT/tools/bench/lib/python.sh"
# shellcheck source=../../lib/compose_overlay.sh
source "$PROJECT_ROOT/tools/bench/lib/compose_overlay.sh"
# shellcheck source=ini.sh
source "$CAPACITY_ROOT/lib/ini.sh"
# shellcheck source=sync_ini.sh
source "$CAPACITY_ROOT/lib/sync_ini.sh"

CAPACITY_OUT="${CAPACITY_OUT:-$PROJECT_ROOT/output/bench/capacity}"
CAPACITY_INI_A="${CAPACITY_INI_A:-$PROJECT_ROOT/models-bench.ini}"
CAPACITY_INI_B="${CAPACITY_INI_B:-$PROJECT_ROOT/models-bench-b.ini}"
CAPACITY_URL_A="${CAPACITY_URL_A:-http://localhost:11601}"
CAPACITY_URL_B="${CAPACITY_URL_B:-http://localhost:11602}"
# Empty → all models in models-bench.ini (after auto-sync)
CAPACITY_MODEL="${CAPACITY_MODEL:-}"
CAPACITY_BACKEND="${CAPACITY_BACKEND:-vulkan}"
CAPACITY_KV_LIST="${CAPACITY_KV_LIST:-q8_0,q6_k,q5_k,q4_k}"
CAPACITY_C_LIST="${CAPACITY_C_LIST:-32768,65536,131072,196608,262144}"
CAPACITY_FILL_RATIO="${CAPACITY_FILL_RATIO:-0.90}"
CAPACITY_MAX_TOKENS="${CAPACITY_MAX_TOKENS:-32}"
CAPACITY_SKIP_EXISTING="${CAPACITY_SKIP_EXISTING:-1}"
CAPACITY_RETRY_FAILED="${CAPACITY_RETRY_FAILED:-0}"
CAPACITY_FORCE="${CAPACITY_FORCE:-0}"
CAPACITY_KEEP_STICKY="${CAPACITY_KEEP_STICKY:-0}"
CAPACITY_STOP_EMB="${CAPACITY_STOP_EMB:-1}"
CAPACITY_AUTO_SYNC="${CAPACITY_AUTO_SYNC:-1}"
CAPACITY_SYNC_SOURCES="${CAPACITY_SYNC_SOURCES:-coder,chat}"
# Fingerprint: cells with different llama-server / image id are re-run automatically
CAPACITY_SERVER_VERSION="${CAPACITY_SERVER_VERSION:-}"
CAPACITY_IMAGE_ID="${CAPACITY_IMAGE_ID:-}"
CAPACITY_IMAGE_NAME="${CAPACITY_IMAGE_NAME:-llama-cpp-vulkan-nix}"
CAPACITY_HAD_CODER=0
CAPACITY_HAD_DAILY=0

VK_COMPOSE="${VK_COMPOSE:-$PROJECT_ROOT/compose.yaml}"
BENCH_COMPOSE="${BENCH_COMPOSE:-$PROJECT_ROOT/compose.bench.yaml}"
STREAM_CLIENT="${STREAM_CLIENT:-$PROJECT_ROOT/tools/bench/scheduling/lib/stream_client.py}"
CELLS_LEDGER="${CAPACITY_OUT}/cells.jsonl"

log() { printf '[bench capacity] %s\n' "$*"; }
die() { printf '[bench capacity] error: %s\n' "$*" >&2; exit 1; }

container_running() {
  local name="$1"
  docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true
}

mem_snapshot() {
  bench_python - <<'PY'
import json, glob, os
out = {"gtt_used_mb": None, "gtt_total_mb": None, "mem_avail_mb": None, "vram_used_mb": None}
for path in sorted(glob.glob("/sys/class/drm/card*/device")):
    gtt_t = os.path.join(path, "mem_info_gtt_total")
    if not os.path.isfile(gtt_t):
        continue
    def mb(p):
        try:
            with open(p, encoding="utf-8") as f:
                return int(int(f.read().strip()) / 1048576)
        except Exception:
            return None
    out["gtt_total_mb"] = mb(gtt_t)
    out["gtt_used_mb"] = mb(os.path.join(path, "mem_info_gtt_used"))
    out["vram_used_mb"] = mb(os.path.join(path, "mem_info_vram_used"))
    break
try:
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                out["mem_avail_mb"] = int(line.split()[1]) // 1024
                break
except Exception:
    pass
print(json.dumps(out))
PY
}

metrics_peak_from_csv() {
  local csv="$1"
  bench_python - "$csv" <<'PY'
import csv, json, sys
path = sys.argv[1]
peak = {"gtt_used_mb": None, "vram_used_mb": None, "mem_avail_mb_min": None}
try:
    with open(path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            def num(k):
                v = (row.get(k) or "").strip()
                if not v:
                    return None
                try:
                    return int(float(v))
                except ValueError:
                    return None
            g, v, m = num("gtt_used_mb"), num("vram_used_mb"), num("mem_avail_mb")
            if g is not None and (peak["gtt_used_mb"] is None or g > peak["gtt_used_mb"]):
                peak["gtt_used_mb"] = g
            if v is not None and (peak["vram_used_mb"] is None or v > peak["vram_used_mb"]):
                peak["vram_used_mb"] = v
            if m is not None and (peak["mem_avail_mb_min"] is None or m < peak["mem_avail_mb_min"]):
                peak["mem_avail_mb_min"] = m
except FileNotFoundError:
    pass
print(json.dumps(peak))
PY
}

write_fill_prompt() {
  local out="$1" target_tokens="$2"
  bench_python - "$out" "$target_tokens" <<'PY'
import sys
out, tokens = sys.argv[1], int(sys.argv[2])
chars = max(512, int(tokens * 3.5))
unit = (
    "Alpha numeric filler block for KV capacity testing. "
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

wait_for_url() {
  local url="$1" tries="${2:-120}"
  local i=0
  while [[ "$i" -lt "$tries" ]]; do
    if curl -sfS --max-time 3 "$url/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

ensure_model_on_url() {
  local base_url="$1" model="$2" label="${3:-}"
  local list status
  list="$(curl -sfS --max-time 30 "$base_url/v1/models")" || return 1
  status="$(bench_python -c "
import json,sys
data=json.loads(sys.argv[1]); mid=sys.argv[2]
for m in data.get('data') or data.get('models') or []:
    if isinstance(m,dict) and m.get('id')==mid:
        st=(m.get('status') or {}).get('value','')
        print(st or 'present')
        break
else:
    print('missing')
" "$list" "$model")"
  if [[ "$status" == "loaded" || "$status" == "present" ]]; then
    [[ "$status" == "loaded" ]] && return 0
  fi
  if [[ -n "$label" ]]; then
    log "load $label"
  else
    log "load $model"
  fi
  curl -sfS --max-time 600 -X POST "$base_url/models/load" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\"}" >/dev/null || return 1
  local i=0
  while [[ "$i" -lt 180 ]]; do
    list="$(curl -sfS --max-time 10 "$base_url/v1/models" 2>/dev/null)" || true
    status="$(bench_python -c "
import json,sys
data=json.loads(sys.argv[1] or '{}'); mid=sys.argv[2]
for m in data.get('data') or data.get('models') or []:
    if isinstance(m,dict) and m.get('id')==mid:
        st=(m.get('status') or {}).get('value','')
        print(st or '')
        break
" "$list" "$model" 2>/dev/null || true)"
    [[ "$status" == "loaded" ]] && return 0
    i=$((i + 1))
    sleep 2
  done
  return 1
}

# CAPACITY_NOCB=1 → ephemeral --no-cont-batching overlay (same helper as sched 07).
compose_bench() {
  local overlay="" overlay_b=""
  local -a files=(-f "$VK_COMPOSE" -f "$BENCH_COMPOSE")
  if [[ "${CAPACITY_NOCB:-0}" == "1" ]]; then
    overlay="$(bench_write_nocb_overlay llama-bench-a 900)"
    overlay_b="$(bench_write_nocb_overlay llama-bench-b 900)"
    files+=(-f "$overlay" -f "$overlay_b")
  fi
  local rc=0
  (cd "$PROJECT_ROOT" && docker compose "${files[@]}" --profile bench "$@") || rc=$?
  bench_rm_overlay "$overlay"
  bench_rm_overlay "$overlay_b"
  return "$rc"
}

prepare_capacity_gpu() {
  CAPACITY_HAD_DAILY=0
  CAPACITY_HAD_CODER=0
  container_running llama-router && CAPACITY_HAD_DAILY=1
  container_running llama-router-coder && CAPACITY_HAD_CODER=1
  export CAPACITY_HAD_DAILY CAPACITY_HAD_CODER

  if [[ "$CAPACITY_KEEP_STICKY" == "1" ]]; then
    log "KEEP_STICKY=1 — leaving sticky routers running"
  else
    log "stop sticky/lab routers for clean capacity curve (configs untouched)"
    (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" stop llama llama-coder llama-lab 2>/dev/null) || true
    if [[ "$CAPACITY_STOP_EMB" == "1" ]]; then
      (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" stop llama-embeddings llama-extractor 2>/dev/null) || true
    fi
  fi
}

restore_after_capacity() {
  [[ "${CAPACITY_NO_RESTORE:-0}" == "1" ]] && return 0
  compose_bench stop llama-bench-a llama-bench-b 2>/dev/null || true
  log "restore sticky routers that were running before capacity"
  if [[ "${CAPACITY_HAD_DAILY:-0}" == "1" ]] || [[ "$CAPACITY_KEEP_STICKY" != "1" ]]; then
    (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" up -d llama) || true
  fi
  if [[ "${CAPACITY_HAD_CODER:-0}" == "1" ]] || [[ "${CAPACITY_RESTORE_CODER:-0}" == "1" ]]; then
    (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" up -d llama-coder) || true
  fi
  if [[ "$CAPACITY_STOP_EMB" == "1" ]]; then
    (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" up -d llama-embeddings llama-extractor) || true
  fi
}

start_bench_a() {
  compose_bench up -d llama-bench-a
  wait_for_url "$CAPACITY_URL_A" 120 || die "bench-a not reachable at $CAPACITY_URL_A"
}

start_bench_ab() {
  compose_bench up -d llama-bench-a llama-bench-b
  wait_for_url "$CAPACITY_URL_A" 120 || die "bench-a not reachable"
  wait_for_url "$CAPACITY_URL_B" 120 || die "bench-b not reachable"
}

restart_bench_a() {
  compose_bench up -d --force-recreate llama-bench-a
  sleep 3
  wait_for_url "$CAPACITY_URL_A" 180 || die "bench-a restart failed"
}

restart_bench_ab() {
  compose_bench up -d --force-recreate llama-bench-a llama-bench-b
  sleep 3
  wait_for_url "$CAPACITY_URL_A" 180 || die "bench-a restart failed"
  wait_for_url "$CAPACITY_URL_B" 180 || die "bench-b restart failed"
}

patch_bench_section() {
  local ini="$1" model="$2" kv="$3" c="$4"
  patch_ini_section "$ini" "$model" "ctk" "$kv"
  patch_ini_section "$ini" "$model" "ctv" "$kv"
  patch_ini_section "$ini" "$model" "c" "$c"
  patch_ini_section "$ini" "$model" "np" "1"
  patch_ini_section "$ini" "$model" "fit" "off"
}

cell_key() {
  local mode="$1" model="$2" kv="$3" c="$4"
  printf '%s|%s|%s|%s|%s' "$CAPACITY_BACKEND" "$mode" "$model" "$kv" "$c"
}

# Detect llama-server version + image id. Call after bench-a is up when possible.
detect_server_fingerprint() {
  local ver="" img="" raw
  CAPACITY_IMAGE_NAME="${CAPACITY_IMAGE_NAME:-llama-cpp-vulkan-nix}"

  if command -v docker >/dev/null 2>&1; then
    img="$(docker image inspect "$CAPACITY_IMAGE_NAME" --format '{{.Id}}' 2>/dev/null || true)"
    if [[ -n "$img" ]]; then
      if container_running llama-bench-a; then
        raw="$(docker exec llama-bench-a /bin/llama-server --version 2>&1 || true)"
      else
        # --pull=never so missing image does not spam / pollute version string
        raw="$(docker run --rm --pull=never --entrypoint /bin/llama-server "$CAPACITY_IMAGE_NAME" --version 2>&1 || true)"
      fi
      ver="$(printf '%s\n' "$raw" | awk '
        BEGIN { IGNORECASE=1 }
        /unable to find image|pull access|docker:/ { next }
        NF && $0 !~ /^WARNING/ { print; exit }
      ')"
      ver="$(printf '%s' "$ver" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]*$//')"
    fi
  fi

  [[ -n "$ver" ]] || ver="unknown"
  [[ -n "$img" ]] || img="unknown"
  CAPACITY_SERVER_VERSION="$ver"
  CAPACITY_IMAGE_ID="$img"
  export CAPACITY_SERVER_VERSION CAPACITY_IMAGE_ID CAPACITY_IMAGE_NAME
  log "fingerprint server=${CAPACITY_SERVER_VERSION} image=${CAPACITY_IMAGE_ID}"
}

# Returns 0 if cell should be skipped (same key + ok + matching fingerprint).
should_skip_cell() {
  local key="$1"
  [[ "$CAPACITY_FORCE" == "1" ]] && return 1
  [[ "$CAPACITY_SKIP_EXISTING" != "1" ]] && return 1
  [[ -f "$CELLS_LEDGER" ]] || return 1
  # Ensure fingerprint exists (lazy detect if scenario forgot)
  if [[ -z "${CAPACITY_SERVER_VERSION:-}" || -z "${CAPACITY_IMAGE_ID:-}" ]]; then
    detect_server_fingerprint
  fi
  bench_python - "$CELLS_LEDGER" "$key" "$CAPACITY_RETRY_FAILED" \
    "$CAPACITY_SERVER_VERSION" "$CAPACITY_IMAGE_ID" <<'PY'
import json, sys
path, key, retry_failed, cur_ver, cur_img = sys.argv[1:6]
best = None
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("key") != key:
                continue
            best = row
except FileNotFoundError:
    pass
if best is None:
    raise SystemExit(1)  # run
ok = bool(best.get("ok"))
# Fingerprint: missing fields on old rows → treat as stale (re-run)
old_ver = (best.get("server_version") or "").strip()
old_img = (best.get("image_id") or "").strip()
stale = False
if cur_ver and cur_ver != "unknown":
    if not old_ver or old_ver != cur_ver:
        stale = True
if cur_img and cur_img != "unknown":
    if not old_img or old_img != cur_img:
        stale = True
if stale:
    raise SystemExit(1)  # re-run after llama.cpp / image change
if ok:
    raise SystemExit(0)  # skip
if retry_failed == "1":
    raise SystemExit(1)  # re-run failed
raise SystemExit(0)  # skip failed unless retry
PY
}

append_cell_ledger() {
  local json_line="$1"
  mkdir -p "$CAPACITY_OUT"
  printf '%s\n' "$json_line" >>"$CELLS_LEDGER"
}

stream_once() {
  local url="$1" model="$2" label="$3" prompt_file="$4" out_jsonl="$5" max_tokens="$6"
  bench_python "$STREAM_CLIENT" \
    --url "$url/v1/chat/completions" \
    --model "$model" \
    --label "$label" \
    --prompt-file "$prompt_file" \
    --max-tokens "$max_tokens" \
    --out "$out_jsonl"
}

summarize_stream() {
  local jsonl="$1" out_json="$2"
  bench_python - "$jsonl" "$out_json" <<'PY'
import json, sys, statistics
path, out = sys.argv[1], sys.argv[2]
t0 = None
chunks = []
err = None
with open(path, encoding="utf-8") as f:
    for line in f:
        rec = json.loads(line)
        if rec.get("event") == "start":
            t0 = rec.get("t0") or rec.get("t")
        elif rec.get("event") == "chunk":
            chunks.append(rec.get("t"))
        elif rec.get("event") == "done" and t0 is not None:
            pass
summary = {
    "chunks": len(chunks),
    "ttft_ms": None,
    "tokens_per_sec": None,
    "elapsed_s": None,
}
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

# Resolve dual context list from host RAM/GTT (or CAPACITY_DUAL_C override).
# Prints comma-separated token counts. Override examples:
#   CAPACITY_DUAL_C=131072
#   CAPACITY_DUAL_C=32768,65536,131072
#   CAPACITY_DUAL_C=auto   (default)
resolve_dual_c_list() {
  local override="${CAPACITY_DUAL_C:-auto}"
  if [[ -n "$override" && "$override" != "auto" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  local snap
  snap="$(mem_snapshot)"
  bench_python - "$snap" <<'PY'
import json, sys
snap = json.loads(sys.argv[1])
gtt = snap.get("gtt_total_mb")
ram = snap.get("mem_avail_mb")
# Prefer GTT (UMA); fall back to MemAvailable; last resort unknown → mid ladder
gtt_gib = (gtt / 1024.0) if gtt else None
ram_gib = (ram / 1024.0) if ram else None
budget = None
if gtt_gib is not None:
    budget = gtt_gib
elif ram_gib is not None:
    budget = ram_gib
# Dual ≈ two resident models → use ~55% of pool as planning budget
if budget is not None:
    budget *= 0.55

# Ladder of context sizes (tokens)
ladder = [16384, 32768, 65536, 131072, 196608, 262144]
if budget is None:
    # unknown host → conservative mid range
    chosen = [32768, 65536, 131072]
elif budget >= 80:
    chosen = [65536, 131072, 196608, 262144]
elif budget >= 48:
    chosen = [32768, 65536, 131072, 196608]
elif budget >= 28:
    chosen = [16384, 32768, 65536, 131072]
elif budget >= 16:
    chosen = [16384, 32768, 65536]
else:
    chosen = [8192, 16384, 32768]

print(",".join(str(x) for x in chosen))
# stderr hint for operators
sys.stderr.write(
    f"[bench capacity] dual c auto: budget≈{budget if budget is not None else '?'}GiB "
    f"(gtt={gtt_gib if gtt_gib is not None else '?'} ram_avail={ram_gib if ram_gib is not None else '?'}) "
    f"→ {','.join(str(x) for x in chosen)}\n"
)
PY
}

init_capacity_run() {
  local tag="$1"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  export CAPACITY_STAMP="$stamp"
  export CAPACITY_RUN_DIR="$CAPACITY_OUT/$stamp"
  mkdir -p "$CAPACITY_RUN_DIR"
  if [[ -z "${CAPACITY_SERVER_VERSION:-}" || -z "${CAPACITY_IMAGE_ID:-}" ]]; then
    detect_server_fingerprint
  fi
  bench_python - "$CAPACITY_RUN_DIR/manifest.json" "$tag" <<'PY'
import json, os, sys
out, tag = sys.argv[1], sys.argv[2]
data = {
    "stamp": os.environ.get("CAPACITY_STAMP", ""),
    "tag": tag,
    "backend": os.environ.get("CAPACITY_BACKEND", "vulkan"),
    "model": os.environ.get("CAPACITY_MODEL", ""),
    "model_list": os.environ.get("CAPACITY_MODEL_LIST", ""),
    "url_a": os.environ.get("CAPACITY_URL_A", ""),
    "url_b": os.environ.get("CAPACITY_URL_B", ""),
    "kv_list": os.environ.get("CAPACITY_KV_LIST", ""),
    "c_list": os.environ.get("CAPACITY_C_LIST", ""),
    "dual_c_list": os.environ.get("CAPACITY_DUAL_C_LIST", ""),
    "skip_existing": os.environ.get("CAPACITY_SKIP_EXISTING", "1"),
    "force": os.environ.get("CAPACITY_FORCE", "0"),
    "server_version": os.environ.get("CAPACITY_SERVER_VERSION", ""),
    "image_id": os.environ.get("CAPACITY_IMAGE_ID", ""),
    "image_name": os.environ.get("CAPACITY_IMAGE_NAME", ""),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  : >"$CAPACITY_RUN_DIR/matrix.jsonl"
  log "run dir → $CAPACITY_RUN_DIR"
}

# Metrics sampler lives under scheduling/; needs SCHED_BENCH_ROOT
SCHED_BENCH_ROOT="${SCHED_BENCH_ROOT:-$PROJECT_ROOT/tools/bench/scheduling}"
export SCHED_BENCH_ROOT
# shellcheck source=../../scheduling/lib/metrics.sh
source "$PROJECT_ROOT/tools/bench/scheduling/lib/metrics.sh"
