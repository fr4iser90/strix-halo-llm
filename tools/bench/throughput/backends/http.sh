#!/usr/bin/env bash
# Throughput suite — HTTP backend (OpenAI-compatible engines).
#
# Metrics (client wall-clock unless noted):
#   ttft_cold_ms / ttft_warm_ms  — time to first token (cold = 1st fill, warm = 2nd)
#   prefill_tok_s               — cold fill_tokens / TTFT (real prompt processing)
#   decode_tok_s                — post-TTFT generation tok/s
#   itl_p50_ms                  — median inter-token latency during decode
#
# Fill ladder: THROUGHPUT_PREFILL_LIST=512,4096,16384 (default).
#   THROUGHPUT_PREFILL_TOKENS=N  — single size (overrides list to one element).
# Cold vs warm: same long prompt streamed twice. Warm may hit prompt/KV cache.
# Decode runs once per model (short prompt), shared across fill rows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SUITE_DIR/../../.." && pwd)"
# shellcheck source=../../lib/http_openai.sh
source "$PROJECT_ROOT/tools/bench/lib/http_openai.sh"

export BENCH_ENGINE="${BENCH_ENGINE:-halogen-flash}"
BENCH_ENGINE="$(bench_engine_normalize "$BENCH_ENGINE")"
export BENCH_ENGINE
ENGINE="$BENCH_ENGINE"

DECODE_TOKENS="${THROUGHPUT_DECODE_TOKENS:-128}"
# Single-size shortcut wins; else list (default ladder).
if [[ -n "${THROUGHPUT_PREFILL_TOKENS:-}" ]]; then
  PREFILL_LIST_CSV="$THROUGHPUT_PREFILL_TOKENS"
else
  PREFILL_LIST_CSV="${THROUGHPUT_PREFILL_LIST:-512,4096,16384}"
fi
OUT_DIR="${BENCH_OUT:-$PROJECT_ROOT/output/bench/throughput}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUT_DIR/${ENGINE}-$STAMP"
mkdir -p "$RUN_DIR" "$OUT_DIR/latest"

bench_http_require_up
bench_http_fingerprint

MODELS=()
if ! bench_http_load_models MODELS; then
  bench_http_die "no models (set --model / MATRIX_MODELS or check /v1/models)"
fi
[[ ${#MODELS[@]} -gt 0 ]] || bench_http_die "no models (set --model / MATRIX_MODELS or check /v1/models)"
bench_http_log "throughput models (${#MODELS[@]}): ${MODELS[*]}"

PREFILL_SIZES=()
IFS=',' read -ra _pref_raw <<<"$PREFILL_LIST_CSV"
for n in "${_pref_raw[@]}"; do
  n="${n// /}"
  [[ -n "$n" ]] || continue
  [[ "$n" =~ ^[0-9]+$ ]] || bench_http_die "invalid prefill size: $n"
  (( n > 0 )) || bench_http_die "prefill size must be > 0: $n"
  PREFILL_SIZES+=("$n")
done
unset _pref_raw
[[ ${#PREFILL_SIZES[@]} -gt 0 ]] || bench_http_die "empty THROUGHPUT_PREFILL_LIST / TOKENS"
bench_http_log "prefill ladder: ${PREFILL_SIZES[*]}  decode_tokens=$DECODE_TOKENS"

_json_field() {
  # Args: summary.json key
  bench_python - "$1" "$2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
v = s.get(sys.argv[2])
if v is None or v == "":
    print("")
elif isinstance(v, float):
    print(f"{v:.2f}" if abs(v) >= 10 or v == int(v) else f"{v:.2f}")
else:
    print(v)
PY
}

# True if string is a number > 0 (rejects 0 / empty / non-numeric).
_positive() {
  local v="${1:-}"
  [[ -n "$v" ]] || return 1
  bench_python -c "import sys; v=float(sys.argv[1]); sys.exit(0 if v > 0 else 1)" "$v" 2>/dev/null
}

# Compare row key → metrics (associative arrays keyed by "model @N")
declare -A TTFT_COLD TTFT_WARM PREFILL DECODE ITL ROW_FILL
ROWS=()

for model in "${MODELS[@]}"; do
  [[ -n "$model" ]] || continue
  mdir="$RUN_DIR/$model"
  mkdir -p "$mdir"
  bench_http_log "=== throughput $model ==="

  # --- Decode once (short prompt) — shared across fill sizes ---
  decode_tok=""
  itl_tok=""
  bench_http_write_short_prompt "$mdir/decode.txt"
  if bench_http_stream_once "$model" "decode" "$mdir/decode.txt" "$mdir/decode.jsonl" "$DECODE_TOKENS"; then
    bench_http_summarize_stream "$mdir/decode.jsonl" "$mdir/decode_summary.json" >/dev/null || true
    decode_tok="$(_json_field "$mdir/decode_summary.json" decode_tok_s)"
    itl_tok="$(_json_field "$mdir/decode_summary.json" itl_ms_p50)"
    srv_d="$(_json_field "$mdir/decode_summary.json" server_decode_tok_s)"
    if _positive "$srv_d"; then
      decode_tok="$srv_d"
    fi
  else
    bench_http_log "warn: decode stream failed for $model"
  fi

  for fill in "${PREFILL_SIZES[@]}"; do
    row="${model} @${fill}"
    fdir="$mdir/fill_${fill}"
    mkdir -p "$fdir"
    ROWS+=("$row")
    ROW_FILL["$row"]="$fill"
    DECODE["$row"]="$decode_tok"
    ITL["$row"]="$itl_tok"

    bench_http_log "--- $model fill=$fill ---"
    bench_http_write_fill_prompt "$fdir/prefill.txt" "$fill"

    # Cold prefill (real prompt processing)
    if bench_http_stream_once "$model" "prefill_cold" "$fdir/prefill.txt" "$fdir/prefill_cold.jsonl" 8; then
      bench_http_summarize_stream "$fdir/prefill_cold.jsonl" "$fdir/prefill_cold_summary.json" "$fill" >/dev/null || true
      TTFT_COLD["$row"]="$(_json_field "$fdir/prefill_cold_summary.json" ttft_ms)"
      # Prefill from cold client TTFT (fill / ttft_cold)
      PREFILL["$row"]="$(_json_field "$fdir/prefill_cold_summary.json" prefill_tok_s)"
      srv="$(_json_field "$fdir/prefill_cold_summary.json" server_prompt_tok_s)"
      if _positive "$srv"; then
        PREFILL["$row"]="$srv"
      fi
    else
      bench_http_log "warn: cold PP stream failed for $row"
      TTFT_COLD["$row"]=""
      PREFILL["$row"]=""
    fi

    # Warm (cache may hit) — TTFT only; do not use for prefill_tok_s
    if bench_http_stream_once "$model" "prefill_warm" "$fdir/prefill.txt" "$fdir/prefill_warm.jsonl" 8; then
      bench_http_summarize_stream "$fdir/prefill_warm.jsonl" "$fdir/prefill_warm_summary.json" "$fill" >/dev/null || true
      TTFT_WARM["$row"]="$(_json_field "$fdir/prefill_warm_summary.json" ttft_ms)"
    else
      bench_http_log "warn: warm PP stream failed for $row"
      TTFT_WARM["$row"]=""
    fi

    # Per-row metrics JSON
    bench_python - "$fdir/metrics.json" \
      "${TTFT_COLD[$row]:-}" "${TTFT_WARM[$row]:-}" \
      "${PREFILL[$row]:-}" "${DECODE[$row]:-}" "${ITL[$row]:-}" \
      "$fill" "$DECODE_TOKENS" "$model" <<'PY'
import json, sys
path = sys.argv[1]
def num(s):
    s = (s or "").strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None
out = {
    "model": sys.argv[9],
    "ttft_cold_ms": num(sys.argv[2]),
    "ttft_warm_ms": num(sys.argv[3]),
    "prefill_tok_s": num(sys.argv[4]),
    "decode_tok_s": num(sys.argv[5]),
    "itl_p50_ms": num(sys.argv[6]),
    "prefill_tokens": float(sys.argv[7]),
    "decode_tokens": float(sys.argv[8]),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
PY

    bench_http_log "  $row  TTFT cold=${TTFT_COLD[$row]:-}ms warm=${TTFT_WARM[$row]:-}ms  prefill=${PREFILL[$row]:-} tok/s  decode=${DECODE[$row]:-} tok/s  ITL p50=${ITL[$row]:-}ms"
  done
done

LABEL="$(bench_engine_label "$ENGINE")"
ENG_DIR="$OUT_DIR/latest/by-engine/$(printf '%s' "$ENGINE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')"
mkdir -p "$ENG_DIR" "$OUT_DIR/latest"
CMP="$ENG_DIR/compare.md"
{
  echo "# Throughput compare"
  echo
  echo "engine: $ENGINE"
  echo
  echo "$LABEL HTTP throughput ($STAMP)."
  echo
  echo "Definitions:"
  echo
  echo "- **TTFT** — time to first token (ms, lower better). Cold = first request; warm = immediate repeat (cache may hit)."
  echo "- **Prefill tok/s** — cold prompt processing ≈ fill_tokens / cold_TTFT (ladder: ${PREFILL_SIZES[*]}). Higher better."
  echo "- **Decode tok/s** — generation after first token (${DECODE_TOKENS} tok, once per model). Higher better."
  echo "- **ITL p50** — median inter-token latency during decode (ms, lower better)."
  echo "- Rows are \`model @fill\` so each fill size is a separate compare line."
  echo
  echo "| model | ttft_cold_ms | ttft_warm_ms | prefill_tok_s | decode_tok_s | itl_p50_ms |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: |"
  for row in "${ROWS[@]}"; do
    [[ -n "$row" ]] || continue
    tc="${TTFT_COLD[$row]:-—}"
    tw="${TTFT_WARM[$row]:-—}"
    pf="${PREFILL[$row]:-—}"
    dc="${DECODE[$row]:-—}"
    itl="${ITL[$row]:-—}"
    [[ -n "$tc" ]] || tc="—"
    [[ -n "$tw" ]] || tw="—"
    [[ -n "$pf" ]] || pf="—"
    [[ -n "$dc" ]] || dc="—"
    [[ -n "$itl" ]] || itl="—"
    echo "| $row | $tc | $tw | $pf | $dc | $itl |"
  done
} >"$CMP"

META="$ENG_DIR/meta.json"
{
  printf '{\n'
  printf '  "engine": "%s",\n' "$ENGINE"
  printf '  "stamp": "%s",\n' "$STAMP"
  printf '  "suite": "http",\n'
  printf '  "scope": "run",\n'
  printf '  "prefill_list": [%s],\n' "$(IFS=','; echo "${PREFILL_SIZES[*]}")"
  printf '  "decode_tokens": %s,\n' "$DECODE_TOKENS"
  printf '  "metrics": ["ttft_cold_ms","ttft_warm_ms","prefill_tok_s","decode_tok_s","itl_p50_ms"],\n'
  printf '  "base_url": "%s"\n' "$(bench_http_base_url)"
  printf '}\n'
} >"$META"

cp -f "$CMP" "$OUT_DIR/llama-bench-$STAMP-${ENGINE}-compare.md"
# shellcheck source=../../lib/thr_latest.sh
source "$PROJECT_ROOT/tools/bench/lib/thr_latest.sh"
bench_thr_publish_engine_latest "$ENGINE" "$CMP" "$META"
bench_http_log "throughput → $ENG_DIR (+ merged latest)"
