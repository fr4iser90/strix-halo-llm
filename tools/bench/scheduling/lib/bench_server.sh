#!/usr/bin/env bash
# Restart llama-bench-a (:11601) for sched sweeps.
# Cont-batching OFF only when a scenario asks (mode=1).
# Lab :11537 → tools/bench/scheduling/lib/coexist.sh (restart_lab_server).
set -euo pipefail

# shellcheck source=../../lib/compose_overlay.sh
source "$PROJECT_ROOT/tools/bench/lib/compose_overlay.sh"

restart_bench_patched() {
  restart_bench_server 0
}

restart_bench_server() {
  local mode="${1:-0}"
  local nocb=0
  case "$mode" in
    1|nocb|off|cont_off) nocb=1 ;;
    0|on|cont_on|auto|"") nocb=0 ;;
    *) nocb=0 ;;
  esac

  if declare -F compose_bench >/dev/null 2>&1; then
    if [[ "$nocb" == "1" ]]; then
      log "bench-a restart cont-batching=off"
      CAPACITY_NOCB=1 compose_bench up -d --force-recreate llama-bench-a
    else
      log "bench-a restart cont-batching=on"
      CAPACITY_NOCB=0 compose_bench up -d --force-recreate llama-bench-a
    fi
    sleep 5
    wait_for_server
    ensure_model_loaded
    return 0
  fi

  local base="${VK_COMPOSE:-$PROJECT_ROOT/compose.yaml}"
  local bench="${BENCH_COMPOSE:-$PROJECT_ROOT/compose.bench.yaml}"
  local overlay=""
  local -a args=(-f "$base" -f "$bench")
  if [[ "$nocb" == "1" ]]; then
    overlay="$(bench_write_nocb_overlay llama-bench-a 900)"
    args+=(-f "$overlay")
  fi
  log "bench-a restart cont-batching=$([[ "$nocb" == "1" ]] && echo off || echo on)"
  (
    cd "$PROJECT_ROOT" || exit 1
    docker compose "${args[@]}" --profile bench up -d --force-recreate llama-bench-a
  )
  bench_rm_overlay "$overlay"
  sleep 5
  wait_for_server
  ensure_model_loaded
}
