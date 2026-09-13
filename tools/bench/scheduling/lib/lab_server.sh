#!/usr/bin/env bash
# Restart lab router. Cont-batching OFF only when a scenario asks (mode=1).
# Default / "auto" / "0" = cont-batching ON (llama.cpp default) — no .env file.
set -euo pipefail

# shellcheck source=../../lib/compose_overlay.sh
source "$PROJECT_ROOT/tools/bench/lib/compose_overlay.sh"

restart_lab_patched() {
  # Sweeps after ini patches: always restore default cont-batching ON.
  restart_lab_server 0
}

restart_lab_server() {
  local mode="${1:-0}"
  local nocb=0
  # Explicit: 1 | nocb | off → disable cont-batching for this restart only.
  case "$mode" in
    1|nocb|off|cont_off) nocb=1 ;;
    0|on|cont_on|auto|"") nocb=0 ;;
    *) nocb=0 ;;
  esac

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
  wait_for_server
  ensure_model_loaded
}
