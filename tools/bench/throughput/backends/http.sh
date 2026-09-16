#!/usr/bin/env bash
# Throughput suite — HTTP backend (OpenAI-compatible engines).
# PP ≈ fill_tokens/TTFT; TG = decode tok/s via streaming chat completions.
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

PP_TOKENS="${HALOGEN_PP_TOKENS:-${THROUGHPUT_PP_TOKENS:-512}}"
TG_TOKENS="${HALOGEN_TG_TOKENS:-${THROUGHPUT_TG_TOKENS:-128}}"
OUT_DIR="${BENCH_OUT:-$PROJECT_ROOT/output/bench/throughput}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUT_DIR/${ENGINE}-$STAMP"
mkdir -p "$RUN_DIR" "$OUT_DIR/latest"

bench_http_require_up
bench_http_fingerprint

MODELS=()
mapfile -t MODELS < <(bench_http_resolve_models)
bench_http_log "throughput models (${#MODELS[@]}): ${MODELS[*]}"

declare -A PP_MAP TG_MAP
for model in "${MODELS[@]}"; do
  [[ -n "$model" ]] || continue
  mdir="$RUN_DIR/$model"
  mkdir -p "$mdir"
  bench_http_log "=== throughput $model ==="

  bench_http_write_fill_prompt "$mdir/pp.txt" "$PP_TOKENS"
  if bench_http_stream_once "$model" "pp" "$mdir/pp.txt" "$mdir/pp.jsonl" 8; then
    bench_http_summarize_stream "$mdir/pp.jsonl" "$mdir/pp_summary.json" >/dev/null || true
    PP_MAP["$model"]="$(bench_python - "$mdir/pp_summary.json" "$PP_TOKENS" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
fill = float(sys.argv[2])
ttft = s.get("ttft_ms")
if ttft and ttft > 0:
    print(f"{fill / (ttft / 1000.0):.2f}")
else:
    print("")
PY
)"
  else
    bench_http_log "warn: PP stream failed for $model"
    PP_MAP["$model"]=""
  fi

  bench_http_write_short_prompt "$mdir/tg.txt"
  if bench_http_stream_once "$model" "tg" "$mdir/tg.txt" "$mdir/tg.jsonl" "$TG_TOKENS"; then
    bench_http_summarize_stream "$mdir/tg.jsonl" "$mdir/tg_summary.json" >/dev/null || true
    TG_MAP["$model"]="$(bench_python - "$mdir/tg_summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
v = s.get("tokens_per_sec")
print(f"{v:.2f}" if v is not None else "")
PY
)"
  else
    bench_http_log "warn: TG stream failed for $model"
    TG_MAP["$model"]=""
  fi
  bench_http_log "  $model  PP=${PP_MAP[$model]:—}  TG=${TG_MAP[$model]:—}"
done

LABEL="$(bench_engine_label "$ENGINE")"
CMP="$OUT_DIR/latest/compare.md"
{
  echo "# llama-bench compare"
  echo
  echo "engine: $ENGINE"
  echo
  echo "$LABEL HTTP throughput ($STAMP). PP ≈ fill_tokens/TTFT (${PP_TOKENS} tok). TG = decode tok/s (${TG_TOKENS} tok)."
  echo
  echo "| model | $LABEL pp | $LABEL tg |"
  echo "| --- | ---: | ---: |"
  for model in "${MODELS[@]}"; do
    [[ -n "$model" ]] || continue
    pp="${PP_MAP[$model]:-}"
    tg="${TG_MAP[$model]:-}"
    [[ -n "$pp" ]] || pp="—"
    [[ -n "$tg" ]] || tg="—"
    echo "| $model | $pp | $tg |"
  done
} >"$CMP"

{
  printf '{\n'
  printf '  "engine": "%s",\n' "$ENGINE"
  printf '  "stamp": "%s",\n' "$STAMP"
  printf '  "suite": "http",\n'
  printf '  "scope": "run",\n'
  printf '  "base_url": "%s"\n' "$(bench_http_base_url)"
  printf '}\n'
} >"$OUT_DIR/latest/meta.json"

cp -f "$CMP" "$OUT_DIR/llama-bench-$STAMP-${ENGINE}-compare.md"
bench_http_log "throughput → $CMP"
