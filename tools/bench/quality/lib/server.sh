#!/usr/bin/env bash
# Quality benches ALWAYS use llama-bench-a (:11601) — never sticky routers.
# Stickys are stopped for a clean GPU (same policy as capacity).
#
# Source from plugins after PROJECT_ROOT is set:
#   source "$PROJECT_ROOT/tools/bench/quality/lib/server.sh"
#   quality_bench_prepare          # once
#   quality_bench_load "$MODEL"    # per model
#   # … run suite …
#   quality_bench_cleanup          # trap EXIT
set -euo pipefail

: "${PROJECT_ROOT:?PROJECT_ROOT required}"

# shellcheck source=../../capacity/lib/common.sh
source "$PROJECT_ROOT/tools/bench/capacity/lib/common.sh"

QUALITY_URL="${QUALITY_URL:-${QUALITY_BASE_URL:-http://127.0.0.1:11601}}"
# Same catalog sources as capacity: sticky coder+chat only.
# Lab (models-lab.ini) is a disk catalog — never bulk-synced into models-bench.ini.
# Missing models are copied one-by-one via quality_ensure_model_section (from lab/coder/chat).
QUALITY_SYNC_SOURCES="${QUALITY_SYNC_SOURCES:-coder,chat}"
# Set by matrix when it owns lifecycle (prepare once, load per model, cleanup once)
QUALITY_BENCH_OWNED="${QUALITY_BENCH_OWNED:-0}"
QUALITY_BENCH_READY="${QUALITY_BENCH_READY:-0}"

quality_log() { printf '[bench quality] %s\n' "$*"; }

# If MODEL is missing from models-bench.ini, copy its section from coder/chat/lab
# (lab = lookup only, not a full sync source).
quality_ensure_model_section() {
  local model="$1"
  local ini_a="${CAPACITY_INI_A:-${LLAMA_INI_DIR:-$PROJECT_ROOT/engines/llama-cpp}/models-bench.ini}"
  local ini_b="${CAPACITY_INI_B:-${LLAMA_INI_DIR:-$PROJECT_ROOT/engines/llama-cpp}/models-bench-b.ini}"
  bench_python - "$PROJECT_ROOT" "$model" "$ini_a" "$ini_b" <<'PY'
import sys
from pathlib import Path

root, model, out_a, out_b = sys.argv[1:5]
sources = [
    Path(root) / "models-lab.ini",
    Path(root) / "models-coder.ini",
    Path(root) / "models.ini",
]

def parse_sections(path: Path):
    if not path.is_file():
        return {}
    sections, cur, buf = {}, None, []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]") and not stripped.startswith(";"):
            if cur is not None:
                sections[cur] = buf
            cur = stripped[1:-1].strip()
            buf = [line]
            continue
        if cur is not None:
            buf.append(line)
    if cur is not None:
        sections[cur] = buf
    return sections

def has_section(path: Path, name: str) -> bool:
    if not path.is_file():
        return False
    needle = f"[{name}]"
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw.strip() == needle:
            return True
    return False

if has_section(Path(out_a), model):
    print(f"present\t{model}")
    raise SystemExit(0)

found = None
src_name = None
for src in sources:
    secs = parse_sections(src)
    if model in secs:
        found = secs[model]
        src_name = src.name
        break
if not found:
    # unique prefix / substring match across sources
    hits = []
    for src in sources:
        for name, body in parse_sections(src).items():
            if name == model or name.startswith(model) or model in name:
                if not model.endswith("-VL") and name.endswith("-VL"):
                    continue
                hits.append((src.name, name, body))
    if len(hits) == 1:
        src_name, model, found = hits[0][0], hits[0][1], hits[0][2]
    elif len(hits) > 1:
        preview = ", ".join(f"{s}:{n}" for s, n, _ in hits[:8])
        print(f"ambiguous\t{preview}", file=sys.stderr)
        raise SystemExit(2)
    else:
        print(f"missing\t{model}", file=sys.stderr)
        raise SystemExit(3)

block = "\n".join(found).rstrip() + "\n"
for out in (Path(out_a), Path(out_b)):
    text = out.read_text(encoding="utf-8") if out.is_file() else ""
    if not text.endswith("\n") and text:
        text += "\n"
    text += "\n" + block
    out.write_text(text, encoding="utf-8")
print(f"added\t{model}\tfrom\t{src_name}")
PY
}

quality_bench_prepare() {
  if [[ "${QUALITY_SKIP_BENCH:-0}" == "1" ]]; then
    quality_log "QUALITY_SKIP_BENCH=1 — using QUALITY_BASE_URL as-is (no bench lifecycle)"
    return 0
  fi
  if [[ "$QUALITY_BENCH_READY" == "1" ]]; then
    return 0
  fi
  local sources="${QUALITY_SYNC_SOURCES:-coder,chat}"
  export CAPACITY_SYNC_SOURCES="$sources"
  export CAPACITY_AUTO_SYNC="${CAPACITY_AUTO_SYNC:-1}"
  if [[ "${CAPACITY_AUTO_SYNC}" == "1" ]]; then
    quality_log "sync models-bench.ini from: $sources (lab = on-demand section only)"
    sync_bench_inis "$sources"
  fi
  prepare_capacity_gpu
  # Restart so llama-server re-reads models-bench.ini (start alone is a no-op if already up).
  if container_running llama-bench-a; then
    quality_log "restart bench-a to reload models-bench.ini"
    compose_bench restart llama-bench-a >/dev/null || compose_bench up -d llama-bench-a >/dev/null
  else
    start_bench_a
  fi
  wait_for_url "${CAPACITY_URL_A:-http://127.0.0.1:11601}" 120 || {
    quality_log "error: bench-a not ready"
    return 1
  }
  QUALITY_URL="http://127.0.0.1:11601"
  export QUALITY_BASE_URL="$QUALITY_URL"
  QUALITY_BENCH_READY=1
  export QUALITY_BENCH_READY
  quality_log "bench-a ready at $QUALITY_BASE_URL (stickys stopped)"
}

quality_bench_load() {
  local model="$1"
  local ensure_st
  [[ -n "$model" ]] || { quality_log "error: empty model"; return 1; }
  quality_bench_prepare

  ensure_st="$(quality_ensure_model_section "$model" 2>&1)" || {
    local rc=$?
    if [[ "$rc" -eq 3 ]]; then
      quality_log "error: model '$model' not found in models-lab.ini / models-coder.ini / models.ini"
    elif [[ "$rc" -eq 2 ]]; then
      quality_log "error: ambiguous model '$model' — use exact section name"
    else
      quality_log "error: could not ensure model section: $ensure_st"
    fi
    return 1
  }
  if [[ "$ensure_st" == added* ]]; then
    quality_log "added model to models-bench.ini ($ensure_st) — restarting bench-a"
    compose_bench restart llama-bench-a >/dev/null
    wait_for_url "${CAPACITY_URL_A:-http://127.0.0.1:11601}" 120 || {
      quality_log "error: bench-a did not come back after INI update"
      return 1
    }
  fi

  if ! ensure_model_on_url "${CAPACITY_URL_A:-http://127.0.0.1:11601}" "$model" "quality|$model"; then
    quality_log "error: failed to load $model on bench-a (is it in models-bench.ini?)"
    return 1
  fi
}

quality_bench_cleanup() {
  if [[ "${QUALITY_SKIP_BENCH:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "$QUALITY_BENCH_OWNED" == "1" ]]; then
    # Matrix owns cleanup
    return 0
  fi
  if [[ "$QUALITY_BENCH_READY" != "1" ]]; then
    return 0
  fi
  QUALITY_BENCH_READY=0
  export QUALITY_BENCH_READY
  restore_after_capacity || true
}

# Normalize URL to host without requiring /v1 yet
quality_default_base_url() {
  if [[ -n "${QUALITY_BASE_URL:-}" && "${QUALITY_SKIP_BENCH:-0}" == "1" ]]; then
    printf '%s\n' "$QUALITY_BASE_URL"
    return
  fi
  printf '%s\n' "${QUALITY_BASE_URL:-http://127.0.0.1:11601}"
}
