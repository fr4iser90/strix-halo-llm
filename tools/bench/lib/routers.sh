#!/usr/bin/env bash
# Unload models / restore routers after benches.
# Daily sticky restore is owned by the llama.cpp adapter (LLAMA_DAILY_SERVICES).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=paths.sh
source "$SCRIPT_DIR/paths.sh"
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

# Restore sticky stack via llama.cpp adapter (LLAMA_DAILY_SERVICES).
bench_restore_daily() {
  # Prefer adapter (handles ROCm leftovers + LLAMA_DAILY_SERVICES)
  if [[ -f "$SCRIPT_DIR/lifecycle.sh" ]]; then
    # shellcheck source=lifecycle.sh
    source "$SCRIPT_DIR/lifecycle.sh"
    if bench_engine_call llama.cpp restore_daily 2>/dev/null; then
      return 0
    fi
  fi
  # Minimal fallback if adapter missing
  local vk="${VK_COMPOSE:-$ENGINE_LLAMA_DIR/compose.yaml}"
  command -v docker >/dev/null 2>&1 || return 0
  bench_router_log "restore Vulkan sticky chat + coder (fallback)"
  bench_docker_compose "$vk" up -d llama llama-coder || true
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
