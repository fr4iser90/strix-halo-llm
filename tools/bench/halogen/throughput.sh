#!/usr/bin/env bash
# Halogen HTTP throughput: Prompt tok/s (TTFT on ~512-token fill) + Generation tok/s.
# Writes throughput/latest/compare.md + meta.json so ./bench index picks it up.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

PP_TOKENS="${HALOGEN_PP_TOKENS:-512}"
TG_TOKENS="${HALOGEN_TG_TOKENS:-128}"
OUT_DIR="${BENCH_OUT:-$PROJECT_ROOT/output/bench/throughput}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUT_DIR/halogen-$STAMP"
mkdir -p "$RUN_DIR" "$OUT_DIR/latest"

halogen_require_up
halogen_fingerprint

MODELS=()
mapfile -t MODELS < <(halogen_resolve_models)
log "throughput models (${#MODELS[@]}): ${MODELS[*]}"

declare -A PP_MAP TG_MAP
for model in "${MODELS[@]}"; do
  [[ -n "$model" ]] || continue
  mdir="$RUN_DIR/$model"
  mkdir -p "$mdir"
  log "=== throughput $model ==="

  # Prefill: large prompt, tiny decode
  write_fill_prompt "$mdir/pp.txt" "$PP_TOKENS"
  if stream_once "$model" "pp" "$mdir/pp.txt" "$mdir/pp.jsonl" 8; then
    summarize_stream "$mdir/pp.jsonl" "$mdir/pp_summary.json" >/dev/null || true
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
    log "warn: PP stream failed for $model"
    PP_MAP["$model"]=""
  fi

  # Decode: short prompt, longer generation
  write_short_prompt "$mdir/tg.txt"
  if stream_once "$model" "tg" "$mdir/tg.txt" "$mdir/tg.jsonl" "$TG_TOKENS"; then
    summarize_stream "$mdir/tg.jsonl" "$mdir/tg_summary.json" >/dev/null || true
    TG_MAP["$model"]="$(bench_python - "$mdir/tg_summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
v = s.get("tokens_per_sec")
print(f"{v:.2f}" if v is not None else "")
PY
)"
  else
    log "warn: TG stream failed for $model"
    TG_MAP["$model"]=""
  fi
  log "  $model  PP=${PP_MAP[$model]:—}  TG=${TG_MAP[$model]:—}"
done

CMP="$OUT_DIR/latest/compare.md"
{
  echo "# llama-bench compare"
  echo
  echo "engine: halogen-flash"
  echo
  echo "Halogen HTTP throughput ($STAMP). PP ≈ fill_tokens/TTFT (${PP_TOKENS} tok). TG = decode tok/s (${TG_TOKENS} tok)."
  echo
  echo "| model | Halogen pp | Halogen tg |"
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
  printf '  "engine": "halogen-flash",\n'
  printf '  "stamp": "%s",\n' "$STAMP"
  printf '  "suite": "halogen",\n'
  printf '  "scope": "run",\n'
  printf '  "base_url": "%s"\n' "$HALOGEN_BASE_URL"
  printf '}\n'
} >"$OUT_DIR/latest/meta.json"

cp -f "$CMP" "$OUT_DIR/llama-bench-$STAMP-halogen-compare.md"
log "throughput → $CMP"
