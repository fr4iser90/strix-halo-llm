#!/usr/bin/env bash
# Helpers for dual-model capacity / coexist benches.
set -euo pipefail

COEXIST_CHAT_URL="${COEXIST_CHAT_URL:-http://localhost:11535}"
COEXIST_CODER_URL="${COEXIST_CODER_URL:-http://localhost:11537}"
COEXIST_CHAT_MODEL="${COEXIST_CHAT_MODEL:-Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL}"
COEXIST_CODER_MODEL="${COEXIST_CODER_MODEL:-Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL}"
COEXIST_CHAT_INI="${COEXIST_CHAT_INI:-$PROJECT_ROOT/models.ini}"
COEXIST_CODER_INI="${COEXIST_CODER_INI:-$PROJECT_ROOT/models-lab.ini}"
COEXIST_GTT_LIMIT_PCT="${COEXIST_GTT_LIMIT_PCT:-92}"
COEXIST_MEM_FLOOR_MB="${COEXIST_MEM_FLOOR_MB:-8192}"
COEXIST_FILL_RATIO="${COEXIST_FILL_RATIO:-0.85}"

coexist_mem_snapshot() {
  bench_python - <<'PY'
import json, glob, os
out = {"gtt_used_mb": None, "gtt_total_mb": None, "mem_avail_mb": None, "vram_used_mb": None}
for path in sorted(glob.glob("/sys/class/drm/card*/device")):
    gtt_t = os.path.join(path, "mem_info_gtt_total")
    gtt_u = os.path.join(path, "mem_info_gtt_used")
    vram_u = os.path.join(path, "mem_info_vram_used")
    if not os.path.isfile(gtt_t):
        continue
    def mb(p):
        try:
            with open(p, encoding="utf-8") as f:
                return int(int(f.read().strip()) / 1048576)
        except Exception:
            return None
    out["gtt_total_mb"] = mb(gtt_t)
    out["gtt_used_mb"] = mb(gtt_u)
    out["vram_used_mb"] = mb(vram_u)
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

coexist_metrics_peak() {
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
if not path:
    print(json.dumps(peak)); raise SystemExit(0)
powers = []
try:
    with open(path, encoding="utf-8") as f:
        r = csv.DictReader(f)
        for row in r:
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
            g = num("gtt_used_mb")
            v = num("vram_used_mb")
            m = num("mem_avail_mb")
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
# ~3.5 chars/token for repetitive English filler
chars = max(512, int(tokens * 3.5))
unit = (
    "Alpha numeric filler block for KV capacity testing. "
    "Count: {i}. Pack context densely without asking questions. "
)
chunks = []
i = 0
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
  local url="$1" tries="${2:-90}"
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

model_status_on_url() {
  local base_url="$1" model="$2"
  local list
  list="$(curl -sfS --max-time 10 "$base_url/v1/models")" || { echo "unreachable"; return 0; }
  printf '%s' "$list" | bench_python -c "
import json,sys
m=sys.argv[1]
data=json.load(sys.stdin)
for x in data.get('data') or []:
    if x.get('id')==m:
        print((x.get('status') or {}).get('value') or 'unknown')
        raise SystemExit(0)
print('missing')
" "$model"
}

# Wait until preset is loaded (sticky load-on-startup / long MoE loads need minutes).
# Never POST /models/load while status is already "loading" or "sleeping" —
# sleeping means resident/idle (wakes on first request); load returns HTTP 400 "already running".
ensure_model_on_url() {
  local base_url="$1" model="$2"
  local status tries=0 max_tries="${COEXIST_LOAD_TRIES:-180}"  # ~15 min @ 5s
  status="$(model_status_on_url "$base_url" "$model")"
  # loaded = active; sleeping = resident idle — both are READY for coexist capacity.
  if [[ "$status" == "loaded" || "$status" == "sleeping" ]]; then
    return 0
  fi
  if [[ "$status" == "loading" ]]; then
    log "waiting for $model on $base_url (already loading) …"
  else
    log "loading $model on $base_url (was: $status) …"
    # Do not fail hard on 400 — race with load-on-startup; fall through to poll.
    curl -sS --max-time 30 -X POST "$base_url/models/load" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$model\"}" >/dev/null 2>&1 || true
  fi
  while [[ "$tries" -lt "$max_tries" ]]; do
    status="$(model_status_on_url "$base_url" "$model")"
    if [[ "$status" == "loaded" || "$status" == "sleeping" ]]; then
      log "loaded $model on $base_url (status=$status)"
      return 0
    fi
    if [[ "$status" == "failed" || "$status" == "error" ]]; then
      log "FAIL load $model on $base_url status=$status"
      return 1
    fi
    tries=$((tries + 1))
    sleep 5
  done
  log "FAIL load timeout $model on $base_url last=$status"
  return 1
}


stream_chat_url() {
  local base_url="$1" model="$2" label="$3" prompt_file="$4" out_jsonl="$5"
  local max_tokens="${6:-32}"
  bench_python "$STREAM_CLIENT" \
    --url "$base_url/v1/chat/completions" \
    --model "$model" \
    --label "$label" \
    --prompt-file "$prompt_file" \
    --max-tokens "$max_tokens" \
    --out "$out_jsonl"
}

stream_chat_url_bg() {
  local base_url="$1" model="$2" label="$3" prompt_file="$4" out_jsonl="$5"
  local max_tokens="${6:-32}"
  local done_file="${out_jsonl}.done"
  rm -f "$done_file"
  (
    if stream_chat_url "$base_url" "$model" "$label" "$prompt_file" "$out_jsonl" "$max_tokens"; then
      echo 0 >"$done_file"
    else
      echo 1 >"$done_file"
    fi
  ) &
  printf '%s\n' "$!"
}

prepare_coexist_gpu() {
  need_cmd docker
  log "coexist mode — sticky + lab + embeddings + extractor all up"
  # Keep embeddings/extractor running in production dual-warm; benches must not reclaim GTT by stopping them.
  (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" up -d llama llama-embeddings llama-extractor)
  (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" --profile lab up -d llama-lab)
  SCHED_STARTED_LAB=1
  sleep 3
  wait_for_url "$COEXIST_CHAT_URL" 90 || die "sticky not reachable at $COEXIST_CHAT_URL"
  wait_for_url "$COEXIST_CODER_URL" 90 || die "lab not reachable at $COEXIST_CODER_URL"
}

restart_sticky() {
  (cd "$PROJECT_ROOT" && docker compose -f "$VK_COMPOSE" up -d --force-recreate llama)
  sleep 5
  wait_for_url "$COEXIST_CHAT_URL" 90 || die "sticky restart failed"
}

# Lab router (:11537) — coexist only. Sched sweeps use restart_bench_* on :11601.
restart_lab_server() {
  local mode="${1:-0}"
  local nocb=0
  case "$mode" in
    1|nocb|off|cont_off) nocb=1 ;;
    0|on|cont_on|auto|"") nocb=0 ;;
    *) nocb=0 ;;
  esac
  # shellcheck source=../../lib/compose_overlay.sh
  source "$PROJECT_ROOT/tools/bench/lib/compose_overlay.sh"
  local base="${VK_COMPOSE:-$PROJECT_ROOT/compose.yaml}"
  local overlay=""
  local -a args=(-f "$base")
  if [[ "$nocb" == "1" ]]; then
    overlay="$(bench_write_nocb_overlay llama-lab 900)"
    args+=(-f "$overlay")
  fi
  log "lab restart cont-batching=$([[ "$nocb" == "1" ]] && echo off || echo on)"
  (
    cd "$PROJECT_ROOT" || exit 1
    docker compose "${args[@]}" --profile lab up -d --force-recreate llama-lab
  )
  bench_rm_overlay "$overlay"
  sleep 5
  wait_for_url "$COEXIST_CODER_URL" 90 || die "lab not reachable after restart"
}

coexist_over_budget() {
  local snap_json="$1"
  bench_python - "$snap_json" "$COEXIST_GTT_LIMIT_PCT" "$COEXIST_MEM_FLOOR_MB" <<'PY'
import json, sys
snap = json.loads(sys.argv[1])
limit_pct = float(sys.argv[2])
floor = int(sys.argv[3])
gtt_u = snap.get("gtt_used_mb")
gtt_t = snap.get("gtt_total_mb")
mem = snap.get("mem_avail_mb")
if gtt_u is not None and gtt_t:
    if gtt_u * 100.0 / gtt_t >= limit_pct:
        raise SystemExit(0)
if mem is not None and mem < floor:
    raise SystemExit(0)
raise SystemExit(1)
PY
}
