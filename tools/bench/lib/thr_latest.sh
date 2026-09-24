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
  PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$_BENCH_THR_LATEST_DIR/../../.." && pwd)}" \
    bench_python - "$out" <<'PY'
import json, os, re, sys
from pathlib import Path

out = Path(sys.argv[1])
lib = None
for p in [out, *out.parents]:
    cand = p / "tools" / "bench" / "lib"
    if (cand / "thr_metrics.py").is_file():
        lib = cand
        break
if lib is None:
    root = os.environ.get("PROJECT_ROOT")
    if root:
        lib = Path(root) / "tools" / "bench" / "lib"
if lib is None or not (lib / "thr_metrics.py").is_file():
    raise SystemExit(f"thr_metrics.py not found (out={out})")
sys.path.insert(0, str(lib))
from thr_metrics import parse_compare_md, dash

latest = out / "latest"
by_eng = latest / "by-engine"
engines = {}

def parse_compare(path: Path, default_engine: str):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return default_engine, []
    return parse_compare_md(text, default_engine)

# Load per-engine snapshots
if by_eng.is_dir():
    for d in sorted(by_eng.iterdir()):
        if not d.is_dir():
            continue
        meta_path = d / "meta.json"
        cmp_path = d / "compare.md"
        eng = d.name.replace("_", ".")
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

# Fallback: single latest/compare.md only if no by-engine data
if not engines:
    single = latest / "compare.md"
    single_meta = latest / "meta.json"
    eng = "llama.cpp"
    meta = {"engine": eng}
    if single_meta.is_file():
        try:
            meta = json.loads(single_meta.read_text(encoding="utf-8"))
            eng = (meta.get("engine") or eng).strip() or eng
            if isinstance(meta.get("engines"), dict):
                meta = {"engine": eng}
        except (OSError, json.JSONDecodeError):
            pass
    if single.is_file() and "## " not in single.read_text(encoding="utf-8")[:500]:
        eng, models = parse_compare(single, eng)
        if models:
            engines[eng] = {"meta": {**meta, "engine": eng}, "models": models, "dir": str(latest)}

# Recover engines from stamped archives
for path in sorted(out.glob("llama-bench-*-compare.md"), reverse=True):
    eng, models = parse_compare(path, "llama.cpp")
    if not models or eng in engines:
        continue
    slug = re.sub(r"[^a-z0-9._-]", "-", eng.lower())
    dest = by_eng / slug
    dest.mkdir(parents=True, exist_ok=True)
    dest.joinpath("compare.md").write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    meta = {"engine": eng, "recovered_from": path.name}
    dest.joinpath("meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    engines[eng] = {"meta": meta, "models": models, "dir": str(dest)}

HDR = "| model | ttft_cold_ms | ttft_warm_ms | prefill_tok_s | decode_tok_s | itl_p50_ms |"
SEP = "| --- | ---: | ---: | ---: | ---: | ---: |"

lines = [
    "# Throughput compare (multi-engine)",
    "",
    "Per-engine snapshots: `latest/by-engine/<engine>/`.",
    "",
    "Definitions:",
    "",
    "- **TTFT** — time to first token (ms, lower better). Cold = first request; warm = immediate repeat.",
    "- **Prefill tok/s** — prompt processing ≈ fill_tokens / warm_TTFT. Higher better.",
    "- **Decode tok/s** — generation after first token. Higher better.",
    "- **ITL p50** — median inter-token latency during decode (ms, lower better).",
    "",
]
for eng in sorted(engines.keys(), key=lambda e: (0 if e == "llama.cpp" else 1, e)):
    block = engines[eng]
    models = block["models"]
    lines.append(f"## {eng}")
    lines.append("")
    lines.append(f"engine: {eng}")
    lines.append("")
    lines.append(HDR)
    lines.append(SEP)
    for m in models:
        lines.append(
            f"| {m['model']} | {dash(m.get('ttft_cold_ms'))} | {dash(m.get('ttft_warm_ms'))} | "
            f"{dash(m.get('prefill_tok_s'))} | {dash(m.get('decode_tok_s'))} | "
            f"{dash(m.get('itl_p50_ms'))} |"
        )
    lines.append("")

(latest / "compare.md").write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

merged_meta = {
    "engines": {
        eng: {**(block.get("meta") or {}), "engine": eng, "n_models": len(block.get("models") or [])}
        for eng, block in engines.items()
    },
    "engine": ",".join(sorted(engines.keys())),
    "metrics": ["ttft_cold_ms", "ttft_warm_ms", "prefill_tok_s", "decode_tok_s", "itl_p50_ms"],
}
(latest / "meta.json").write_text(json.dumps(merged_meta, indent=2) + "\n", encoding="utf-8")

rows = []
for eng in sorted(engines.keys(), key=lambda e: (0 if e == "llama.cpp" else 1, e)):
    for m in engines[eng]["models"]:
        rows.append(
            "<tr>"
            f"<td>{eng}</td><td>{m['model']}</td>"
            f"<td class='n'>{dash(m.get('ttft_cold_ms'))}</td>"
            f"<td class='n'>{dash(m.get('ttft_warm_ms'))}</td>"
            f"<td class='n'>{dash(m.get('prefill_tok_s'))}</td>"
            f"<td class='n'>{dash(m.get('decode_tok_s'))}</td>"
            f"<td class='n'>{dash(m.get('itl_p50_ms'))}</td>"
            "</tr>"
        )
html = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"/><title>Throughput compare</title>
<style>
body{{font:15px/1.5 system-ui,sans-serif;background:#0f1115;color:#e8eaed;margin:1.5rem}}
table{{border-collapse:collapse;width:100%}} th,td{{border-bottom:1px solid #252a35;padding:.4rem .55rem;text-align:left}}
th.n,td.n{{text-align:right;font-variant-numeric:tabular-nums}}
.meta{{color:#9aa0a6}} .def{{margin:.75rem 0 1.25rem;font-size:.92rem;color:#9aa0a6}}
.def strong{{color:#c4c7cc}}
</style></head><body>
<h1>Throughput (multi-engine)</h1>
<p class="meta">Merged from latest/by-engine/*</p>
<div class="def">
  <div><strong>TTFT cold/warm</strong> — ms to first token (lower better). Cold = first fill; warm = repeat (cache may hit).</div>
  <div><strong>Prefill tok/s</strong> — prompt processing speed. Higher better.</div>
  <div><strong>Decode tok/s</strong> — generation after first token. Higher better.</div>
  <div><strong>ITL p50</strong> — median ms between output tokens (lower better).</div>
</div>
<table><thead><tr>
<th>Engine</th><th>Model</th>
<th class="n">TTFT cold</th><th class="n">TTFT warm</th>
<th class="n">Prefill tok/s</th><th class="n">Decode tok/s</th><th class="n">ITL p50</th>
</tr></thead>
<tbody>
{''.join(rows) if rows else '<tr><td colspan="7" class="meta">No data</td></tr>'}
</tbody></table>
<p class="meta">Markdown: output/bench/throughput/latest/compare.md</p>
</body></html>
"""
(latest / "compare.html").write_text(html, encoding="utf-8")
print(f"[bench thr] merged latest for engines: {', '.join(engines) or '(none)'}")
PY
}
