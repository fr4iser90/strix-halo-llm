#!/usr/bin/env bash
# Unload all models from lab router (:11537) to free VRAM/GTT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=python.sh
source "$SCRIPT_DIR/python.sh"

bench_router_log() { printf '[bench] %s\n' "$*"; }

bench_container_running() {
  local name="$1"
  docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true
}

bench_unload_lab() {
  local base_url="${SCHED_BASE_URL:-http://localhost:11537}"
  local models_json model

  bench_container_running llama-router-lab || return 0
  command -v curl >/dev/null 2>&1 || return 0

  models_json="$(curl -sfS --max-time 5 "$base_url/v1/models" 2>/dev/null)" || {
    bench_router_log "lab unload skipped (not reachable)"
    return 0
  }

  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    bench_router_log "unload lab model: $model"
    curl -sfS --max-time 60 -X POST "$base_url/models/unload" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$model\"}" >/dev/null 2>&1 \
      || bench_router_log "warning: unload failed for $model"
  done < <(bench_python -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
for m in data.get('data') or data.get('models') or []:
    if not isinstance(m, dict):
        continue
    st = (m.get('status') or {}).get('value', '')
    if st and st != 'loaded':
        continue
    mid = m.get('id')
    if mid:
        print(mid)
" <<< "$models_json")
}

bench_restore_daily() {
  local root="${PROJECT_ROOT:?}"
  local vk="${VK_COMPOSE:-$root/compose.yaml}"
  local rocm="${ROCM_COMPOSE:-$root/compose.rocm.yaml}"

  command -v docker >/dev/null 2>&1 || return 0
  bench_router_log "start daily + embeddings + extractor"
  (cd "$root" && docker compose -f "$vk" up -d llama llama-embeddings llama-extractor) || true
  if [[ -f "$rocm" ]]; then
    (cd "$root" && docker compose -f "$rocm" up -d llama llama-embeddings llama-extractor 2>/dev/null) || true
  fi
}

bench_restore_after_throughput() {
  [[ "${BENCH_NO_RESTORE:-0}" == "1" ]] && return 0
  bench_restore_daily
}

bench_restore_after_sched() {
  [[ "${SCHED_NO_RESTORE:-0}" == "1" ]] && return 0
  bench_unload_lab
  bench_restore_daily
}
