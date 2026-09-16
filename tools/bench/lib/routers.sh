#!/usr/bin/env bash
# Unload models / restore routers after benches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tools/bench/lib → repo root
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=python.sh
source "$SCRIPT_DIR/python.sh"

bench_router_log() { printf '[bench] %s\n' "$*"; }

bench_container_running() {
  local name="$1"
  docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true
}

# Coexist / legacy: unload models from lab :11537
bench_unload_lab() {
  local base_url="${COEXIST_CODER_URL:-http://localhost:11537}"
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

# Restore sticky stack. Default: Vulkan only — and stop any ROCm leftovers.
# Set BENCH_RESTORE_BACKEND=rocm|both only when you intentionally use ROCm.
bench_restore_daily() {
  local root="${PROJECT_ROOT:?}"
  local vk="${VK_COMPOSE:-$root/compose.yaml}"
  local rocm="${ROCM_COMPOSE:-$root/compose.rocm.yaml}"
  local backend="${BENCH_RESTORE_BACKEND:-${CAPACITY_BACKEND:-vulkan}}"

  command -v docker >/dev/null 2>&1 || return 0

  case "$backend" in
    rocm)
      bench_router_log "restore ROCm sticky chat + coder + embeddings + extractor"
      [[ -f "$rocm" ]] || { bench_router_log "missing $rocm"; return 0; }
      # Stop Vulkan stickys so they do not fight for the GPU
      (cd "$root" && docker compose -f "$vk" stop llama llama-coder llama-embeddings llama-extractor 2>/dev/null) || true
      (cd "$root" && docker compose -f "$rocm" up -d llama llama-coder llama-embeddings llama-extractor) || true
      ;;
    both|all)
      bench_router_log "restore Vulkan + ROCm sticky stacks"
      (cd "$root" && docker compose -f "$vk" up -d llama llama-coder llama-embeddings llama-extractor) || true
      if [[ -f "$rocm" ]]; then
        (cd "$root" && docker compose -f "$rocm" up -d llama llama-coder llama-embeddings llama-extractor 2>/dev/null) || true
      fi
      ;;
    *)
      # vulkan (default) — never start ROCm; stop ROCm if still running
      bench_router_log "restore Vulkan sticky chat + coder + embeddings + extractor"
      if [[ -f "$rocm" ]]; then
        bench_router_log "stop ROCm leftovers (if any)"
        (cd "$root" && docker compose -f "$rocm" stop 2>/dev/null) || true
      fi
      (cd "$root" && docker compose -f "$vk" up -d llama llama-coder llama-embeddings llama-extractor) || true
      ;;
  esac
}

bench_restore_after_throughput() {
  [[ "${BENCH_NO_RESTORE:-0}" == "1" ]] && return 0
  bench_restore_daily
}

# Coexist path only (sticky + lab). Normal sched uses sched_bench_cleanup → restore_after_capacity.
bench_restore_after_sched() {
  [[ "${SCHED_NO_RESTORE:-0}" == "1" ]] && return 0
  bench_unload_lab
  bench_restore_daily
}
