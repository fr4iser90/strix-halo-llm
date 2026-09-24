#!/usr/bin/env bash
# Shared OpenAI-compatible HTTP helpers for suite backends (engine-agnostic).
# Used by capacity/throughput/scheduling backends/http.sh.
#
# Expects: PROJECT_ROOT, bench_python, bench_engine_* (via lifecycle/engine).
# Env:
#   BENCH_HTTP_BASE_URL — optional BYO override (else active engine base URL)
#   MATRIX_MODELS / HALOGEN_MODEL / QUALITY_MODEL / CAPACITY_MODELS — model ids
#
# shellcheck shell=bash

_BENCH_HTTP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=python.sh
source "$_BENCH_HTTP_DIR/python.sh"
# shellcheck source=engine.sh
source "$_BENCH_HTTP_DIR/engine.sh"
# shellcheck source=lifecycle.sh
source "$_BENCH_HTTP_DIR/lifecycle.sh"

: "${PROJECT_ROOT:=$(cd "$_BENCH_HTTP_DIR/../../.." && pwd)}"

STREAM_CLIENT="${STREAM_CLIENT:-$PROJECT_ROOT/tools/bench/scheduling/lib/stream_client.py}"

bench_http_log() { printf '[bench http] %s\n' "$*" >&2; }
bench_http_die() { printf '[bench http] error: %s\n' "$*" >&2; exit 1; }

# Resolve OpenAI base URL for the active engine.
# Never reuse HALOGEN_BASE_URL for gufo (or vice versa) — .env often sets halogen's port.
bench_http_base_url() {
  local eng url
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-halogen-flash}")"
  if [[ -n "${BENCH_HTTP_BASE_URL:-}" ]]; then
    printf '%s\n' "${BENCH_HTTP_BASE_URL%/}"
    return 0
  fi
  url="$(bench_engine_base_url "$eng")"
  printf '%s\n' "${url%/}"
}

bench_http_require_up() {
  local eng url
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-halogen-flash}")"
  export BENCH_ENGINE="$eng"
  bench_engine_prepare "$eng" || bench_http_die "$eng prepare failed"
  # Always bind to this engine's port (ignore stale HALOGEN_BASE_URL from .env / prior suite).
  unset BENCH_HTTP_BASE_URL
  url="$(bench_engine_base_url "$eng")"
  BENCH_HTTP_BASE_URL="${url%/}"
  export BENCH_HTTP_BASE_URL
  export QUALITY_BASE_URL="$BENCH_HTTP_BASE_URL"
  export SCHED_BASE_URL="$BENCH_HTTP_BASE_URL"
  case "$eng" in
    halogen-flash) export HALOGEN_BASE_URL="$BENCH_HTTP_BASE_URL" ;;
    gufo) export GUFO_BASE_URL="$BENCH_HTTP_BASE_URL" ;;
  esac
  # Standalone suite backends must tear down + restore peers on exit.
  # Matrix may also trap cleanup — second call is a no-op once OWNED=0.
  if [[ "${BENCH_HTTP_LIFECYCLE_TRAP:-0}" != "1" ]]; then
    export BENCH_HTTP_LIFECYCLE_TRAP=1
    # shellcheck disable=SC2064
    trap 'bench_engine_cleanup' EXIT
  fi
}

# Print model ids from /v1/models (one per line).
# NOTE: never `curl | python - <<EOF` — heredoc steals stdin from the pipe.
bench_http_list_models() {
  local url="${1:-$(bench_http_base_url)}" raw
  raw="$(curl -sfS --max-time 10 "${url%/}/v1/models")" || {
    bench_http_log "warn: GET ${url%/}/v1/models failed"
    return 1
  }
  BENCH_HTTP_MODELS_JSON="$raw" bench_python - <<'PY'
import json, os
raw = os.environ.get("BENCH_HTTP_MODELS_JSON") or ""
data = json.loads(raw) if raw.strip() else {}
for m in data.get("data") or []:
    mid = (m.get("id") or "").strip()
    if mid:
        print(mid)
PY
}

# GGUF path /models/…/Name-UD-Q4_K_XL-00001-of-00004.gguf → Name-UD-Q4_K_XL
bench_http_gufo_weight_label() {
  local p="${GUFO_MODEL:-}" base
  [[ -n "$p" ]] || return 1
  base="${p##*/}"
  base="${base%.gguf}"
  base="${base%.GGUF}"
  # multi-shard Unsloth: -00001-of-00004
  if [[ "$base" =~ ^(.*)-[0-9]{5}-of-[0-9]{5}$ ]]; then
    base="${BASH_REMATCH[1]}"
  fi
  printf '%s\n' "$base"
}

# Halogen pack dir → qwen38-flash-next-w4b (prefer *-w4b.hgn stem)
bench_http_halogen_weight_label() {
  local dir="${HALOGEN_MODELS:-}" f base
  [[ -n "$dir" && -d "$dir" ]] || return 1
  f="$(find "$dir" -maxdepth 1 -type f -name '*-w4b.hgn' 2>/dev/null | head -n1 || true)"
  if [[ -z "$f" ]]; then
    f="$(find "$dir" -maxdepth 1 -type f -name '*.hgn' ! -name '*mtp*' ! -name '*vision*' ! -name '*overlay*' 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$f" ]] || return 1
  base="${f##*/}"
  base="${base%.hgn}"
  printf '%s\n' "$base"
}

# Record label for tables/index (includes quant). API id may differ (Gufo marketing name).
bench_http_record_model_label() {
  local eng api_id="${1:-}" label=""
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-}")"
  case "$eng" in
    gufo)
      label="$(bench_http_gufo_weight_label 2>/dev/null || true)"
      ;;
    halogen-flash)
      label="$(bench_http_halogen_weight_label 2>/dev/null || true)"
      ;;
  esac
  if [[ -n "$label" ]]; then
    printf '%s\n' "$label"
  else
    printf '%s\n' "$api_id"
  fi
}

# Priority: MATRIX_MODELS / HALOGEN_MODEL / QUALITY_MODEL / CAPACITY_MODELS → else /v1/models
# For gufo/halogen: record ids = weight labels (quant in name); BENCH_HTTP_API_MODEL =
# served /v1/models id for HTTP bodies (marketing name ≠ GGUF basename).
#
# IMPORTANT: do not call via `mapfile < <(bench_http_resolve_models)` — that runs in a
# subshell and drops BENCH_HTTP_API_MODEL. Use bench_http_load_models instead.
bench_http_resolve_models() {
  local csv="${MATRIX_MODELS:-${HALOGEN_MODEL:-${QUALITY_MODEL:-${CAPACITY_MODELS:-}}}}"
  local -a out=() api_ids=()
  local eng label
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-halogen-flash}")"

  if [[ -n "$csv" ]]; then
    local IFS=',' p
    for p in $csv; do
      p="${p// /}"
      [[ -n "$p" ]] && out+=("$p")
    done
  else
    mapfile -t out < <(bench_http_list_models) || true
  fi
  # drop empties
  local -a cleaned=()
  local x
  for x in "${out[@]:-}"; do
    [[ -n "$x" ]] && cleaned+=("$x")
  done
  out=("${cleaned[@]:-}")
  if [[ ${#out[@]} -eq 0 ]]; then
    printf '[bench http] error: no models (set --model / MATRIX_MODELS or check /v1/models)\n' >&2
    return 1
  fi

  # Capture served id(s) for HTTP; replace display/record ids with weight labels.
  unset BENCH_HTTP_API_MODEL || true
  case "$eng" in
    gufo|halogen-flash)
      mapfile -t api_ids < <(bench_http_list_models 2>/dev/null || true)
      if [[ ${#api_ids[@]} -gt 0 && -n "${api_ids[0]:-}" ]]; then
        export BENCH_HTTP_API_MODEL="${api_ids[0]}"
      elif [[ -z "$csv" ]]; then
        export BENCH_HTTP_API_MODEL="${out[0]}"
      fi
      # If caller passed explicit MATRIX_MODELS that already looks like a weight id
      # (has quant), keep it; else rewrite from GUFO_MODEL / HALOGEN_MODELS.
      if [[ -z "$csv" ]] || [[ "${out[0]}" == *" "* ]] || [[ "${out[0]}" == "Qwen3.8 Flash Next" ]] \
        || [[ "${out[0]}" == halogen-qwen* ]]; then
        label="$(bench_http_record_model_label "${BENCH_HTTP_API_MODEL:-${out[0]}}")"
        if [[ -n "$label" ]]; then
          out=("$label")
        fi
      fi
      if [[ -n "${BENCH_HTTP_API_MODEL:-}" ]]; then
        bench_http_log "record model=${out[0]}  api model=${BENCH_HTTP_API_MODEL}"
      fi
      ;;
  esac

  printf '%s\n' "${out[@]}"
}

# Fill nameref array + export BENCH_HTTP_API_MODEL in the *current* shell.
# Usage: local -a MODELS=(); bench_http_load_models MODELS || die …
bench_http_load_models() {
  local __dst="${1:?bench_http_load_models needs array name}"
  local -n __models_ref="$__dst"
  local csv="${MATRIX_MODELS:-${HALOGEN_MODEL:-${QUALITY_MODEL:-${CAPACITY_MODELS:-}}}}"
  local -a out=() api_ids=()
  local eng label x
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-halogen-flash}")"

  out=()
  if [[ -n "$csv" ]]; then
    local IFS=',' p
    for p in $csv; do
      p="${p// /}"
      [[ -n "$p" ]] && out+=("$p")
    done
  else
    mapfile -t out < <(bench_http_list_models) || true
  fi
  local -a cleaned=()
  for x in "${out[@]:-}"; do
    [[ -n "$x" ]] && cleaned+=("$x")
  done
  out=("${cleaned[@]:-}")
  if [[ ${#out[@]} -eq 0 ]]; then
    printf '[bench http] error: no models (set --model / MATRIX_MODELS or check /v1/models)\n' >&2
    return 1
  fi

  unset BENCH_HTTP_API_MODEL || true
  case "$eng" in
    gufo|halogen-flash)
      mapfile -t api_ids < <(bench_http_list_models 2>/dev/null || true)
      if [[ ${#api_ids[@]} -gt 0 && -n "${api_ids[0]:-}" ]]; then
        export BENCH_HTTP_API_MODEL="${api_ids[0]}"
      elif [[ -z "$csv" ]]; then
        export BENCH_HTTP_API_MODEL="${out[0]}"
      fi
      if [[ -z "$csv" ]] || [[ "${out[0]}" == *" "* ]] || [[ "${out[0]}" == "Qwen3.8 Flash Next" ]] \
        || [[ "${out[0]}" == halogen-qwen* ]]; then
        label="$(bench_http_record_model_label "${BENCH_HTTP_API_MODEL:-${out[0]}}")"
        if [[ -n "$label" ]]; then
          out=("$label")
        fi
      fi
      if [[ -n "${BENCH_HTTP_API_MODEL:-}" ]]; then
        bench_http_log "record model=${out[0]}  api model=${BENCH_HTTP_API_MODEL}"
      fi
      ;;
  esac

  __models_ref=("${out[@]}")
  return 0
}

bench_http_fingerprint() {
  local url="${1:-$(bench_http_base_url)}" eng raw ver
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-halogen-flash}")"
  raw="$(curl -sfS --max-time 5 "${url%/}/health" 2>/dev/null || true)"
  if [[ -n "$raw" ]]; then
    ver="$(BENCH_HTTP_HEALTH_JSON="$raw" bench_python - <<'PY'
import json, os
raw = (os.environ.get("BENCH_HTTP_HEALTH_JSON") or "").strip()
try:
    data = json.loads(raw)
    if isinstance(data, dict):
        bits = []
        for k in ("version", "api_version", "engine_version", "status"):
            if data.get(k) is not None:
                bits.append(f"{k}={data.get(k)}")
        print(" ".join(bits) if bits else json.dumps(data, separators=(",", ":"))[:200])
    else:
        print(str(data)[:200])
except Exception:
    print(raw[:200].replace("\n", " "))
PY
)"
  else
    ver="${eng}@${url}"
  fi
  CAPACITY_SERVER_VERSION="${ver}"
  CAPACITY_IMAGE_ID="${eng}"
  CAPACITY_IMAGE_NAME="${eng}-server"
  export CAPACITY_SERVER_VERSION CAPACITY_IMAGE_ID CAPACITY_IMAGE_NAME
  bench_http_log "fingerprint $CAPACITY_SERVER_VERSION"
}

bench_http_write_fill_prompt() {
  local out="$1" target_tokens="$2"
  bench_python - "$out" "$target_tokens" <<'PY'
import sys
out, tokens = sys.argv[1], int(sys.argv[2])
chars = max(512, int(tokens * 3.5))
unit = (
    "Alpha numeric filler block for capacity testing. "
    "Count: {i}. Pack context densely without asking questions. "
)
chunks, i = [], 0
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

bench_http_write_short_prompt() {
  printf '%s\n' "Say OK." >"$1"
}

bench_http_stream_once() {
  local model="$1" label="$2" prompt_file="$3" out_jsonl="$4" max_tokens="$5"
  local url api_model eng
  url="$(bench_http_base_url)"
  eng="$(bench_engine_normalize "${BENCH_ENGINE:-}")"
  # Record/table id may be GGUF weight label; HTTP needs served /v1/models id.
  api_model="${BENCH_HTTP_API_MODEL:-}"
  if [[ -z "$api_model" ]]; then
    case "$eng" in
      gufo|halogen-flash)
        api_model="$(bench_http_list_models 2>/dev/null | head -n1 || true)"
        [[ -n "$api_model" ]] && export BENCH_HTTP_API_MODEL="$api_model"
        ;;
    esac
  fi
  api_model="${api_model:-$model}"
  bench_python "$STREAM_CLIENT" \
    --url "${url}/v1/chat/completions" \
    --model "$api_model" \
    --label "$label" \
    --prompt-file "$prompt_file" \
    --max-tokens "$max_tokens" \
    --out "$out_jsonl"
}

bench_http_summarize_stream() {
  # Args: jsonl out_json [fill_tokens]
  local jsonl="$1" out_json="$2" fill="${3:-}"
  local -a args=("$PROJECT_ROOT/tools/bench/lib/stream_summary.py" "$jsonl" "$out_json")
  if [[ -n "$fill" ]]; then
    args+=(--fill-tokens "$fill")
  fi
  bench_python "${args[@]}"
}

bench_http_summarize_jsonl_sched() {
  # Full summary (TTFT / decode / ITL / E2E / server timings).
  bench_http_summarize_stream "$1" "$2"
}

# --- Compat aliases (capacity/scheduling call sites) ---
log() { bench_http_log "$@"; }
die() { bench_http_die "$@"; }
write_fill_prompt() { bench_http_write_fill_prompt "$@"; }
write_short_prompt() { bench_http_write_short_prompt "$@"; }
stream_once() { bench_http_stream_once "$@"; }
summarize_stream() { bench_http_summarize_stream "$@"; }
summarize_jsonl_sched() { bench_http_summarize_jsonl_sched "$@"; }
