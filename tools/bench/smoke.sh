#!/usr/bin/env bash
# Multi-engine smoke: are the services you care about answering HTTP?
#
#   ./bench smoke
#   ./bench smoke llama,halogen,piper
#   SMOKE_ENGINES=llama,gufo,whisper ./bench smoke
#
# This is NOT "coexist capacity" (that = two llama.cpp LLM routers under KV load).
# Smoke = stack health across engines.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

PROJECT_ROOT="$ROOT"
# shellcheck source=lib/paths.sh
source "$ROOT/tools/bench/lib/paths.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./bench smoke [engine[,engine…]]

Check HTTP readiness for each engine. Default: SMOKE_ENGINES or STACK_ENGINES or llama.

Engines: llama | halogen | gufo | piper | whisper | all

Note: sched --scenario coexist_capacity / dual_llm is ONLY two llama routers
(sticky+lab) under memory load — not piper/whisper/halogen together.
EOF
}

ok() { printf '  OK   %-12s %s\n' "$1" "$2"; }
bad() { printf '  FAIL %-12s %s\n' "$1" "$2"; FAIL=1; }

FAIL=0

check_llama() {
  local u
  for u in \
    "http://127.0.0.1:11535/v1/models|llama:11535" \
    "http://127.0.0.1:11538/v1/models|llama-coder:11538"; do
    IFS='|' read -r url label <<<"$u"
    if curl -sfS --max-time 4 "$url" >/dev/null 2>&1; then ok "$label" "$url"
    else bad "$label" "$url"; fi
  done
}

check_halogen() {
  local url="http://127.0.0.1:8731/v1/models"
  if curl -sfS --max-time 4 "$url" >/dev/null 2>&1; then ok "halogen" "$url"
  else bad "halogen" "$url (set HALOGEN_MODELS + ./stack up halogen)"; fi
}

check_gufo() {
  local port="${GUFO_PUBLISH_PORT:-8080}"
  local url="http://127.0.0.1:${port}/ready"
  if curl -sfS --max-time 4 "$url" >/dev/null 2>&1 \
    || curl -sfS --max-time 4 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
    ok "gufo" "http://127.0.0.1:${port}"
  else
    bad "gufo" ":${port} (GUFO_MODELS + GUFO_MODEL + ./stack up gufo)"
  fi
}

check_piper() {
  local port="${PIPER_PUBLISH_PORT:-9001}"
  local url="http://127.0.0.1:${port}/"
  if curl -sfS --max-time 4 "$url" >/dev/null 2>&1; then ok "piper" "$url"
  else bad "piper" "$url (TTS_MODELS + ./stack up piper)"; fi
}

check_whisper() {
  local port="${WHISPER_PUBLISH_PORT:-9000}"
  local url="http://127.0.0.1:${port}/"
  if curl -sfS --max-time 4 "$url" >/dev/null 2>&1; then ok "whisper" "$url"
  else bad "whisper" "$url (STT_MODELS + ./stack up whisper)"; fi
}

run_one() {
  case "$1" in
    llama|llama.cpp) check_llama ;;
    halogen|halogen-flash) check_halogen ;;
    gufo) check_gufo ;;
    piper|tts) check_piper ;;
    whisper|stt) check_whisper ;;
    all)
      check_llama; check_halogen; check_gufo; check_piper; check_whisper
      ;;
    *) die "unknown engine: $1" ;;
  esac
}

list="${1:-}"
case "$list" in
  -h|--help|help) usage; exit 0 ;;
esac
if [[ -z "$list" ]]; then
  list="${SMOKE_ENGINES:-${STACK_ENGINES:-llama}}"
fi
list="${list// /}"

echo "=== bench smoke (multi-engine HTTP) ==="
echo "engines: $list"
echo ""

if [[ "$list" == "all" ]]; then
  run_one all
else
  IFS=',' read -r -a engs <<< "$list"
  for e in "${engs[@]}"; do
    [[ -n "$e" ]] || continue
    run_one "$e"
  done
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "Some checks failed. Start with: ./stack up $list"
  exit 1
fi
echo "All requested engines responded."
exit 0
