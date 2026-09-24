#!/usr/bin/env bash
# Throughput suite — HTTP backend (OpenAI-compatible engines).
#
# Metrics (client wall-clock unless noted):
#   ttft_cold_ms / ttft_warm_ms  — time to first token (cold = 1st fill, warm = 2nd)
#   prefill_tok_s               — warm fill_tokens / TTFT
#   decode_tok_s                — post-TTFT generation tok/s
#   itl_p50_ms                  — median inter-token latency during decode
#
# Cold vs warm: same long prompt streamed twice. Warm may hit prompt/KV cache.
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

PREFILL_TOKENS="${THROUGHPUT_PREFILL_TOKENS:-512}"
DECODE_TOKENS="${THROUGHPUT_DECODE_TOKENS:-128}"
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

declare -A TTFT_COLD TTFT_WARM PREFILL DECODE ITL
for model in "${MODELS[@]}"; do
  [[ -n "$model" ]] || continue
  mdir="$RUN_DIR/$model"
  mkdir -p "$mdir"
  bench_http_log "=== throughput $model ==="

  bench_http_write_fill_prompt "$mdir/prefill.txt" "$PREFILL_TOKENS"

  # --- Cold prefill (first request on this prompt) ---
  if bench_http_stream_once "$model" "prefill_cold" "$mdir/prefill.txt" "$mdir/prefill_cold.jsonl" 8; then
    bench_http_summarize_stream "$mdir/prefill_cold.jsonl" "$mdir/prefill_cold_summary.json" "$PREFILL_TOKENS" >/dev/null || true
    TTFT_COLD["$model"]="$(_json_field "$mdir/prefill_cold_summary.json" ttft_ms)"
  else
    bench_http_log "warn: cold PP stream failed for $model"
    TTFT_COLD["$model"]=""
  fi

  # --- Warm prefill (same prompt again; cache may hit) ---
  if bench_http_stream_once "$model" "prefill_warm" "$mdir/prefill.txt" "$mdir/prefill_warm.jsonl" 8; then
    bench_http_summarize_stream "$mdir/prefill_warm.jsonl" "$mdir/prefill_warm_summary.json" "$PREFILL_TOKENS" >/dev/null || true
    TTFT_WARM["$model"]="$(_json_field "$mdir/prefill_warm_summary.json" ttft_ms)"
    PREFILL["$model"]="$(_json_field "$mdir/prefill_warm_summary.json" prefill_tok_s)"
    # Prefer server prefill speed when the engine reports it.
    srv="$(_json_field "$mdir/prefill_warm_summary.json" server_prompt_tok_s)"
    if [[ -n "$srv" ]]; then
      PREFILL["$model"]="$srv"
    fi
  else
    bench_http_log "warn: warm PP stream failed for $model"
    TTFT_WARM["$model"]=""
    PREFILL["$model"]=""
  fi

  # --- Decode / generation (short prompt, many tokens) ---
  bench_http_write_short_prompt "$mdir/decode.txt"
  if bench_http_stream_once "$model" "decode" "$mdir/decode.txt" "$mdir/decode.jsonl" "$DECODE_TOKENS"; then
    bench_http_summarize_stream "$mdir/decode.jsonl" "$mdir/decode_summary.json" >/dev/null || true
    DECODE["$model"]="$(_json_field "$mdir/decode_summary.json" decode_tok_s)"
    ITL["$model"]="$(_json_field "$mdir/decode_summary.json" itl_ms_p50)"
    srv_d="$(_json_field "$mdir/decode_summary.json" server_decode_tok_s)"
    if [[ -n "$srv_d" ]]; then
      DECODE["$model"]="$srv_d"
    fi
  else
    bench_http_log "warn: decode stream failed for $model"
    DECODE["$model"]=""
    ITL["$model"]=""
  fi

  # Combined per-model JSON for site/index consumers
  bench_python - "$mdir/metrics.json" \
    "${TTFT_COLD[$model]:-}" "${TTFT_WARM[$model]:-}" \
    "${PREFILL[$model]:-}" "${DECODE[$model]:-}" "${ITL[$model]:-}" \
    "$PREFILL_TOKENS" "$DECODE_TOKENS" <<'PY'
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

  bench_http_log "  $model  TTFT cold=${TTFT_COLD[$model]:-}ms warm=${TTFT_WARM[$model]:-}ms  prefill=${PREFILL[$model]:-} tok/s  decode=${DECODE[$model]:-} tok/s  ITL p50=${ITL[$model]:-}ms"
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
  echo "- **Prefill tok/s** — prompt processing speed ≈ fill_tokens / warm_TTFT (${PREFILL_TOKENS} tok). Higher better."
  echo "- **Decode tok/s** — generation after first token (${DECODE_TOKENS} tok). Higher better."
  echo "- **ITL p50** — median inter-token latency during decode (ms, lower better)."
  echo
  echo "| model | ttft_cold_ms | ttft_warm_ms | prefill_tok_s | decode_tok_s | itl_p50_ms |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: |"
  for model in "${MODELS[@]}"; do
    [[ -n "$model" ]] || continue
    tc="${TTFT_COLD[$model]:-—}"
    tw="${TTFT_WARM[$model]:-—}"
    pf="${PREFILL[$model]:-—}"
    dc="${DECODE[$model]:-—}"
    itl="${ITL[$model]:-—}"
    [[ -n "$tc" ]] || tc="—"
    [[ -n "$tw" ]] || tw="—"
    [[ -n "$pf" ]] || pf="—"
    [[ -n "$dc" ]] || dc="—"
    [[ -n "$itl" ]] || itl="—"
    echo "| $model | $tc | $tw | $pf | $dc | $itl |"
  done
} >"$CMP"

META="$ENG_DIR/meta.json"
{
  printf '{\n'
  printf '  "engine": "%s",\n' "$ENGINE"
  printf '  "stamp": "%s",\n' "$STAMP"
  printf '  "suite": "http",\n'
  printf '  "scope": "run",\n'
  printf '  "prefill_tokens": %s,\n' "$PREFILL_TOKENS"
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
