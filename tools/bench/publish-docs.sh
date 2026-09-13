#!/usr/bin/env bash
# Publish curated bench artifacts to docs/ for GitHub Pages.
#
# Copies only small summaries / HTML (not raw jsonl runs).
# Usage:
#   ./tools/bench/publish-docs.sh
#   ./bench publish
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/output/bench"
DST="$ROOT/docs"

mkdir -p "$DST/throughput/latest" "$DST/scheduling/latest" "$DST/quality" "$DST/capacity/latest"

copy_if() {
  local from="$1" to="$2"
  if [[ -e "$from" ]]; then
    mkdir -p "$(dirname "$to")"
    cp -a "$from" "$to"
    echo "  + ${to#"$ROOT/"}"
  fi
}

echo "=== publish docs/ (GitHub Pages) ==="

# Hardware snapshot (always refresh on publish host)
if [[ -x "$ROOT/tools/bench/probe-host.sh" ]]; then
  "$ROOT/tools/bench/probe-host.sh" || true
fi

# Rebuild index/planner if present
if [[ -x "$ROOT/tools/bench/build-index.sh" ]]; then
  "$ROOT/tools/bench/build-index.sh" || true
fi
if [[ -x "$ROOT/tools/bench/build-planner.sh" ]]; then
  "$ROOT/tools/bench/build-planner.sh" || true
fi

copy_if "$SRC/host.json" "$DST/host.json"
copy_if "$SRC/index.html" "$DST/index.html"
copy_if "$SRC/index.md" "$DST/index.md"
copy_if "$SRC/planner.html" "$DST/planner.html"

copy_if "$SRC/throughput/latest/compare.html" "$DST/throughput/latest/compare.html"
copy_if "$SRC/throughput/latest/compare.md" "$DST/throughput/latest/compare.md"

copy_if "$SRC/scheduling/latest/compare.html" "$DST/scheduling/latest/compare.html"
copy_if "$SRC/scheduling/latest/compare.md" "$DST/scheduling/latest/compare.md"
copy_if "$SRC/scheduling/latest/summary.json" "$DST/scheduling/latest/summary.json"
copy_if "$SRC/scheduling/latest/manifest.json" "$DST/scheduling/latest/manifest.json"
copy_if "$SRC/scheduling/latest/apply-plan.json" "$DST/scheduling/latest/apply-plan.json"

copy_if "$SRC/capacity/latest/compare.md" "$DST/capacity/latest/compare.md"
copy_if "$SRC/capacity/latest/manifest.json" "$DST/capacity/latest/manifest.json"
copy_if "$SRC/capacity/cells.jsonl" "$DST/capacity/cells.jsonl"
copy_if "$SRC/matrix/progress.json" "$DST/matrix/progress.json"

# Quality: copy latest summaries + index if any
if [[ -d "$SRC/quality" ]]; then
  find "$SRC/quality" -maxdepth 3 \( -name 'summary.json' -o -name 'compare.md' -o -name 'compare.html' -o -name 'latest.json' -o -name 'index.md' \) \
    -print0 2>/dev/null | while IFS= read -r -d '' f; do
    rel="${f#"$SRC/"}"
    copy_if "$f" "$DST/$rel"
  done
fi

# Landing hint if index missing
if [[ ! -f "$DST/index.html" ]]; then
  cat >"$DST/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>strix-halo-llm benches</title></head>
<body>
<h1>strix-halo-llm</h1>
<p>No bench dashboard published yet. On the build host run <code>./bench index && ./bench publish</code>.</p>
</body></html>
HTML
  echo "  + docs/index.html (placeholder)"
fi

# Pages config (project site at /strix-halo-llm/)
if [[ ! -f "$DST/.nojekyll" ]]; then
  touch "$DST/.nojekyll"
  echo "  + docs/.nojekyll"
fi

cat >"$DST/README.md" <<'EOF'
# GitHub Pages (bench dashboard)

Static site root. Enable once per fork:

1. Repo **Settings → Pages → Build and deployment**
2. Source: **Deploy from a branch**
3. Branch: `main` → folder **`/docs`** → Save

After benches on your machine:

```bash
./bench publish
git add docs
git commit -m "docs: refresh bench dashboard"
git push
```

`./bench publish` refreshes `host.json` (RAM, GTT, GPU, llama.cpp pin, image id)
and rebuilds `index.html` so results stay comparable across forks.

Workflow: `.github/workflows/pages.yml` deploys `docs/` on push (Actions must be allowed on the fork).
EOF

echo "✓ docs/ ready for GitHub Pages"
