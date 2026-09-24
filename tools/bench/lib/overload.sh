#!/usr/bin/env bash
# Overload / multi-instance guards for engine adapters.
# shellcheck shell=bash

[[ -n "${_BENCH_OVERLOAD_LOADED:-}" ]] && return 0
_BENCH_OVERLOAD_LOADED=1

_OVERLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=python.sh
source "$_OVERLOAD_DIR/python.sh" 2>/dev/null || true

# Min free MemAvailable (GiB) before starting another GPU engine instance.
: "${ENGINE_MIN_FREE_RAM_GIB:=12}"

bench_overload_log() { printf '[bench overload] %s\n' "$*"; }

# GiB MemAvailable (empty if unknown)
bench_mem_avail_gib() {
  bench_python - <<'PY' 2>/dev/null || true
try:
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                print(round(int(line.split()[1]) / (1024.0 * 1024.0), 2))
                break
except OSError:
    pass
PY
}

# List conflicting GPU LLM endpoints that are up (one per line: name url)
bench_gpu_llm_live() {
  local pairs=(
    "llama-sticky|http://127.0.0.1:11535/v1/models"
    "llama-coder|http://127.0.0.1:11538/v1/models"
    "llama-bench-a|http://127.0.0.1:11601/v1/models"
    "llama-bench-b|http://127.0.0.1:11602/v1/models"
    "halogen|http://127.0.0.1:8731/v1/models"
    "gufo|http://127.0.0.1:${GUFO_PUBLISH_PORT:-8080}/ready"
    "gufo|http://127.0.0.1:${GUFO_PUBLISH_PORT:-8080}/v1/models"
  )
  local p name url
  for p in "${pairs[@]}"; do
    IFS='|' read -r name url <<<"$p"
    if curl -sfS --max-time 2 "$url" >/dev/null 2>&1; then
      printf '%s %s\n' "$name" "$url"
    fi
  done
}

# Max concurrent GPU-heavy instances this engine may run (1 = solo only).
# Adapters may override via engine_<pref>_max_instances; else case defaults.
bench_engine_max_instances() {
  local eng pref fn
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}" 2>/dev/null || printf '%s\n' "${1:-llama.cpp}")"
  pref="$(printf '%s' "$eng" | tr '.-' '_')"
  fn="engine_${pref}_max_instances"
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn"
    return 0
  fi
  case "$eng" in
    llama.cpp) printf '%s\n' "${LLAMA_MAX_INSTANCES:-4}" ;;
    halogen-flash) printf '%s\n' "${HALOGEN_MAX_INSTANCES:-1}" ;;
    gufo) printf '%s\n' "${GUFO_MAX_INSTANCES:-1}" ;;
    piper|whisper) printf '%s\n' "1" ;;
    *) printf '%s\n' "1" ;;
  esac
}

# Whether engine is a heavy GPU LLM (compete for GTT).
bench_engine_is_gpu_llm() {
  local eng="${1:-$BENCH_ENGINE}"
  if declare -F bench_engine_normalize >/dev/null 2>&1; then
    eng="$(bench_engine_normalize "$eng")"
  fi
  case "$eng" in
    llama.cpp|halogen-flash|gufo) return 0 ;;
    *) return 1 ;;
  esac
}

# Own-family names that do not count as "foreign peer" for solo engines.
_bench_overload_is_self() {
  local eng="$1" other="$2"
  case "$eng:$other" in
    halogen-flash:halogen) return 0 ;;
    gufo:gufo) return 0 ;;
    llama.cpp:llama-*) return 0 ;;
    *) return 1 ;;
  esac
}

# Guard before starting `want` additional GPU instances of `eng`.
# Exit 0 = ok to proceed; 1 = blocked (unless ENGINE_FORCE_OVERLOAD=1).
bench_engine_guard_start() {
  local eng="${1:?}"
  local want="${2:-1}"
  local max free reason=""
  if declare -F bench_engine_normalize >/dev/null 2>&1; then
    eng="$(bench_engine_normalize "$eng")"
  fi

  if [[ "${ENGINE_FORCE_OVERLOAD:-0}" == "1" ]]; then
    bench_overload_log "ENGINE_FORCE_OVERLOAD=1 — skip peer/MemAvailable checks"
    # still enforce max_instances below
  fi

  max="$(bench_engine_max_instances "$eng")"
  if [[ "$want" -gt "$max" ]]; then
    reason="$eng allows max_instances=$max (requested $want)"
    bench_overload_log "BLOCK: $reason"
    printf '%s\n' "$reason" >&2
    return 1
  fi

  if [[ "${ENGINE_FORCE_OVERLOAD:-0}" == "1" ]]; then
    return 0
  fi

  # Solo GPU LLMs: refuse if another GPU LLM family is already live
  if bench_engine_is_gpu_llm "$eng" && [[ "$max" -eq 1 ]]; then
    local line other
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      other="${line%% *}"
      _bench_overload_is_self "$eng" "$other" && continue
      reason="$eng is solo-only; live GPU peer: $line (stop others or ENGINE_FORCE_OVERLOAD=1)"
      bench_overload_log "BLOCK: $reason"
      printf '%s\n' "$reason" >&2
      return 1
    done < <(bench_gpu_llm_live)
  fi

  free="$(bench_mem_avail_gib)"
  if [[ -n "$free" ]] && command -v bench_python >/dev/null 2>&1; then
    if bench_python -c "import sys; sys.exit(0 if float('$free') < float('${ENGINE_MIN_FREE_RAM_GIB}') else 1)" 2>/dev/null; then
      reason="MemAvailable ${free}GiB < ENGINE_MIN_FREE_RAM_GIB=${ENGINE_MIN_FREE_RAM_GIB} (ENGINE_FORCE_OVERLOAD=1 to override)"
      bench_overload_log "BLOCK: $reason"
      printf '%s\n' "$reason" >&2
      return 1
    fi
  fi

  return 0
}
