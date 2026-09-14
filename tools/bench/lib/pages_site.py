#!/usr/bin/env python3
"""Public GitHub Pages site: overview + detail pages (no operator/local tools)."""
from __future__ import annotations

import html
import json
import os
import re
from typing import Any


def esc(s: Any) -> str:
    return html.escape(str(s if s is not None else ""))


def tip(label: str, explanation: str) -> str:
    return (
        f'<span class="tip" tabindex="0">{esc(label)}'
        f'<span class="tip-text" role="tooltip">{esc(explanation)}</span></span>'
    )


def fmt_num(x: Any, digits: int = 1) -> str:
    if x is None or x == "" or x == "—":
        return "—"
    if isinstance(x, (int, float)):
        if abs(x) >= 1000:
            return f"{x:,.0f}"
        return f"{x:.{digits}f}"
    return str(x)


def fmt_pct(x: Any, digits: int = 1) -> str:
    if x is None or x == "" or x == "—":
        return "—"
    try:
        v = float(x)
    except (TypeError, ValueError):
        return str(x)
    return f"{100.0 * v:.{digits}f}%"


def parse_float(x: Any) -> float | None:
    if x is None or x == "" or x == "—":
        return None
    if isinstance(x, (int, float)):
        return float(x)
    try:
        return float(str(x).replace(",", "").strip())
    except (TypeError, ValueError):
        return None


def display_name(name: str | None, n: int = 28) -> str:
    """Short label for UI; full name stays in title=."""
    s = str(name or "").strip()
    if not s:
        return "—"
    # Drop common GGUF-ish suffixes for readability
    short = s
    for pat in (
        r"-UD-Q[\w.]+$",
        r"-Q\d+_K(_[A-Z]+)?$",
        r"-Q\d+_K_XL$",
        r"-GGUF$",
    ):
        short = re.sub(pat, "", short, flags=re.I)
    short = short.replace("-MTP", "").replace("_", "-")
    if len(short) > n:
        short = short[: n - 1] + "…"
    return short or s[:n]


SHARED_CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { font: 15px/1.55 "Segoe UI", system-ui, sans-serif; margin: 0 auto;
  padding: 1.5rem 1.35rem 3rem; max-width: 980px; background: #0f1115; color: #e8eaed; }
h1 { font-size: 1.45rem; font-weight: 650; letter-spacing: -0.02em; margin: 0 0 .3rem; }
h2 { font-size: 1.05rem; margin: 0 0 .5rem; color: #e8eaed; font-weight: 600; }
h3 { font-size: .95rem; margin: 1.1rem 0 .35rem; color: #c4c7cc; }
.meta { color: #9aa0a6; font-size: .9rem; }
.lede { color: #b8bdc5; font-size: .95rem; max-width: 40rem; margin: 0 0 1rem; }
a { color: #8ab4f8; }
.more { font-size: .85rem; margin: .25rem 0 1rem; }
.site-nav { display: flex; flex-wrap: wrap; gap: .25rem; margin: 0 0 1.35rem;
  padding: .35rem; background: #171a21; border: 1px solid #252a35; border-radius: 10px; }
.site-nav a { color: #9aa0a6; text-decoration: none; padding: .45rem .75rem;
  border-radius: 7px; font-size: .88rem; font-weight: 500; }
.site-nav a:hover { color: #e8eaed; background: #1e2330; }
.site-nav a.active { color: #e8eaed; background: #2a3444; }
.host-line { font-size: .88rem; color: #9aa0a6; margin: 0 0 1.25rem;
  padding: .55rem .75rem; background: #171a21; border-radius: 8px; border: 1px solid #252a35; }
.host-line a { color: #9aa0a6; }
table { border-collapse: collapse; width: 100%; margin: .5rem 0 1rem; }
th, td { padding: .45rem .6rem; border-bottom: 1px solid #2a2e37; }
th { text-align: left; color: #9aa0a6; font-weight: 600; font-size: .8rem; }
td.n, th.n { text-align: right; font-variant-numeric: tabular-nums;
  font-family: ui-monospace, "Cascadia Mono", monospace; }
.best { color: #7ddea5; font-weight: 600; }
.ok { color: #7ddea5; }
.fail { color: #f28b82; }
.card { background: #171a21; border: 1px solid #252a35; border-radius: 10px;
  padding: 1rem 1.15rem; margin: 1rem 0; }
.card h2 { margin-top: 0; }
.verdict-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: .7rem; margin-top: .75rem; }
.verdict-card { background: #12141a; border: 1px solid #252a35; border-radius: 10px;
  padding: .85rem .95rem; min-height: 5rem; }
.verdict-card.muted { opacity: .72; }
.verdict-label { font-size: .76rem; color: #9aa0a6; margin-bottom: .3rem; }
.verdict-value { font-size: 1.4rem; font-weight: 650; letter-spacing: -0.02em;
  font-variant-numeric: tabular-nums; }
.verdict-value .unit { font-size: .72rem; font-weight: 500; color: #9aa0a6; }
.verdict-sub { font-size: .76rem; color: #9aa0a6; margin-top: .3rem; word-break: break-word; }
.tip { position: relative; border-bottom: 1px dotted #6b7280; cursor: help; }
.tip .tip-text {
  visibility: hidden; opacity: 0; position: absolute; z-index: 40;
  left: 0; bottom: calc(100% + 8px); width: min(280px, 70vw);
  padding: .55rem .7rem; border-radius: 6px; background: #2a3140; color: #e8eaed;
  font-size: .8rem; font-weight: 400; line-height: 1.4;
  box-shadow: 0 8px 24px rgba(0,0,0,.35); pointer-events: none;
}
.tip:hover .tip-text, .tip:focus .tip-text, .tip:focus-within .tip-text {
  visibility: visible; opacity: 1;
}
details.panel { background: #171a21; border: 1px solid #252a35; border-radius: 10px;
  padding: .75rem 1.05rem 1rem; margin: 1rem 0; }
summary { cursor: pointer; color: #c4c7cc; font-weight: 600; }
.chart-box { background: #12141a; border-radius: 8px; padding: .75rem 1rem 1rem;
  border: 1px solid #252a35; margin: .75rem 0; }
.chart-wrap { position: relative; height: 280px; }
.chart-wrap.tall { height: 320px; }
.btn { display: inline-block; margin: .3rem .4rem .3rem 0; padding: .45rem .85rem;
  background: #2a3444; color: #e8eaed; border: none; border-radius: 6px; cursor: pointer;
  font: inherit; }
.btn.active { background: #3d5a3d; }
.metric-tabs { margin: .5rem 0 1rem; }
select.model-pick { background: #12141a; color: #e8eaed; border: 1px solid #2a2e37;
  border-radius: 4px; padding: .35rem .5rem; font: inherit; margin: .25rem .5rem .75rem 0; }
.scroll { overflow-x: auto; margin: .5rem 0 1rem; }
.scroll table { min-width: 480px; }
.links-row { display: flex; flex-wrap: wrap; gap: .75rem 1.25rem; margin: 1.25rem 0 0;
  font-size: .9rem; }
footer.site { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #252a35;
  color: #9aa0a6; font-size: .82rem; }
"""


def site_nav(active: str) -> str:
    items = [
        ("index.html", "overview", "Overview"),
        ("context.html", "context", "Context"),
        ("quality.html", "quality", "Quality"),
        ("host.html", "host", "Host"),
    ]
    links = []
    for href, key, label in items:
        cls = ' class="active"' if key == active else ""
        links.append(f'<a href="{href}"{cls}>{esc(label)}</a>')
    return f'<nav class="site-nav" aria-label="Site">{"".join(links)}</nav>'


def host_one_liner(host: dict | None) -> str:
    if not host:
        return '<p class="host-line">Host not probed yet. <a href="host.html">Host details</a></p>'
    gpu = host.get("gpu") or "GPU"
    # shorten long GPU strings
    if len(str(gpu)) > 48:
        gpu = str(gpu)[:47] + "…"
    ram = host.get("ram_gib")
    ram_s = f"{ram} GiB RAM" if ram is not None else "RAM —"
    backend = host.get("backend_default") or "—"
    pin = host.get("llama_pin") or {}
    commit = (pin.get("commit") or "")[:8] or "—"
    return (
        f'<p class="host-line">{esc(gpu)} · {esc(ram_s)} · {esc(backend)} · '
        f'llama.cpp <code>{esc(commit)}</code> · '
        f'<a href="host.html">Host details</a></p>'
    )


def shell(title: str, active: str, body: str, *, chart_js: bool = False, extra_head: str = "") -> str:
    chart = '<script src="chart.umd.min.js"></script>\n' if chart_js else ""
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>{SHARED_CSS}</style>
{chart}{extra_head}
</head><body>
{site_nav(active)}
{body}
<footer class="site">Measured benches on this host · comparable only for the same build (see Host)</footer>
</body></html>
"""


def verdict_cards(thr_models: list, qual_rows: list, cap_latest: dict) -> str:
    cards: list[str] = []

    best_q = None
    for r in qual_rows or []:
        p1 = parse_float(r.get("pass_at_1"))
        if p1 is None:
            continue
        if best_q is None or p1 > best_q[0]:
            best_q = (p1, r.get("model") or "—")
    if best_q:
        full = best_q[1]
        cards.append(
            '<div class="verdict-card">'
            f'<div class="verdict-label">{tip("Code quality", "HumanEval: share of Python problems solved on the first try. Code correctness only — not chat or speed.")}</div>'
            f'<div class="verdict-value">{fmt_pct(best_q[0])}</div>'
            f'<div class="verdict-sub" title="{esc(full)}">{esc(display_name(full))}</div>'
            "</div>"
        )
    else:
        cards.append(
            '<div class="verdict-card muted"><div class="verdict-label">Code quality</div>'
            '<div class="verdict-value">—</div><div class="verdict-sub">No HumanEval yet</div></div>'
        )

    best_tg = None
    for m in thr_models or []:
        tg = parse_float(m.get("tg"))
        if tg is None:
            continue
        if best_tg is None or tg > best_tg[0]:
            best_tg = (tg, m.get("model") or "—")
    if best_tg:
        full = best_tg[1]
        cards.append(
            '<div class="verdict-card">'
            f'<div class="verdict-label">{tip("Generation", "Tokens/s while writing the reply (alone on the server). Higher is better.")}</div>'
            f'<div class="verdict-value">{fmt_num(best_tg[0])} <span class="unit">tok/s</span></div>'
            f'<div class="verdict-sub" title="{esc(full)}">{esc(display_name(full))}</div>'
            "</div>"
        )
    else:
        cards.append(
            '<div class="verdict-card muted"><div class="verdict-label">Generation</div>'
            '<div class="verdict-value">—</div><div class="verdict-sub">No throughput yet</div></div>'
        )

    best_pp = None
    for m in thr_models or []:
        pp = parse_float(m.get("pp"))
        if pp is None:
            continue
        if best_pp is None or pp > best_pp[0]:
            best_pp = (pp, m.get("model") or "—")
    if best_pp:
        full = best_pp[1]
        cards.append(
            '<div class="verdict-card">'
            f'<div class="verdict-label">{tip("Prompt", "Tokens/s while reading the prompt (alone). Higher is better.")}</div>'
            f'<div class="verdict-value">{fmt_num(best_pp[0])} <span class="unit">tok/s</span></div>'
            f'<div class="verdict-sub" title="{esc(full)}">{esc(display_name(full))}</div>'
            "</div>"
        )
    else:
        cards.append(
            '<div class="verdict-card muted"><div class="verdict-label">Prompt</div>'
            '<div class="verdict-value">—</div><div class="verdict-sub">No throughput yet</div></div>'
        )

    # Max context: best per host, prefer showing one model
    max_c = None
    for r in (cap_latest or {}).values():
        if r.get("mode") != "solo" or r.get("skipped") or not r.get("ok"):
            continue
        c = int(r.get("c") or 0)
        if max_c is None or c > max_c[0]:
            max_c = (c, r.get("model") or "—", r.get("kv") or "—")
    if max_c:
        full = max_c[1]
        # Prefer 256k style label when exact power of two-ish
        c_label = f"{max_c[0]:,}"
        if max_c[0] == 262144:
            c_label = "256k"
        elif max_c[0] == 131072:
            c_label = "128k"
        elif max_c[0] == 65536:
            c_label = "64k"
        cards.append(
            '<div class="verdict-card">'
            f'<div class="verdict-label">{tip("Max context", "Largest context length that loaded and ran successfully.")}</div>'
            f'<div class="verdict-value">{esc(c_label)}</div>'
            f'<div class="verdict-sub" title="{esc(full)}">{esc(display_name(full))} · KV {esc(max_c[2])}</div>'
            "</div>"
        )
    else:
        cards.append(
            '<div class="verdict-card muted"><div class="verdict-label">Max context</div>'
            '<div class="verdict-value">—</div><div class="verdict-sub">No capacity yet</div></div>'
        )

    return (
        '<section class="card" id="verdict" aria-label="At a glance">'
        "<h2>At a glance</h2>"
        '<p class="meta">Best measured numbers on this host.</p>'
        f'<div class="verdict-grid">{"".join(cards)}</div>'
        "</section>"
    )


def thr_table_html(thr_models: list) -> str:
    rows = []
    if thr_models:
        for m in thr_models:
            full = m.get("model") or "—"
            rows.append(
                f'<tr><td title="{esc(full)}">{esc(display_name(full, 40))}</td>'
                f'<td class="n">{esc(m.get("pp") or "—")}</td>'
                f'<td class="n">{esc(m.get("tg") or "—")}</td></tr>'
            )
    else:
        rows.append('<tr><td colspan="3" class="meta">No throughput runs yet.</td></tr>')
    return (
        '<div class="card" id="throughput"><h2>Single-user throughput</h2>'
        '<p class="meta">One request at a time. Higher tokens/s is better.</p>'
        '<p class="more"><a href="throughput/latest/compare.html">→ Full throughput details</a></p>'
        "<table><thead><tr>"
        "<th>Model</th>"
        f'<th class="n">{tip("Prompt", "Tokens/s reading ~512-token prompt.")}</th>'
        f'<th class="n">{tip("Generation", "Tokens/s writing ~128 tokens.")}</th>'
        "</tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table></div>"
    )


def qual_table_html(qual_rows: list, *, fmt_stamp) -> str:
    rows = []
    if qual_rows:
        for r in qual_rows:
            p1, p10 = r.get("pass_at_1"), r.get("pass_at_10")
            suite = r.get("suite") or "—"
            suite_label = "HumanEval" if "humaneval" in str(suite).lower() else suite
            full = r.get("model") or "—"
            p1s = fmt_pct(p1) if parse_float(p1) is not None else esc(p1 or "—")
            p10s = fmt_pct(p10) if parse_float(p10) is not None else esc(p10 or "—")
            rows.append(
                f"<tr><td>{esc(suite_label)}</td>"
                f'<td title="{esc(full)}">{esc(display_name(full, 40))}</td>'
                f'<td class="n best">{p1s}</td>'
                f'<td class="n">{p10s}</td>'
                f'<td class="meta">{esc(fmt_stamp(r.get("stamp") or ""))}</td></tr>'
            )
    else:
        rows.append('<tr><td colspan="5" class="meta">No code-quality runs yet.</td></tr>')
    return (
        "<table><thead><tr>"
        "<th>Benchmark</th><th>Model</th>"
        f'<th class="n">{tip("pass@1", "Share solved on the first sample (%).")}</th>'
        f'<th class="n">{tip("pass@10", "Needs n≥10 samples; else blank.")}</th>'
        "<th>Measured</th></tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table>"
    )


def max_ctx_one_per_model(cap_latest: dict, cap_metrics_fn) -> str:
    """One row per model at preferred KV (q8_0), largest ok context + dual note."""
    prefer_kv = ("q8_0", "q8", "q5_0", "q5", "q4_0", "q4")  # first match wins as preferred

    solo = [
        r
        for r in (cap_latest or {}).values()
        if r.get("mode") == "solo" and not r.get("skipped") and r.get("ok")
    ]
    if not solo:
        return '<p class="meta">No capacity runs yet.</p>'

    # model -> kv -> best row by c
    by_model: dict[str, dict[str, Any]] = {}
    for r in solo:
        model = r.get("model") or "?"
        kv = r.get("kv") or "?"
        c = int(r.get("c") or 0)
        prev = by_model.setdefault(model, {}).get(kv)
        if prev is None or c > int(prev.get("c") or 0):
            by_model[model][kv] = r

    def pick_row(kvs: dict[str, Any]):
        for pref in prefer_kv:
            if pref in kvs:
                return kvs[pref], pref
        # fallback: largest c, then any
        best = None
        for kv, r in kvs.items():
            if best is None or int(r.get("c") or 0) > int(best[0].get("c") or 0):
                best = (r, kv)
        return best if best else (None, None)

    def plausible(prefill_s, prefill_tok_s, c):
        """Hide obvious measurement glitches (e.g. >1500 t/s at 128k)."""
        if prefill_tok_s is not None and prefill_tok_s > 800:
            return False
        if prefill_s is not None and c and c >= 65536 and prefill_s < 30:
            return False
        return True

    # other KVs that also reach same max (for note)
    def other_note(model, chosen_kv, chosen_c):
        kvs = by_model.get(model) or {}
        alts = []
        for kv, r in sorted(kvs.items()):
            if kv == chosen_kv:
                continue
            if int(r.get("c") or 0) >= chosen_c:
                alts.append(kv)
        if not alts:
            return ""
        return f'<span class="meta">also @ {" / ".join(alts)}</span>'

    rows = []
    for model in sorted(by_model.keys()):
        r, kv = pick_row(by_model[model])
        if not r:
            continue
        m = cap_metrics_fn(r) or {}
        c = int(r.get("c") or 0)
        gtt_s = f"{m['gtt_mb']} MiB" if m.get("gtt_mb") is not None else "—"
        ps_v, pps_v = m.get("prefill_s"), m.get("prefill_tok_s")
        if plausible(ps_v, pps_v, c):
            ps = esc(f"{ps_v} s") if ps_v is not None else "—"
            pps = esc(f"{pps_v} t/s") if pps_v is not None else "—"
        else:
            ps = "—"
            pps = '<span class="meta" title="Prefill metric looked inconsistent — see full grid">suspect</span>'
        note = other_note(model, kv, c)
        rows.append(
            f'<tr><td title="{esc(model)}">{esc(display_name(model, 42))}</td>'
            f"<td>{esc(kv)}</td>"
            f'<td class="n best">{c:,}</td>'
            f'<td class="n">{esc(gtt_s)}</td>'
            f'<td class="n">{ps}</td>'
            f'<td class="n">{pps}</td>'
            f"<td>{note}</td></tr>"
        )

    # Dual summary: max ok context per model
    dual = [
        r
        for r in (cap_latest or {}).values()
        if r.get("mode") == "dual" and not r.get("skipped") and r.get("ok")
    ]
    dual_best: dict[str, Any] = {}
    for r in dual:
        model = r.get("model") or "?"
        c = int(r.get("c") or 0)
        prev = dual_best.get(model)
        if prev is None or c > int(prev.get("c") or 0):
            dual_best[model] = r
    dual_html = ""
    if dual_best:
        drows = []
        for model in sorted(dual_best.keys()):
            r = dual_best[model]
            drows.append(
                f'<tr><td title="{esc(model)}">{esc(display_name(model, 42))}</td>'
                f"<td>{esc(r.get('kv') or '—')}</td>"
                f'<td class="n best">{int(r.get("c") or 0):,}</td></tr>'
            )
        dual_html = (
            "<h3>Two instances (dual)</h3>"
            '<p class="meta">Largest context where two copies of the same model both fit.</p>'
            "<table><thead><tr><th>Model</th><th>KV</th>"
            '<th class="n">Max context</th></tr></thead><tbody>'
            + "".join(drows)
            + "</tbody></table>"
        )

    return (
        '<p class="meta">Preferred KV <strong>q8_0</strong> (typical sticky setting). '
        "Other quants that also reach the same max are noted on the right. "
        "Prompt cost is for a full fill at that context.</p>"
        "<table><thead><tr>"
        "<th>Model</th><th>KV</th>"
        f'<th class="n">{tip("Max context", "Largest successful context at the preferred KV (q8 when measured).")}</th>'
        f'<th class="n">{tip("Memory", "Shared GPU memory at that context.")}</th>'
        f'<th class="n">{tip("Prompt time", "Seconds to process a full prompt at max context.")}</th>'
        f'<th class="n">{tip("Prompt speed", "Tokens/s while reading the prompt.")}</th>'
        "<th>Also fits</th>"
        "</tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table>"
        + dual_html
    )


def overview_chart_script(thr_chart: dict) -> str:
    data = json.dumps({"throughput": thr_chart}, ensure_ascii=False).replace("<", "\\u003c")
    return f"""
<script id="bench-chart-data" type="application/json">{data}</script>
<script>
(function () {{
  const raw = document.getElementById("bench-chart-data");
  if (!raw || typeof Chart === "undefined") return;
  let DATA;
  try {{ DATA = JSON.parse(raw.textContent); }} catch (e) {{ return; }}
  const thr = DATA.throughput || {{}};
  if (!(thr.labels || []).length) return;
  const tick = {{ color: "#9aa0a6" }};
  const grid = {{ color: "#2a2e37" }};
  new Chart(document.getElementById("chart-thr"), {{
    type: "bar",
    data: {{
      labels: thr.labels,
      datasets: [
        {{ label: "Prompt (tok/s)", data: thr.pp, backgroundColor: "#5b8def" }},
        {{ label: "Generation (tok/s)", data: thr.tg, backgroundColor: "#7ddea5" }},
      ],
    }},
    options: {{
      responsive: true,
      maintainAspectRatio: false,
      plugins: {{ legend: {{ labels: {{ color: "#c4c7cc" }} }} }},
      scales: {{
        x: {{ ticks: tick, grid }},
        y: {{ ticks: tick, grid, title: {{ display: true, text: "tokens / s", color: "#9aa0a6" }} }},
      }},
    }},
  }});
}})();
</script>
"""


def context_chart_script(cap_chart: dict) -> str:
    data = json.dumps({"capacity": cap_chart}, ensure_ascii=False).replace("<", "\\u003c")
    return f"""
<script id="bench-chart-data" type="application/json">{data}</script>
<script>
(function () {{
  const raw = document.getElementById("bench-chart-data");
  const sel = document.getElementById("cap-model");
  const ySel = document.getElementById("cap-y");
  const canvas = document.getElementById("chart-cap");
  const fallback = document.getElementById("cap-fallback");
  if (!raw) return;
  let DATA;
  try {{ DATA = JSON.parse(raw.textContent); }} catch (e) {{ return; }}
  const cap = DATA.capacity || {{}};
  const models = Object.keys(cap).sort();
  const hasChart = typeof Chart !== "undefined";
  const tick = {{ color: "#9aa0a6" }};
  const grid = {{ color: "#2a2e37" }};
  const common = {{
    responsive: true,
    maintainAspectRatio: false,
    plugins: {{ legend: {{ labels: {{ color: "#c4c7cc" }} }} }},
  }};
  const yLabels = {{
    prefill_s: "Prompt time (s)",
    prefill_tok_s: "Prompt speed (tok/s)",
    gtt_gib: "Memory (GiB)",
    power_w: "GPU watts",
  }};
  const palette = ["#5b8def", "#7ddea5", "#f0c674", "#f28b82", "#c58af9", "#78d4e8"];
  let capChart = null;
  function fmtC(c) {{
    if (c >= 1024) return (c / 1024) + "k";
    return String(c);
  }}
  function renderCap(model) {{
    const series = cap[model] || {{}};
    const yKey = (ySel && ySel.value) || "prefill_s";
    const kvs = Object.keys(series).sort();
    if (!hasChart || !canvas) {{
      if (fallback) {{
        fallback.hidden = false;
        let html = "<table><thead><tr><th>KV</th><th class=\\"n\\">Context</th><th class=\\"n\\">Value</th></tr></thead><tbody>";
        kvs.forEach((kv) => {{
          (series[kv] || []).forEach((p) => {{
            if (p[yKey] == null) return;
            html += "<tr><td>" + kv + "</td><td class=\\"n\\">" + p.c + "</td><td class=\\"n\\">" + p[yKey] + "</td></tr>";
          }});
        }});
        html += "</tbody></table>";
        fallback.innerHTML = html;
      }}
      return;
    }}
    const datasets = kvs.map((kv, i) => ({{
      label: kv,
      data: (series[kv] || []).filter((p) => p[yKey] != null).map((p) => ({{ x: p.c, y: p[yKey] }})),
      borderColor: palette[i % palette.length],
      backgroundColor: palette[i % palette.length],
      tension: 0.15,
      showLine: true,
      pointRadius: 4,
    }}));
    if (capChart) capChart.destroy();
    capChart = new Chart(canvas, {{
      type: "line",
      data: {{ datasets }},
      options: {{
        ...common,
        parsing: false,
        scales: {{
          x: {{
            type: "linear",
            ticks: {{ ...tick, callback: (v) => fmtC(v) }},
            grid,
            title: {{ display: true, text: "context tokens", color: "#9aa0a6" }},
          }},
          y: {{
            ticks: tick,
            grid,
            title: {{ display: true, text: yLabels[yKey] || yKey, color: "#9aa0a6" }},
          }},
        }},
      }},
    }});
  }}
  if (sel && models.length) {{
    models.forEach((m) => {{
      const o = document.createElement("option");
      o.value = m;
      o.textContent = m.length > 48 ? m.slice(0, 47) + "…" : m;
      o.title = m;
      sel.appendChild(o);
    }});
    sel.addEventListener("change", () => renderCap(sel.value));
    if (ySel) ySel.addEventListener("change", () => renderCap(sel.value));
    renderCap(models[0]);
  }} else if (sel) {{
    sel.outerHTML = '<p class="meta">No capacity series yet.</p>';
  }}
}})();
</script>
"""


def write_public_pages(
    out_root: str,
    *,
    host: dict | None,
    thr_models: list,
    qual_rows: list,
    cap_latest: dict,
    thr_chart: dict,
    cap_chart: dict,
    capacity_grid_html: str,
    fingerprint_html: str,
    host_html_card: str,
    cap_metrics_fn,
    fmt_stamp,
    cap_has_power: bool = False,
) -> list[str]:
    """Write overview + detail pages. Returns list of written paths."""
    written = []

    # --- Overview ---
    body = f"""
<header>
<h1>LLM bench results</h1>
<p class="lede">Speed, longest usable context, and code correctness — measured on this host.</p>
</header>
{host_one_liner(host)}
{verdict_cards(thr_models, qual_rows, cap_latest)}
<div class="card" id="charts">
<h2>Prompt vs generation</h2>
<p class="meta">Tokens per second with the model alone on the server. Higher is better.</p>
<div class="chart-box"><div class="chart-wrap"><canvas id="chart-thr"></canvas></div></div>
</div>
{thr_table_html(thr_models)}
<div class="card" id="quality-preview">
<h2>Code correctness</h2>
<p class="meta">HumanEval pass@1 — code only, not chat quality. <a href="quality.html">→ Quality page</a></p>
{qual_table_html(qual_rows, fmt_stamp=fmt_stamp)}
</div>
<p class="links-row">
  <a href="context.html">Context &amp; memory →</a>
  <a href="quality.html">Quality details →</a>
  <a href="host.html">Host &amp; build →</a>
  <a href="scheduling/latest/compare.html">Under-load sweeps →</a>
</p>
{overview_chart_script(thr_chart)}
"""
    overview = shell("LLM Bench — Overview", "overview", body, chart_js=True)
    # Default entry point = same as GitHub Pages (index.html)
    path = os.path.join(out_root, "index.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(overview)
    written.append(path)
    # Compat alias for older publish / bookmarks
    alias = os.path.join(out_root, "pages-index.html")
    with open(alias, "w", encoding="utf-8") as f:
        f.write(overview)
    written.append(alias)

    # --- Context ---
    power_opt = (
        '<option value="power_w">GPU watts (avg)</option>' if cap_has_power else ""
    )
    # capacity_grid_html may be a full card; wrap in details
    grid_block = capacity_grid_html or '<p class="meta">No capacity grid yet.</p>'
    ctx_body = f"""
<header>
<h1>Context &amp; memory</h1>
<p class="lede">How far context can grow, and what prompt processing costs at that point.</p>
</header>
{host_one_liner(host)}
<div class="card">
<h2>Longest context that fits</h2>
{max_ctx_one_per_model(cap_latest, cap_metrics_fn)}
</div>
<div class="card">
<h2>Prompt cost vs context</h2>
<p class="meta">Pick a model. Lower line = faster prompt processing as context grows.</p>
<label class="meta" for="cap-model">Model </label>
<select id="cap-model" class="model-pick"></select>
<label class="meta" for="cap-y">Y axis </label>
<select id="cap-y" class="model-pick">
  <option value="prefill_s" selected>Prompt time (s)</option>
  <option value="prefill_tok_s">Prompt speed (tok/s)</option>
  <option value="gtt_gib">Memory (GiB)</option>
  {power_opt}
</select>
<div class="chart-box"><div class="chart-wrap tall"><canvas id="chart-cap"></canvas></div>
<div id="cap-fallback" class="meta" hidden></div></div>
</div>
<details class="panel">
<summary>Full context × KV grid &amp; dual instances</summary>
<p class="meta">Lab detail — every measured cell. Prefer the summary table above for decisions.</p>
{grid_block}
</details>
<p class="more"><a href="capacity/latest/compare.md">→ Capacity ledger (markdown)</a></p>
{context_chart_script(cap_chart)}
"""
    path = os.path.join(out_root, "context.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(shell("LLM Bench — Context", "context", ctx_body, chart_js=True))
    written.append(path)

    # --- Quality ---
    q_body = f"""
<header>
<h1>Code correctness</h1>
<p class="lede">HumanEval-style Python coding problems. Measures whether generated code passes unit tests — not chat style, reasoning prose, or speed.</p>
</header>
{host_one_liner(host)}
<div class="card">
<h2>HumanEval</h2>
<p class="meta"><strong>pass@1</strong> = share of problems solved with a single sample.
<strong>pass@10</strong> needs multiple samples per problem (n≥10); otherwise blank.</p>
{qual_table_html(qual_rows, fmt_stamp=fmt_stamp)}
<p class="more"><a href="quality/latest/compare.md">→ Per-run details</a></p>
</div>
"""
    path = os.path.join(out_root, "quality.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(shell("LLM Bench — Quality", "quality", q_body))
    written.append(path)

    # --- Host ---
    # Strip outer card duplication somewhat — host_html_card already has card
    h_body = f"""
<header>
<h1>Host &amp; build</h1>
<p class="lede">Results only compare fairly on the same machine, driver, and llama.cpp build.</p>
</header>
{host_html_card}
{fingerprint_html}
"""
    path = os.path.join(out_root, "host.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(shell("LLM Bench — Host", "host", h_body))
    written.append(path)

    return written
