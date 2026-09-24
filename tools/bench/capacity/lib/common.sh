#!/usr/bin/env bash
# Shared helpers for capacity benches (KV×ctx + dual).
# Stickys stay config-untouched; GPU may be freed by stopping them for clean curves.
set -euo pipefail

CAPACITY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$CAPACITY_ROOT/../../.." && pwd)"

# shellcheck source=../../lib/paths.sh
source "$PROJECT_ROOT/tools/bench/lib/paths.sh"
# shellcheck source=../../lib/python.sh
source "$PROJECT_ROOT/tools/bench/lib/python.sh"
# shellcheck source=../../lib/host_mem.sh
source "$PROJECT_ROOT/tools/bench/lib/host_mem.sh"
# shellcheck source=../../lib/compose_overlay.sh
source "$PROJECT_ROOT/tools/bench/lib/compose_overlay.sh"
# shellcheck source=../../lib/engine.sh
source "$PROJECT_ROOT/tools/bench/lib/engine.sh"
# shellcheck source=ini.sh
source "$CAPACITY_ROOT/lib/ini.sh"
# shellcheck source=sync_ini.sh
source "$CAPACITY_ROOT/lib/sync_ini.sh"

CAPACITY_OUT="${CAPACITY_OUT:-$PROJECT_ROOT/output/bench/capacity}"
# CAPACITY_INI_* / VK_COMPOSE / BENCH_COMPOSE come from paths.sh (engines/llama-cpp/)
CAPACITY_URL_A="${CAPACITY_URL_A:-http://localhost:11601}"
CAPACITY_URL_B="${CAPACITY_URL_B:-http://localhost:11602}"
# Empty → all models in models-bench.ini (after auto-sync)
# CAPACITY_MODELS=A,B,C (preferred) or CAPACITY_MODEL=A (legacy single / also accepts commas)
CAPACITY_MODEL="${CAPACITY_MODEL:-}"
CAPACITY_MODELS="${CAPACITY_MODELS:-}"
CAPACITY_NO_VL="${CAPACITY_NO_VL:-0}"
CAPACITY_BACKEND="${CAPACITY_BACKEND:-vulkan}"
CAPACITY_KV_LIST="${CAPACITY_KV_LIST:-q8_0,q5_0,q4_0}"
CAPACITY_C_LIST="${CAPACITY_C_LIST:-32768,65536,131072,196608,262144}"
# Fallback if help probe fails (matches current llama.cpp --cache-type-k)
CAPACITY_KV_FALLBACK_ALLOWED="${CAPACITY_KV_FALLBACK_ALLOWED:-f32,f16,bf16,q8_0,q4_0,q4_1,iq4_nl,q5_0,q5_1}"
CAPACITY_KV_ALLOWED="${CAPACITY_KV_ALLOWED:-}"
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
peak = {
    "gtt_used_mb": None,
    "vram_used_mb": None,
    "mem_avail_mb_min": None,
    "power_w_peak": None,
    "power_w_avg": None,
    "power_source": None,
    "temp_c_peak": None,
}
powers = []
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
            def fnum(k):
                v = (row.get(k) or "").strip()
                if not v:
                    return None
                try:
                    return float(v)
                except ValueError:
                    return None
            g, v, m = num("gtt_used_mb"), num("vram_used_mb"), num("mem_avail_mb")
            if g is not None and (peak["gtt_used_mb"] is None or g > peak["gtt_used_mb"]):
                peak["gtt_used_mb"] = g
            if v is not None and (peak["vram_used_mb"] is None or v > peak["vram_used_mb"]):
                peak["vram_used_mb"] = v
            if m is not None and (peak["mem_avail_mb_min"] is None or m < peak["mem_avail_mb_min"]):
                peak["mem_avail_mb_min"] = m
            w = fnum("power_w")
            if w is not None:
                powers.append(w)
                if peak["power_w_peak"] is None or w > peak["power_w_peak"]:
                    peak["power_w_peak"] = round(w, 2)
            src = (row.get("power_source") or "").strip()
            if src:
                peak["power_source"] = src
            t = fnum("temp_c")
            if t is not None and (peak["temp_c_peak"] is None or t > peak["temp_c_peak"]):
                peak["temp_c_peak"] = round(t, 2)
except FileNotFoundError:
    pass
if powers:
    peak["power_w_avg"] = round(sum(powers) / len(powers), 2)
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
  local -a extra=()
  if [[ "${CAPACITY_NOCB:-0}" == "1" ]]; then
    overlay="$(bench_write_nocb_overlay llama-bench-a 900)"
    overlay_b="$(bench_write_nocb_overlay llama-bench-b 900)"
    extra+=(-f "$overlay" -f "$overlay_b")
  fi
  local rc=0
  # Bench routers live in compose.yaml (profile bench). Extra -f only if BENCH_COMPOSE differs.
  if [[ "$BENCH_COMPOSE" == "$VK_COMPOSE" ]] \
    || [[ "$(basename "$BENCH_COMPOSE")" == "$(basename "$VK_COMPOSE")" ]]; then
    bench_docker_compose "$VK_COMPOSE" "${extra[@]}" --profile bench "$@" || rc=$?
  else
    bench_docker_compose "$VK_COMPOSE" -f "$BENCH_COMPOSE" "${extra[@]}" --profile bench "$@" || rc=$?
  fi
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
    log "stop sticky routers for clean capacity curve (configs untouched; lab untouched)"
    # shellcheck source=../../lib/lifecycle.sh
    source "$PROJECT_ROOT/tools/bench/lib/lifecycle.sh"
    bench_engine_stop_stickys llama.cpp
    if [[ "$CAPACITY_STOP_EMB" == "1" ]]; then
      # stop_daily already includes emb/extractor; keep explicit for clarity
      :
    fi
  fi
}

restore_after_capacity() {
  [[ "${CAPACITY_NO_RESTORE:-0}" == "1" ]] && return 0
  compose_bench stop llama-bench-a llama-bench-b 2>/dev/null || true
  log "restore sticky routers that were running before capacity"
  # Always go through bench_restore_daily so ROCm leftovers get stopped (Vulkan default).
  # shellcheck source=../../lib/routers.sh
  source "$PROJECT_ROOT/tools/bench/lib/routers.sh"
  if [[ "${CAPACITY_HAD_DAILY:-0}" == "1" ]] || [[ "${CAPACITY_HAD_CODER:-0}" == "1" ]] || [[ "$CAPACITY_KEEP_STICKY" != "1" ]]; then
    bench_restore_daily
  elif [[ "$CAPACITY_STOP_EMB" == "1" ]]; then
    bench_restore_daily
  fi
}

start_bench_a() {
  # shellcheck source=../../lib/lifecycle.sh
  source "$PROJECT_ROOT/tools/bench/lib/lifecycle.sh"
  local rc=0
  bench_engine_call llama.cpp start_bench 1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    compose_bench up -d llama-bench-a || die "bench-a compose up failed"
  elif [[ "$rc" -ne 0 ]]; then
    die "llama.cpp start_bench failed (rc=$rc; check overload / MemAvailable)"
  fi
  wait_for_url "$CAPACITY_URL_A" 120 || die "bench-a not reachable at $CAPACITY_URL_A"
}

start_bench_ab() {
  # shellcheck source=../../lib/lifecycle.sh
  source "$PROJECT_ROOT/tools/bench/lib/lifecycle.sh"
  local rc=0
  bench_engine_call llama.cpp start_bench 2 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    compose_bench up -d llama-bench-a llama-bench-b || die "bench a/b compose up failed"
  elif [[ "$rc" -ne 0 ]]; then
    die "llama.cpp start_bench 2 failed (rc=$rc; check overload / MemAvailable)"
  fi
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
  # llama.cpp keeps legacy 5-part keys; other engines prefix so ledgers never collide.
  printf '%s%s|%s|%s|%s|%s' "$(bench_engine_cell_key_prefix)" "$CAPACITY_BACKEND" "$mode" "$model" "$kv" "$c"
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

# Parse --cache-type-k allowed values from llama-server -h (inside image).
probe_kv_cache_types() {
  local help="" raw=""
  CAPACITY_IMAGE_NAME="${CAPACITY_IMAGE_NAME:-llama-cpp-vulkan-nix}"
  if command -v docker >/dev/null 2>&1; then
    if container_running llama-bench-a; then
      help="$(docker exec llama-bench-a /bin/llama-server -h 2>&1 || true)"
    else
      help="$(docker run --rm --pull=never --entrypoint /bin/llama-server "$CAPACITY_IMAGE_NAME" -h 2>&1 || true)"
    fi
  fi
  raw="$(HELP_TEXT="$help" bench_python - <<'PY'
import os, re
text = os.environ.get("HELP_TEXT") or ""
m = re.search(
    r"(?:-ctk,\s*)?--cache-type-k(?!-draft)\b.*?allowed values:\s*([^\n(]+)",
    text,
    flags=re.I | re.S,
)
if not m:
    raise SystemExit(0)
vals = [v.strip().lower() for v in m.group(1).split(",") if v.strip()]
print(",".join(vals))
PY
)"
  if [[ -n "$raw" ]]; then
    CAPACITY_KV_ALLOWED="$raw"
  else
    CAPACITY_KV_ALLOWED="$CAPACITY_KV_FALLBACK_ALLOWED"
    log "warn: could not parse --cache-type-k from llama-server -h — using fallback: $CAPACITY_KV_ALLOWED"
  fi
  export CAPACITY_KV_ALLOWED
  log "KV cache types allowed: $CAPACITY_KV_ALLOWED"
}

# Map legacy weight-quant names → real KV types; drop unsupported.
# Requires probe_kv_cache_types (or CAPACITY_KV_ALLOWED). Updates CAPACITY_KV_LIST.
filter_kv_list_inplace() {
  local requested="${1:-$CAPACITY_KV_LIST}"
  local out
  [[ -n "${CAPACITY_KV_ALLOWED:-}" ]] || probe_kv_cache_types
  out="$(
    bench_python - "$requested" "$CAPACITY_KV_ALLOWED" <<'PY'
import sys
req, allowed_csv = sys.argv[1], sys.argv[2]
allowed = {x.strip().lower() for x in allowed_csv.split(",") if x.strip()}
# GGUF weight quants ≠ KV cache types (common matrix footgun)
aliases = {
    "q4_k": "q4_0",
    "q5_k": "q5_0",
    "q6_k": None,
    "q4": "q4_0",
    "q5": "q5_0",
    "q8": "q8_0",
}
out, seen = [], set()
for raw in req.split(","):
    t = raw.strip().lower()
    if not t:
        continue
    orig = t
    if t in aliases:
        mapped = aliases[t]
        if mapped is None:
            print(f"kv drop {orig}: weight quant, not a KV cache type (try q5_0)", file=sys.stderr)
            continue
        if mapped != t:
            print(f"kv alias {orig} → {mapped}", file=sys.stderr)
        t = mapped
    if t not in allowed:
        print(f"kv drop {t}: not in llama-server allow-list", file=sys.stderr)
        continue
    if t in seen:
        continue
    seen.add(t)
    out.append(t)
if not out:
    for prefer in ("q8_0", "q5_0", "q4_0", "f16"):
        if prefer in allowed:
            out = [prefer]
            break
    if not out and allowed:
        out = [sorted(allowed)[0]]
    print(f"kv fallback → {','.join(out)}", file=sys.stderr)
print(",".join(out))
PY
  )"
  [[ -n "$out" ]] || die "no usable KV cache types after filter (requested=$requested allowed=$CAPACITY_KV_ALLOWED)"
  CAPACITY_KV_LIST="$out"
  export CAPACITY_KV_LIST
  log "KV list: $CAPACITY_KV_LIST"
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

# --- Progress / ETA (capacity cells) ------------------------------------------
# ETA = remaining_must_run × session_wall_avg. No avg yet → ETA omitted (honest).
# Plan classifies ledger/q4 skips up front so skips do not inflate remaining work.
CAPACITY_PROG_TOTAL="${CAPACITY_PROG_TOTAL:-0}"
CAPACITY_PROG_INDEX="${CAPACITY_PROG_INDEX:-0}"
CAPACITY_PROG_TIMED_N="${CAPACITY_PROG_TIMED_N:-0}"
CAPACITY_PROG_TIMED_SUM="${CAPACITY_PROG_TIMED_SUM:-0}"
CAPACITY_PROG_SKIP_N="${CAPACITY_PROG_SKIP_N:-0}"
CAPACITY_PROG_RUN_N="${CAPACITY_PROG_RUN_N:-0}"
CAPACITY_PROG_CELL_T0="${CAPACITY_PROG_CELL_T0:-0}"
CAPACITY_PROG_FILE="${CAPACITY_PROG_FILE:-$CAPACITY_OUT/progress.json}"
CAPACITY_PROG_PLAN_FILE="${CAPACITY_PROG_PLAN_FILE:-$CAPACITY_OUT/progress.plan.jsonl}"

capacity_fmt_duration() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  if [[ "$s" -lt 60 ]]; then
    printf '%ss' "$s"
  elif [[ "$s" -lt 3600 ]]; then
    printf '%dm%02ds' "$((s / 60))" "$((s % 60))"
  else
    printf '%dh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# Build skip/run plan for all cells. Args: mode models_csv kv_csv c_csv [q4_min_c]
# q4_min_c=0 disables q4-family min-c skips (dual).
capacity_progress_build_plan() {
  local mode="${1:?}" models_csv="${2:?}" kv_csv="${3:?}" c_csv="${4:?}" q4_min_c="${5:-0}"
  mkdir -p "$(dirname "$CAPACITY_PROG_PLAN_FILE")"
  if [[ -z "${CAPACITY_SERVER_VERSION:-}" || -z "${CAPACITY_IMAGE_ID:-}" ]]; then
    detect_server_fingerprint
  fi
  local summary
  summary="$(bench_python - "$CAPACITY_PROG_PLAN_FILE" "$CELLS_LEDGER" "$mode" \
    "$CAPACITY_BACKEND" "$models_csv" "$kv_csv" "$c_csv" "$q4_min_c" \
    "${CAPACITY_FORCE:-0}" "${CAPACITY_SKIP_EXISTING:-1}" "${CAPACITY_RETRY_FAILED:-0}" \
    "${CAPACITY_SERVER_VERSION:-}" "${CAPACITY_IMAGE_ID:-}" <<'PY'
import json, os, sys

(
    plan_path, ledger_path, mode, backend, models_csv, kv_csv, c_csv, q4_min_c,
    force, skip_existing, retry_failed, cur_ver, cur_img,
) = sys.argv[1:14]
q4_min_c = int(q4_min_c or 0)
force = force == "1"
skip_existing = skip_existing == "1"
retry_failed = retry_failed == "1"
models = [m.strip() for m in models_csv.split(",") if m.strip()]
kvs = [k.strip() for k in kv_csv.split(",") if k.strip()]
cs = [c.strip() for c in c_csv.split(",") if c.strip()]
q4_family = {"q4_0", "q4_1", "iq4_nl"}

latest = {}
if os.path.isfile(ledger_path):
    with open(ledger_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            key = row.get("key")
            if key:
                latest[key] = row

def will_skip_ledger(key: str) -> bool:
    if force or not skip_existing:
        return False
    best = latest.get(key)
    if best is None:
        return False
    old_ver = (best.get("server_version") or "").strip()
    old_img = (best.get("image_id") or "").strip()
    if cur_ver and cur_ver != "unknown" and (not old_ver or old_ver != cur_ver):
        return False
    if cur_img and cur_img != "unknown" and (not old_img or old_img != cur_img):
        return False
    if bool(best.get("ok")):
        return True
    return retry_failed != True  # failed + no retry → skip

os.makedirs(os.path.dirname(plan_path) or ".", exist_ok=True)
total = 0
must_run = 0
with open(plan_path, "w", encoding="utf-8") as out:
    for model in models:
        for kv in kvs:
            for c in cs:
                key = f"{backend}|{mode}|{model}|{kv}|{c}"
                reason = ""
                kind = "run"
                try:
                    c_int = int(c)
                except ValueError:
                    c_int = 0
                if q4_min_c > 0 and kv in q4_family and c_int < q4_min_c:
                    kind = "skip"
                    reason = "q4_min_c"
                elif will_skip_ledger(key):
                    kind = "skip"
                    reason = "ledger"
                if kind == "run":
                    must_run += 1
                total += 1
                out.write(json.dumps({"key": key, "kind": kind, "reason": reason}) + "\n")
print(f"{total} {must_run}")
PY
)"
  CAPACITY_PROG_TOTAL="${summary%% *}"
  CAPACITY_PROG_MUST_RUN_TOTAL="${summary##* }"
  export CAPACITY_PROG_TOTAL CAPACITY_PROG_MUST_RUN_TOTAL CAPACITY_PROG_PLAN_FILE
}

# Count planned must-run cells from 0-based start index (inclusive) to end.
# begin → start=INDEX-1 (include current); end → start=INDEX (exclude current).
capacity_progress_remaining_run() {
  local start0="${1:-}"
  if [[ -z "$start0" ]]; then
    if [[ "${CAPACITY_PROG_INDEX:-0}" -lt 1 ]]; then
      start0=0
    else
      start0=$((CAPACITY_PROG_INDEX - 1))
    fi
  fi
  bench_python - "$CAPACITY_PROG_PLAN_FILE" "$start0" <<'PY'
import json, os, sys
path, start = sys.argv[1], int(sys.argv[2])
n = 0
if not os.path.isfile(path):
    print(0)
    raise SystemExit(0)
with open(path, encoding="utf-8") as f:
    for i, line in enumerate(f):
        if i < start:
            continue
        line = line.strip()
        if not line:
            continue
        try:
            if json.loads(line).get("kind") == "run":
                n += 1
        except json.JSONDecodeError:
            pass
print(n)
PY
}

capacity_progress_init() {
  CAPACITY_PROG_INDEX=0
  CAPACITY_PROG_TIMED_N=0
  CAPACITY_PROG_TIMED_SUM=0
  CAPACITY_PROG_SKIP_N=0
  CAPACITY_PROG_RUN_N=0
  CAPACITY_PROG_ETA=""
  export CAPACITY_PROG_INDEX CAPACITY_PROG_TIMED_N CAPACITY_PROG_TIMED_SUM
  export CAPACITY_PROG_SKIP_N CAPACITY_PROG_RUN_N CAPACITY_PROG_ETA
  mkdir -p "$(dirname "$CAPACITY_PROG_FILE")"
  local must="${CAPACITY_PROG_MUST_RUN_TOTAL:-?}"
  log "progress plan: ${CAPACITY_PROG_TOTAL} cells (${must} must-run, rest skip)"
  capacity_progress_write ""
}

# $1=detail  $2=optional remaining_run start (0-based inclusive)
capacity_progress_write() {
  local detail="${1:-}"
  local rem_start="${2:-}"
  local pct=0 remaining_run=0 avg=0
  local eta_s="" eta_h=""
  if [[ "${CAPACITY_PROG_TOTAL:-0}" -gt 0 ]]; then
    pct=$((CAPACITY_PROG_INDEX * 100 / CAPACITY_PROG_TOTAL))
  fi
  if [[ -n "$rem_start" ]]; then
    remaining_run="$(capacity_progress_remaining_run "$rem_start")"
  else
    remaining_run="$(capacity_progress_remaining_run)"
  fi
  [[ "$remaining_run" =~ ^[0-9]+$ ]] || remaining_run=0

  # Only session wall-clock of real runs — never invent ETA without samples.
  if [[ "${CAPACITY_PROG_TIMED_N:-0}" -gt 0 ]]; then
    avg=$((CAPACITY_PROG_TIMED_SUM / CAPACITY_PROG_TIMED_N))
  fi
  if [[ "$avg" -gt 0 ]]; then
    eta_s=$((remaining_run * avg))
    eta_h="$(capacity_fmt_duration "$eta_s")"
  fi

  CAPACITY_PROG_REMAINING_RUN="$remaining_run"
  CAPACITY_PROG_PCT="$pct"
  CAPACITY_PROG_ETA="${eta_h}"
  CAPACITY_PROG_DETAIL="$detail"
  export CAPACITY_PROG_REMAINING_RUN CAPACITY_PROG_PCT CAPACITY_PROG_ETA CAPACITY_PROG_DETAIL

  bench_python - "$CAPACITY_PROG_FILE" "$CAPACITY_PROG_INDEX" "$CAPACITY_PROG_TOTAL" "$pct" \
    "${eta_s}" "${eta_h}" "$avg" "$detail" "$remaining_run" \
    "${CAPACITY_PROG_SKIP_N:-0}" "${CAPACITY_PROG_RUN_N:-0}" \
    "${CAPACITY_PROG_TIMED_N:-0}" "${CAPACITY_PROG_MUST_RUN_TOTAL:-0}" <<'PY'
import json, os, sys, time
(
    path, idx, total, pct, eta_s, eta_h, avg, detail, remaining_run,
    skip_n, run_n, timed_n, must_run_total,
) = sys.argv[1:14]
eta_val = eta_h if eta_h else None
eta_s_val = int(eta_s) if str(eta_s).isdigit() else None
avg_val = int(avg) if str(avg).isdigit() and int(avg) > 0 else None
data = {
    "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "index": int(idx),
    "total": int(total),
    "pct": int(pct),
    "remaining_run": int(remaining_run) if str(remaining_run).isdigit() else 0,
    "must_run_total": int(must_run_total) if str(must_run_total).isdigit() else None,
    "skipped": int(skip_n) if str(skip_n).isdigit() else 0,
    "ran": int(run_n) if str(run_n).isdigit() else 0,
    "timed_n": int(timed_n) if str(timed_n).isdigit() else 0,
    "eta_s": eta_s_val,
    "eta": eta_val,
    "avg_cell_s": avg_val,
    "detail": detail,
}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

capacity_progress_begin() {
  local detail="${1:-}"
  CAPACITY_PROG_INDEX=$((CAPACITY_PROG_INDEX + 1))
  CAPACITY_PROG_CELL_T0="$(date +%s)"
  export CAPACITY_PROG_INDEX CAPACITY_PROG_CELL_T0
  capacity_progress_write "$detail"  # remaining includes current cell
  local msg="progress ${CAPACITY_PROG_INDEX}/${CAPACITY_PROG_TOTAL} (${CAPACITY_PROG_PCT}%) runs_left ${CAPACITY_PROG_REMAINING_RUN}"
  if [[ -n "${CAPACITY_PROG_ETA:-}" ]]; then
    msg+=" ETA ~${CAPACITY_PROG_ETA}"
  fi
  log "${msg} | $detail"
}

# kind=skip → no timing; kind=run → accumulate wall time for this cell
capacity_progress_end() {
  local kind="${1:-run}"
  if [[ "$kind" == "run" && "${CAPACITY_PROG_CELL_T0:-0}" -gt 0 ]]; then
    local now dt
    now="$(date +%s)"
    dt=$((now - CAPACITY_PROG_CELL_T0))
    [[ "$dt" -lt 1 ]] && dt=1
    CAPACITY_PROG_TIMED_N=$((CAPACITY_PROG_TIMED_N + 1))
    CAPACITY_PROG_TIMED_SUM=$((CAPACITY_PROG_TIMED_SUM + dt))
    CAPACITY_PROG_RUN_N=$((CAPACITY_PROG_RUN_N + 1))
    export CAPACITY_PROG_TIMED_N CAPACITY_PROG_TIMED_SUM CAPACITY_PROG_RUN_N
  else
    CAPACITY_PROG_SKIP_N=$((CAPACITY_PROG_SKIP_N + 1))
    export CAPACITY_PROG_SKIP_N
  fi
  # Exclude current cell from remaining_run (0-based start = INDEX).
  capacity_progress_write "${CAPACITY_PROG_DETAIL:-}" "${CAPACITY_PROG_INDEX}"
}

# Dual stop-on-fail: fast-forward remaining same model+kv cells as skip (ETA + %).
capacity_progress_skip_rest_of_ladder() {
  local model="${1:?}" kv="${2:?}"
  local mode="${3:-dual}"
  local prefix="$(bench_engine_cell_key_prefix)${CAPACITY_BACKEND}|${mode}|${model}|${kv}|"
  local key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    capacity_progress_begin "$key"
    log "skip $key (ladder stop)"
    capacity_progress_end skip
  done < <(bench_python - "$CAPACITY_PROG_PLAN_FILE" "$CAPACITY_PROG_INDEX" "$prefix" <<'PY'
import json, os, sys
path, idx, prefix = sys.argv[1], int(sys.argv[2]), sys.argv[3]
if not os.path.isfile(path):
    raise SystemExit(0)
rows = []
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
changed = False
keys = []
for i in range(idx, len(rows)):
    key = rows[i].get("key") or ""
    if key.startswith(prefix):
        rows[i]["kind"] = "skip"
        rows[i]["reason"] = "ladder_stop"
        keys.append(key)
        changed = True
if changed:
    with open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
for k in keys:
    print(k)
PY
)
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
    "engine": os.environ.get("BENCH_ENGINE", "llama.cpp"),
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
# shellcheck source=server.sh
source "$CAPACITY_ROOT/lib/server.sh"
