#!/usr/bin/env bash
# Publish curated bench artifacts to docs/ for GitHub Pages.
#
# Pages = measured benches only (host, capacity, sched metrics, throughput, quality).
# Recommendations / planner / apply-plan stay local under output/bench/ — NOT copied.
#
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

echo "=== publish docs/ (GitHub Pages — benches only, no recommendations) ==="

# Hardware snapshot (always refresh on publish host)
if [[ -x "$ROOT/tools/bench/probe-host.sh" ]]; then
  "$ROOT/tools/bench/probe-host.sh" || true
fi

# Rebuild index (writes index.html local + pages-index.html for Pages)
if [[ -x "$ROOT/tools/bench/build-index.sh" ]]; then
  "$ROOT/tools/bench/build-index.sh" || true
fi
# Planner stays local-only (not copied below)

copy_if "$SRC/host.json" "$DST/host.json"
# Prefer pages-index (no apply/planner); fall back to index.html
if [[ -f "$SRC/pages-index.html" ]]; then
  copy_if "$SRC/pages-index.html" "$DST/index.html"
else
  copy_if "$SRC/index.html" "$DST/index.html"
fi
copy_if "$SRC/index.md" "$DST/index.md"
copy_if "$SRC/chart.umd.min.js" "$DST/chart.umd.min.js"

copy_if "$SRC/throughput/latest/compare.html" "$DST/throughput/latest/compare.html"
copy_if "$SRC/throughput/latest/compare.md" "$DST/throughput/latest/compare.md"

copy_if "$SRC/scheduling/latest/compare.html" "$DST/scheduling/latest/compare.html"
copy_if "$SRC/scheduling/latest/compare.md" "$DST/scheduling/latest/compare.md"
copy_if "$SRC/scheduling/latest/summary.json" "$DST/scheduling/latest/summary.json"
copy_if "$SRC/scheduling/latest/manifest.json" "$DST/scheduling/latest/manifest.json"
# intentionally NOT: apply-plan.json, planner.html

copy_if "$SRC/capacity/latest/compare.md" "$DST/capacity/latest/compare.md"
copy_if "$SRC/capacity/latest/manifest.json" "$DST/capacity/latest/manifest.json"
copy_if "$SRC/capacity/cells.jsonl" "$DST/capacity/cells.jsonl"
copy_if "$SRC/capacity/progress.json" "$DST/capacity/progress.json"
copy_if "$SRC/matrix/progress.json" "$DST/matrix/progress.json"

# Quality: copy latest summaries + index if any
if [[ -d "$SRC/quality" ]]; then
  find "$SRC/quality" -maxdepth 3 \( -name 'summary.json' -o -name 'compare.md' -o -name 'compare.html' -o -name 'latest.json' -o -name 'index.md' \) \
    -print0 2>/dev/null | while IFS= read -r -d '' f; do
    rel="${f#"$SRC/"}"
    copy_if "$f" "$DST/$rel"
  done
fi

# Remove stale recommendation artifacts from docs/ if previously published
rm -f "$DST/planner.html" "$DST/scheduling/latest/apply-plan.json" 2>/dev/null || true

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
# GitHub Pages (benchmark results only)

Static site root — **measured benches** (capacity, sched, throughput, quality, host).
Recommendation planner / apply-ini stay on the bench host (`output/bench/`), not here.

Enable once per fork:

1. Repo **Settings → Pages → Build and deployment**
2. Source: **Deploy from a branch**
3. Branch: `main` → folder **`/docs`** → Save

```bash
./bench publish
git add docs
git commit -m "docs: refresh bench dashboard"
git push
```
EOF

echo "✓ docs/ ready for GitHub Pages (benches only)"
