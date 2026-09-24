#!/usr/bin/env bash
# Multi-engine throughput "latest" — per-engine dirs + merged overview files.
#
# Layout:
#   output/bench/throughput/latest/by-engine/<slug>/{compare.md,meta.json}
#   output/bench/throughput/latest/{compare.md,meta.json,compare.html}  # merged
#
# Writers call: bench_thr_publish_engine_latest <engine> <compare.md> <meta.json> [compare.html]
#
# shellcheck shell=bash

_BENCH_THR_LATEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=python.sh
source "$_BENCH_THR_LATEST_DIR/python.sh"
# shellcheck source=engine.sh
source "$_BENCH_THR_LATEST_DIR/engine.sh" 2>/dev/null || true

bench_thr_engine_slug() {
  local eng
  eng="$(bench_engine_normalize "${1:-${BENCH_ENGINE:-llama.cpp}}" 2>/dev/null || echo "${1:-llama.cpp}")"
  printf '%s\n' "$eng" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

# Publish one engine's latest artifacts, then rebuild merged latest/.
# Args: engine compare_md_path meta_json_path [optional_html]
bench_thr_publish_engine_latest() {
  local eng="${1:?}"
  local cmp_src="${2:?}"
  local meta_src="${3:?}"
  local html_src="${4:-}"
  local root out slug eng_dir
  root="${PROJECT_ROOT:-${BENCH_ROOT:-}}"
  if [[ -z "$root" ]]; then
    root="$(cd "$_BENCH_THR_LATEST_DIR/../../.." && pwd)"
  fi
  out="${BENCH_OUT:-${THROUGHPUT_OUT:-$root/output/bench/throughput}}"
  eng="$(bench_engine_normalize "$eng" 2>/dev/null || echo "$eng")"
  slug="$(bench_thr_engine_slug "$eng")"
  eng_dir="$out/latest/by-engine/$slug"
  mkdir -p "$eng_dir" "$out/latest"

  [[ -f "$cmp_src" ]] || {
    printf '[bench thr] error: missing compare.md %s\n' "$cmp_src" >&2
    return 1
  }
  # HTTP backend already writes into eng_dir/compare.md — skip same-file cp.
  if [[ "$(cd "$(dirname "$cmp_src")" && pwd)/$(basename "$cmp_src")" != \
        "$(cd "$eng_dir" && pwd)/compare.md" ]]; then
    cp -f "$cmp_src" "$eng_dir/compare.md"
  fi
  if [[ -f "$meta_src" ]]; then
    if [[ "$(cd "$(dirname "$meta_src")" && pwd)/$(basename "$meta_src")" != \
          "$(cd "$eng_dir" && pwd)/meta.json" ]]; then
      cp -f "$meta_src" "$eng_dir/meta.json"
    fi
  else
    printf '{"engine":"%s"}\n' "$eng" >"$eng_dir/meta.json"
  fi
  # Ensure engine field in meta (Nix: use bench_python, not bare python3)
  bench_python - "$eng_dir/meta.json" "$eng" <<'PY' || true
import json, sys
path, eng = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data["engine"] = eng
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  if [[ -n "$html_src" && -f "$html_src" ]]; then
    cp -f "$html_src" "$eng_dir/compare.html"
  fi

  bench_thr_rebuild_merged_latest "$out"
}

bench_thr_rebuild_merged_latest() {
  local out="${1:?}"
  mkdir -p "$out/latest"
  # NixOS often has no `python3` on PATH — always go through bench_python
  bench_python - "$out" <<'PY'
import json, os, re, sys
from pathlib import Path

out = Path(sys.argv[1])
latest = out / "latest"
by_eng = latest / "by-engine"
engines = {}

def parse_compare(path: Path, default_engine: str):
    models = []
    engine = default_engine
    in_table = False
    header_cols = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return engine, models
    for line in text.splitlines():
        raw = line.rstrip()
        low = raw.lower()
        if low.startswith("engine:"):
            engine = raw.split(":", 1)[1].strip() or engine
            continue
        if raw.startswith("|") and "model" in low and ("pp" in low or "tg" in low):
            header_cols = [c.strip() for c in raw.strip("|").split("|")]
            in_table = True
            continue
        if in_table:
            if not raw.startswith("|") or raw.startswith("| ---") or re.match(r"^\|\s*-+", raw):
                if models:
                    break
                continue
            parts = [p.strip() for p in raw.strip("|").split("|")]
            if not parts or parts[0].lower() == "model":
                continue
            # Prefer columns named like "* pp" / "* tg" or positions 1,2
            pp = tg = "—"
            if header_cols and len(header_cols) == len(parts):
                for h, v in zip(header_cols, parts):
                    hl = h.lower()
                    if hl.endswith(" pp") or hl == "pp":
                        pp = v
                    elif hl.endswith(" tg") or hl == "tg":
                        tg = v
                if pp == "—" and len(parts) >= 3:
                    pp, tg = parts[1], parts[2]
            elif len(parts) >= 3:
                pp, tg = parts[1], parts[2]
            models.append({"model": parts[0], "pp": pp, "tg": tg, "engine": engine})
    return engine, models

# Load per-engine snapshots
if by_eng.is_dir():
    for d in sorted(by_eng.iterdir()):
        if not d.is_dir():
            continue
        meta_path = d / "meta.json"
        cmp_path = d / "compare.md"
        eng = d.name.replace("_", ".")  # halogen-flash stays; llama.cpp slug keeps dot
        if meta_path.is_file():
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                eng = (meta.get("engine") or eng).strip() or eng
            except (OSError, json.JSONDecodeError):
                meta = {"engine": eng}
        else:
            meta = {"engine": eng}
        if cmp_path.is_file():
            eng2, models = parse_compare(cmp_path, eng)
            eng = eng2 or eng
            engines[eng] = {"meta": meta, "models": models, "dir": str(d)}

# Legacy fallback: single latest/compare.md only if no by-engine data
if not engines:
    legacy = latest / "compare.md"
    legacy_meta = latest / "meta.json"
    eng = "llama.cpp"
    meta = {"engine": eng}
    if legacy_meta.is_file():
        try:
            meta = json.loads(legacy_meta.read_text(encoding="utf-8"))
            eng = (meta.get("engine") or eng).strip() or eng
            # merged meta from a previous multi-engine run — skip single parse
            if isinstance(meta.get("engines"), dict):
                meta = {"engine": eng}
        except (OSError, json.JSONDecodeError):
            pass
    if legacy.is_file() and "## " not in legacy.read_text(encoding="utf-8")[:500]:
        eng, models = parse_compare(legacy, eng)
        if models:
            engines[eng] = {"meta": {**meta, "engine": eng}, "models": models, "dir": str(latest)}

# Recover engines from stamped archives (e.g. llama overrun by halogen)
for path in sorted(out.glob("llama-bench-*-compare.md"), reverse=True):
    eng, models = parse_compare(path, "llama.cpp")
    if not models:
        continue
    if eng in engines:
        continue
    # Persist recovered snapshot into by-engine/
    slug = re.sub(r"[^a-z0-9._-]", "-", eng.lower())
    dest = by_eng / slug
    dest.mkdir(parents=True, exist_ok=True)
    dest.joinpath("compare.md").write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    meta = {"engine": eng, "recovered_from": path.name}
    dest.joinpath("meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    engines[eng] = {"meta": meta, "models": models, "dir": str(dest)}

# Write merged compare.md
lines = [
    "# llama-bench compare (multi-engine)",
    "",
    "Per-engine snapshots: `latest/by-engine/<engine>/`. "
    "This file merges the latest result for each engine.",
    "",
]
for eng in sorted(engines.keys(), key=lambda e: (0 if e == "llama.cpp" else 1, e)):
    block = engines[eng]
    models = block["models"]
    lines.append(f"## {eng}")
    lines.append("")
    lines.append(f"engine: {eng}")
    lines.append("")
    lines.append("| model | pp | tg |")
    lines.append("| --- | ---: | ---: |")
    for m in models:
        lines.append(f"| {m['model']} | {m.get('pp') or '—'} | {m.get('tg') or '—'} |")
    lines.append("")

(latest / "compare.md").write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

merged_meta = {
    "engines": {
        eng: {**(block.get("meta") or {}), "engine": eng, "n_models": len(block.get("models") or [])}
        for eng, block in engines.items()
    },
    "engine": ",".join(sorted(engines.keys())),
}
(latest / "meta.json").write_text(json.dumps(merged_meta, indent=2) + "\n", encoding="utf-8")

# Simple merged HTML
rows = []
for eng in sorted(engines.keys(), key=lambda e: (0 if e == "llama.cpp" else 1, e)):
    for m in engines[eng]["models"]:
        rows.append(
            "<tr>"
            f"<td>{eng}</td><td>{m['model']}</td>"
            f"<td class='n'>{m.get('pp') or '—'}</td>"
            f"<td class='n'>{m.get('tg') or '—'}</td>"
            "</tr>"
        )
html = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"/><title>Throughput compare</title>
<style>
body{{font:15px/1.5 system-ui,sans-serif;background:#0f1115;color:#e8eaed;margin:1.5rem}}
table{{border-collapse:collapse;width:100%}} th,td{{border-bottom:1px solid #252a35;padding:.4rem .55rem;text-align:left}}
th.n,td.n{{text-align:right;font-variant-numeric:tabular-nums}}
.meta{{color:#9aa0a6}}
</style></head><body>
<h1>Throughput (multi-engine)</h1>
<p class="meta">Merged from latest/by-engine/*</p>
<table><thead><tr><th>Engine</th><th>Model</th><th class="n">pp</th><th class="n">tg</th></tr></thead>
<tbody>
{''.join(rows) if rows else '<tr><td colspan="4" class="meta">No data</td></tr>'}
</tbody></table>
<p class="meta">Markdown: output/bench/throughput/latest/compare.md</p>
</body></html>
"""
(latest / "compare.html").write_text(html, encoding="utf-8")
print(f"[bench thr] merged latest for engines: {', '.join(engines) or '(none)'}")
PY
}
