#!/usr/bin/env bash
# Quality benchmarks dispatcher — pluggable suites under plugins/
#
#   ./bench quality list
#   ./bench quality humaneval --model Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL
#   ./bench quality run humaneval …
#   ./bench quality compare
#
# Each plugin is: tools/bench/quality/plugins/<name>/run.sh
# Contract: see plugins/README.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tools/bench/quality → repo root
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PLUGINS="$SCRIPT_DIR/plugins"
OUT_ROOT="${QUALITY_OUT:-$ROOT/output/bench/quality}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./bench quality <command> [args]

Commands:
  list                         list installed quality plugins
  run <suite> [opts]           run a plugin (alias: ./bench quality <suite> …)
  compare                      rebuild quality/latest compare table
  help

Built-in suites (plugins/):
  humaneval    OpenAI HumanEval pass@k via local OpenAI-compatible API
               https://github.com/openai/human-eval

Common env (all plugins):
  QUALITY_BASE_URL   default http://127.0.0.1:11538  (coder sticky)
  QUALITY_MODEL      API model / INI section name
  QUALITY_OUT        output root (default output/bench/quality)

Examples:
  ./bench quality list
  ./bench quality humaneval --model Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL
  QUALITY_BASE_URL=http://127.0.0.1:11537 ./bench quality humaneval --n 1 --limit 10

Add a suite: copy plugins/_template → plugins/mybench and implement run.sh
EOF
}

list_plugins() {
  local d name
  echo "Quality plugins in $PLUGINS:"
  echo ""
  shopt -s nullglob
  for d in "$PLUGINS"/*/ ; do
    name="$(basename "$d")"
    [[ "$name" == _* ]] && continue
    if [[ -x "$d/run.sh" || -f "$d/run.sh" ]]; then
      printf '  %-16s' "$name"
      if [[ -f "$d/DESCRIPTION" ]]; then
        head -n 1 "$d/DESCRIPTION"
      else
        echo ""
      fi
    fi
  done
  shopt -u nullglob
}

run_plugin() {
  local suite="$1"; shift
  local runner="$PLUGINS/$suite/run.sh"
  [[ -f "$runner" ]] || die "unknown quality suite: $suite (try: ./bench quality list)"
  chmod +x "$runner" 2>/dev/null || true
  mkdir -p "$OUT_ROOT/$suite"
  export QUALITY_OUT="$OUT_ROOT"
  export QUALITY_SUITE="$suite"
  export PROJECT_ROOT="$ROOT"
  exec "$runner" "$@"
}

compare_quality() {
  mkdir -p "$OUT_ROOT/latest"
  # shellcheck source=../lib/python.sh
  source "$ROOT/tools/bench/lib/python.sh"
  bench_python - "$OUT_ROOT" <<'PY'
import json, os, sys, glob
from datetime import datetime, timezone

root = sys.argv[1]
rows = []
for path in sorted(glob.glob(os.path.join(root, "*", "*", "summary.json"))):
    # quality/<suite>/<stamp>/summary.json
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        continue
    parts = path.split(os.sep)
    # …/quality/suite/stamp/summary.json
    try:
        i = parts.index("quality")
        suite, stamp = parts[i + 1], parts[i + 2]
    except (ValueError, IndexError):
        suite, stamp = "?", "?"
    metrics = data.get("metrics") or {}
    rows.append({
        "suite": suite,
        "stamp": stamp,
        "model": data.get("model", "—"),
        "endpoint": data.get("base_url", "—"),
        "pass_at_1": metrics.get("pass@1", metrics.get("pass_at_1")),
        "pass_at_10": metrics.get("pass@10", metrics.get("pass_at_10")),
        "n_tasks": data.get("n_tasks"),
        "n_samples": data.get("n_samples_per_task"),
        "path": path,
    })

# latest per (suite, model)
best = {}
for r in rows:
    key = (r["suite"], r["model"])
    prev = best.get(key)
    if prev is None or r["stamp"] > prev["stamp"]:
        best[key] = r

latest = sorted(best.values(), key=lambda r: (r["suite"], r["model"]))
os.makedirs(os.path.join(root, "latest"), exist_ok=True)
with open(os.path.join(root, "latest", "summary.json"), "w", encoding="utf-8") as f:
    json.dump({"generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "rows": latest}, f, indent=2)

lines = [
    "# Quality benchmarks — latest",
    "",
    "| Suite | Model | pass@1 | pass@10 | n | samples/task | Stamp |",
    "| --- | --- | ---: | ---: | ---: | ---: | --- |",
]
for r in latest:
    def fmt(x):
        if x is None: return "—"
        if isinstance(x, float): return f"{x:.3f}"
        return str(x)
    lines.append(
        f"| {r['suite']} | `{r['model']}` | {fmt(r['pass_at_1'])} | {fmt(r['pass_at_10'])} | "
        f"{fmt(r['n_tasks'])} | {fmt(r['n_samples'])} | `{r['stamp']}` |"
    )
lines.append("")
md = "\n".join(lines)
with open(os.path.join(root, "latest", "compare.md"), "w", encoding="utf-8") as f:
    f.write(md)
print(md)
PY
}

cmd="${1:-}"
case "$cmd" in
  ""|help|-h|--help)
    usage
    ;;
  list|ls)
    list_plugins
    ;;
  compare)
    compare_quality
    ;;
  run)
    shift
    [[ $# -ge 1 ]] || die "usage: ./bench quality run <suite> …"
    run_plugin "$@"
    ;;
  *)
    # ./bench quality humaneval … → treat as suite name
    run_plugin "$@"
    ;;
esac
