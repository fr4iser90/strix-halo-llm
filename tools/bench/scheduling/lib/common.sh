#!/usr/bin/env bash
# Shared helpers for scheduling / rolling-prefill tests (tools/bench/scheduling).
set -euo pipefail

SCHED_BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCHED_BENCH_ROOT/../../.." && pwd)"

# shellcheck source=../../lib/paths.sh
source "$PROJECT_ROOT/tools/bench/lib/paths.sh"

SCHED_BASE_URL="${SCHED_BASE_URL:-http://127.0.0.1:11601}"
SCHED_MODEL="${SCHED_MODEL:-Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL}"
SCHED_OUT="${SCHED_OUT:-$PROJECT_ROOT/output/bench/scheduling}"
SCHED_NP="${SCHED_NP:-}"
SCHED_UB="${SCHED_UB:-}"
SCHED_B="${SCHED_B:-64}"
SCHED_UB_LIST="${SCHED_UB_LIST:-32,64,128,256}"
# Patches go to models-bench.ini (bench-a) under engines/llama-cpp/
SCHED_BENCH_INI="${SCHED_BENCH_INI:-$CAPACITY_INI_A}"

STREAM_CLIENT="${SCHED_BENCH_ROOT}/lib/stream_client.py"

# shellcheck source=../../lib/python.sh
source "$PROJECT_ROOT/tools/bench/lib/python.sh"
# shellcheck source=../../lib/engine.sh
source "$PROJECT_ROOT/tools/bench/lib/engine.sh"
# shellcheck source=server.sh
source "$SCHED_BENCH_ROOT/lib/server.sh"

# Router state (coexist)
SCHED_STOPPED_DAILY=0
SCHED_STOPPED_EMB=0
SCHED_STARTED_LAB=0

log() { printf '[bench sched] %s\n' "$*"; }
die() { printf '[bench sched] error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
  done
}

need_stream_client() {
  [[ -f "$STREAM_CLIENT" ]] || die "missing $STREAM_CLIENT"
  need_cmd curl
  bench_python -c "import sys" >/dev/null 2>&1 || die "no python3 (nix-shell -p python3 on NixOS)"
}

run_dir() {
  printf '%s\n' "${SCHED_RUN_DIR:-}"
}

scenario_dir() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "scenario_dir: name required"
  printf '%s/%s\n' "$(run_dir)" "$name"
}

fixture_path() {
  local name="$1"
  local p="$SCHED_BENCH_ROOT/fixtures/$name"
  [[ -f "$p" ]] || die "missing fixture: $p"
  printf '%s\n' "$p"
}

init_run() {
  local tag="${1:-run}"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  export SCHED_RUN_DIR="$SCHED_OUT/$stamp"
  export SCHED_STAMP="$stamp"
  mkdir -p "$SCHED_RUN_DIR"
  write_manifest "$tag"
  log "run dir → $SCHED_RUN_DIR"
}

write_manifest() {
  local tag="${1:-run}"
  local man="$SCHED_RUN_DIR/manifest.json"
  bench_python - "$man" "$tag" <<'PY'
import json, os, sys
out, tag = sys.argv[1], sys.argv[2]
data = {
    "stamp": os.environ.get("SCHED_STAMP", ""),
    "tag": tag,
    "engine": os.environ.get("BENCH_ENGINE", "llama.cpp"),
    "base_url": os.environ.get("SCHED_BASE_URL", ""),
    "model": os.environ.get("SCHED_MODEL", ""),
    "np": os.environ.get("SCHED_NP", ""),
    "ub": os.environ.get("SCHED_UB", ""),
    "b": os.environ.get("SCHED_B", ""),
    "ub_list": os.environ.get("SCHED_UB_LIST", ""),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

container_running() {
  local name="$1"
  docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true
}

# Deprecated name — use sched_bench_prepare.
prepare_bench_gpu() {
  sched_bench_prepare
}

restore_routers() {
  [[ "${SCHED_NO_RESTORE:-0}" == "1" ]] && return 0
  if [[ "${SCHED_COEXIST:-0}" == "1" ]]; then
    # shellcheck source=../../lib/routers.sh
    source "$PROJECT_ROOT/tools/bench/lib/routers.sh"
    bench_restore_after_sched
    return 0
  fi
  sched_bench_cleanup
}

wait_for_server() {
  local url="$SCHED_BASE_URL/v1/models"
  local tries="${SCHED_WAIT_TRIES:-90}"
  local i=0
  while [[ "$i" -lt "$tries" ]]; do
    if curl -sfS --max-time 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  die "bench server not reachable at $SCHED_BASE_URL"
}

ensure_model_loaded() {
  local model="$SCHED_MODEL"
  if declare -F ensure_model_on_url >/dev/null 2>&1; then
    ensure_model_on_url "$SCHED_BASE_URL" "$model" "sched|$model" \
      || die "failed to load $model on $SCHED_BASE_URL (is it in models-bench.ini?)"
    return 0
  fi
  local list
  list="$(curl -sfS "$SCHED_BASE_URL/v1/models")" || die "GET /v1/models failed"
  if printf '%s' "$list" | grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$model\""; then
    return 0
  fi
  log "loading model $model …"
  curl -sfS -X POST "$SCHED_BASE_URL/models/load" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\"}" >/dev/null \
    || die "POST /models/load failed for $model (is it in models-bench.ini?)"
  sleep 2
}

preflight() {
  need_stream_client
  wait_for_server
  ensure_model_loaded
}

stream_chat() {
  local label="$1" prompt_file="$2" out_jsonl="$3"
  local max_tokens="${4:-128}"
  bench_python "$STREAM_CLIENT" \
    --url "$SCHED_BASE_URL/v1/chat/completions" \
    --model "$SCHED_MODEL" \
    --label "$label" \
    --prompt-file "$prompt_file" \
    --max-tokens "$max_tokens" \
    --out "$out_jsonl"
}

stream_chat_bg() {
  local label="$1" prompt_file="$2" out_jsonl="$3"
  local max_tokens="${4:-4096}"
  local done_file="${out_jsonl}.done"
  rm -f "$done_file"
  (
    if stream_chat "$label" "$prompt_file" "$out_jsonl" "$max_tokens"; then
      echo 0 >"$done_file"
    else
      echo 1 >"$done_file"
    fi
  ) &
  printf '%s\n' "$!"
}

wait_stream_bg() {
  local out_jsonl="$1" _pid="${2:-}"
  local done_file="${out_jsonl}.done"
  local tries=0 max="${SCHED_STREAM_WAIT:-7200}"
  while [[ ! -f "$done_file" && "$tries" -lt "$max" ]]; do
    sleep 1
    tries=$((tries + 1))
  done
  [[ -f "$done_file" ]] || die "timeout waiting for stream: $out_jsonl"
  [[ "$(cat "$done_file")" == "0" ]] || die "stream failed: $out_jsonl"
}

# Soft variant: returns 0/1 instead of dying (for capacity matrix cells).
wait_stream_bg_soft() {
  local out_jsonl="$1" _pid="${2:-}"
  local done_file="${out_jsonl}.done"
  local tries=0 max="${SCHED_STREAM_WAIT:-7200}"
  while [[ ! -f "$done_file" && "$tries" -lt "$max" ]]; do
    sleep 1
    tries=$((tries + 1))
  done
  [[ -f "$done_file" ]] || return 1
  [[ "$(cat "$done_file")" == "0" ]] || return 1
  return 0
}


wait_pid() {
  local pid="$1"
  wait "$pid" 2>/dev/null || true
}

summarize_jsonl() {
  local jsonl="$1" summary="$2"
  local root="${PROJECT_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  fi
  bench_python "$root/tools/bench/lib/stream_summary.py" "$jsonl" "$summary"
}

write_scenario_summary() {
  local scenario="$1"
  local sdir
  sdir="$(scenario_dir "$scenario")"
  bench_python - "$sdir" <<'PY'
import json, glob, os, sys

sdir = sys.argv[1]
merged = {"scenario": os.path.basename(sdir)}
for path in sorted(glob.glob(os.path.join(sdir, "*_summary.json"))):
    key = os.path.basename(path).replace("_summary.json", "")
    with open(path, encoding="utf-8") as f:
        merged[key] = json.load(f)
metrics = os.path.join(sdir, "metrics.csv")
if os.path.isfile(metrics):
    merged["metrics_rows"] = sum(1 for _ in open(metrics, encoding="utf-8")) - 1
out = os.path.join(sdir, "summary.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PY
}
