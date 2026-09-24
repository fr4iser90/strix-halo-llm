#!/usr/bin/env bash
# Shared inference-engine identity for benches.
# All engines: llama.cpp | halogen-flash | gufo | piper | whisper
#
#   ./bench matrix --engine llama.cpp|halogen-flash|gufo
#   ./bench audio  --engine piper|whisper
#   ./bench smoke  [any]
#
# Lifecycle: tools/bench/lib/lifecycle.sh + engines/<id>.sh
# shellcheck shell=bash
: "${BENCH_ENGINE:=llama.cpp}"

bench_engine_normalize() {
  local raw="${1:-${BENCH_ENGINE:-llama.cpp}}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr ' _' '--' | sed 's/--*/-/g')"
  case "$raw" in
    ""|llama|llamacpp|llama-cpp|llama.cpp) printf '%s\n' "llama.cpp" ;;
    halogen|halogen-flash|halogenflash|flash-server|peonist-halogen)
      printf '%s\n' "halogen-flash" ;;
    gufo|gufo-runtime|gufo-org) printf '%s\n' "gufo" ;;
    piper|tts|piper-tts) printf '%s\n' "piper" ;;
    whisper|stt|whisper-cpp|whispercpp) printf '%s\n' "whisper" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

BENCH_ENGINE="$(bench_engine_normalize "${BENCH_ENGINE:-llama.cpp}")"
export BENCH_ENGINE

bench_engine_known() {
  printf '%s\n' "llama.cpp halogen-flash gufo piper whisper"
}

bench_engine_is_known() {
  local eng want
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  for want in $(bench_engine_known); do
    [[ "$eng" == "$want" ]] && return 0
  done
  return 1
}

bench_engine_label() {
  case "$(bench_engine_normalize "${1:-$BENCH_ENGINE}")" in
    llama.cpp) printf '%s\n' "llama.cpp" ;;
    halogen-flash) printf '%s\n' "Halogen Flash" ;;
    gufo) printf '%s\n' "Gufo" ;;
    piper) printf '%s\n' "Piper TTS" ;;
    whisper) printf '%s\n' "Whisper STT" ;;
    *) printf '%s\n' "$(bench_engine_normalize "${1:-$BENCH_ENGINE}")" ;;
  esac
}

# Family: llm | audio — which suite matrix uses
bench_engine_family() {
  case "$(bench_engine_normalize "${1:-$BENCH_ENGINE}")" in
    piper|whisper) printf '%s\n' "audio" ;;
    *) printf '%s\n' "llm" ;;
  esac
}

bench_engine_default_url() {
  case "$(bench_engine_normalize "${1:-$BENCH_ENGINE}")" in
    halogen-flash) printf '%s\n' "${HALOGEN_BASE_URL:-http://127.0.0.1:8731}" ;;
    gufo) printf '%s\n' "${GUFO_BASE_URL:-http://127.0.0.1:${GUFO_PUBLISH_PORT:-8080}}" ;;
    piper) printf '%s\n' "${PIPER_BASE_URL:-http://127.0.0.1:${PIPER_PUBLISH_PORT:-9001}}" ;;
    whisper) printf '%s\n' "${WHISPER_BASE_URL:-http://127.0.0.1:${WHISPER_PUBLISH_PORT:-9000}}" ;;
    *) printf '%s\n' "${QUALITY_BASE_URL:-http://127.0.0.1:11601}" ;;
  esac
}

# http = OpenAI chat LLM · audio = piper/whisper · native = llama-bench / llama-server
bench_engine_protocol() {
  case "$(bench_engine_normalize "${1:-$BENCH_ENGINE}")" in
    halogen-flash|gufo) printf '%s\n' "http" ;;
    piper|whisper) printf '%s\n' "audio" ;;
    *) printf '%s\n' "native" ;;
  esac
}

bench_suite_backend_path() {
  local suite_dir="${1:?}"
  local proto
  proto="$(bench_engine_protocol)"
  case "$proto" in
    http)
      if [[ -f "$suite_dir/backends/http.sh" ]]; then
        printf '%s\n' "$suite_dir/backends/http.sh"
        return 0
      fi
      ;;
    audio)
      if [[ -f "$suite_dir/../audio/run.sh" ]]; then
        printf '%s\n' "$suite_dir/../audio/run.sh"
        return 0
      fi
      ;;
  esac
  return 1
}

bench_engine_from_url() {
  local url="${1:-}"
  case "$url" in
    *:8731*|*:8731/*) printf '%s\n' "halogen-flash" ;;
    *:9001*|*:9001/*) printf '%s\n' "piper" ;;
    *:9000*|*:9000/*) printf '%s\n' "whisper" ;;
    *:8080*|*:8080/*) printf '%s\n' "gufo" ;;
    *) printf '%s\n' "llama.cpp" ;;
  esac
}

bench_engine_cell_key_prefix() {
  local eng
  eng="$(bench_engine_normalize "${1:-$BENCH_ENGINE}")"
  if [[ "$eng" == "llama.cpp" ]]; then
    printf ''
  else
    printf '%s|' "$eng"
  fi
}

bench_engine_apply_quality_defaults() {
  local eng
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-llama.cpp}")"
  case "$eng" in
    halogen-flash|gufo)
      export QUALITY_SKIP_BENCH="${QUALITY_SKIP_BENCH:-1}"
      if [[ -z "${QUALITY_BASE_URL:-}" || "${QUALITY_BASE_URL}" == *"11601"* ]]; then
        export QUALITY_BASE_URL="$(bench_engine_default_url "$eng")"
      fi
      ;;
    piper|whisper)
      # HumanEval N/A — audio suite instead
      export QUALITY_SKIP_BENCH=1
      ;;
  esac
}

bench_engine_resolve() {
  local cli="${1:-}"
  local profile="${2:-}"
  local env_e="${BENCH_ENGINE:-}"
  local pick="llama.cpp"
  if [[ -n "$cli" ]]; then
    pick="$cli"
  elif [[ -n "$env_e" && "$env_e" != "llama.cpp" ]]; then
    pick="$env_e"
  elif [[ -n "$profile" ]]; then
    pick="$profile"
  elif [[ -n "$env_e" ]]; then
    pick="$env_e"
  fi
  pick="$(bench_engine_normalize "$pick")"
  if ! bench_engine_is_known "$pick"; then
    printf 'error: unknown engine %s (known: %s)\n' "$pick" "$(bench_engine_known)" >&2
    return 1
  fi
  printf '%s\n' "$pick"
}
