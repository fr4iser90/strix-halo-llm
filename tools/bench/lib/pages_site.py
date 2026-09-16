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


def normalize_engine(value: Any) -> str:
    raw = str(value or "llama.cpp").strip().lower().replace("_", "-")
    raw = re.sub(r"-+", "-", raw)
    aliases = {
        "": "llama.cpp",
        "llama": "llama.cpp",
        "llamacpp": "llama.cpp",
        "llama-cpp": "llama.cpp",
        "llama.cpp": "llama.cpp",
        "halogen": "halogen-flash",
        "halogen-flash": "halogen-flash",
        "halogenflash": "halogen-flash",
        "flash-server": "halogen-flash",
    }
    return aliases.get(raw, raw or "llama.cpp")


def engine_label(engine: str) -> str:
    eng = normalize_engine(engine)
    return {
        "llama.cpp": "llama.cpp",
        "halogen-flash": "Halogen Flash",
    }.get(eng, eng)


def row_engine(row: dict | None) -> str:
    if not row:
        return "llama.cpp"
    if row.get("engine"):
        return normalize_engine(row.get("engine"))
    key = str(row.get("key") or "")
    parts = key.split("|")
    # Legacy: backend|mode|model|kv|c  — Non-legacy: engine|backend|mode|…
    if len(parts) >= 6 and parts[0] not in ("vulkan", "rocm", "cpu"):
        return normalize_engine(parts[0])
    return "llama.cpp"


def engine_tabs_html(engines: list[str], *, include_compare: bool = True) -> str:
    """Global engine filter. Hidden when only one engine (keeps legacy look)."""
    if len(engines) < 2:
        return ""
    buttons = []
    for i, eng in enumerate(engines):
        cls = " active" if i == 0 else ""
        buttons.append(
            f'<button type="button" class="engine-tab{cls}" data-engine="{esc(eng)}" '
            f'aria-pressed="{"true" if i == 0 else "false"}">{esc(engine_label(eng))}</button>'
        )
    if include_compare:
        buttons.append(
            '<button type="button" class="engine-tab" data-engine="__compare__" '
            'aria-pressed="false">Compare</button>'
        )
    return (
        '<nav class="engine-tabs" aria-label="Inference engine">'
        + "".join(buttons)
        + "</nav>"
    )


def engine_switch_script() -> str:
    return """
<script>
(function () {
  const tabs = Array.from(document.querySelectorAll(".engine-tabs .engine-tab"));
  const panels = Array.from(document.querySelectorAll(".engine-panel"));
  if (!tabs.length || !panels.length) return;
  const KEY = "benchEngineTab";
  function activate(id) {
    tabs.forEach((btn) => {
      const on = btn.getAttribute("data-engine") === id;
      btn.classList.toggle("active", on);
      btn.setAttribute("aria-pressed", on ? "true" : "false");
    });
    panels.forEach((p) => {
      p.hidden = p.getAttribute("data-engine") !== id;
    });
    try { localStorage.setItem(KEY, id); } catch (e) {}
    // Re-layout Chart.js canvases that were hidden at init
    if (typeof Chart !== "undefined") {
      Object.values(Chart.instances || {}).forEach((c) => {
        try { c.resize(); } catch (e) {}
      });
    }
  }
  tabs.forEach((btn) => btn.addEventListener("click", () => activate(btn.getAttribute("data-engine"))));
  let initial = tabs[0].getAttribute("data-engine");
  try {
    const saved = localStorage.getItem(KEY);
    if (saved && tabs.some((t) => t.getAttribute("data-engine") === saved)) initial = saved;
  } catch (e) {}
  activate(initial);
})();
</script>
"""


def _compare_catalog(by_engine: dict[str, dict], engines: list[str]) -> list[dict]:
    """Flatten per-engine metrics into picker entries (one row per engine+model)."""
    # key: (engine, model) -> metrics
    bucket: dict[tuple[str, str], dict] = {}

    def slot(eng: str, model: str) -> dict:
        k = (eng, model)
        if k not in bucket:
            bucket[k] = {
                "id": f"{eng}::{model}",
                "engine": eng,
                "engine_label": engine_label(eng),
                "model": model,
                "label": f"{engine_label(eng)} · {display_name(model, 42)}",
                "pp": None,
                "tg": None,
                "pass_at_1": None,
                "pass_at_10": None,
                "n": None,
                "max_c": None,
            }
        return bucket[k]

    for eng in engines:
        payload = by_engine.get(eng) or {}
        for m in payload.get("thr_models") or []:
            name = (m.get("model") or "").strip()
            if not name:
                continue
            e = slot(eng, name)
            e["pp"] = parse_float(m.get("pp"))
            e["tg"] = parse_float(m.get("tg"))
        for r in payload.get("qual_rows") or []:
            name = (r.get("model") or "").strip()
            if not name:
                continue
            e = slot(eng, name)
            p1 = parse_float(r.get("pass_at_1"))
            p10 = parse_float(r.get("pass_at_10"))
            n = r.get("n")
            # Prefer higher-n run when multiple quality rows collide
            prev_n = int(e["n"] or 0)
            cur_n = int(n or 0) if n not in (None, "") else 0
            if e["pass_at_1"] is None or cur_n >= prev_n:
                if p1 is not None:
                    e["pass_at_1"] = p1
                if p10 is not None:
                    e["pass_at_10"] = p10
                if n not in (None, ""):
                    e["n"] = cur_n
        for r in (payload.get("cap_latest") or {}).values():
            if r.get("mode") != "solo" or r.get("skipped") or not r.get("ok"):
                continue
            name = (r.get("model") or "").strip()
            if not name:
                continue
            e = slot(eng, name)
            c = int(r.get("c") or 0)
            if e["max_c"] is None or c > int(e["max_c"] or 0):
                e["max_c"] = c

    entries = list(bucket.values())
    entries.sort(key=lambda x: (x["engine_label"].lower(), display_name(x["model"], 80).lower()))
    return entries


def compare_panel_html(by_engine: dict[str, dict], engines: list[str]) -> str:
    """Interactive model pair picker (any engine × model) + optional same-name overlaps."""
    if len(engines) < 2:
        return ""

    catalog = _compare_catalog(by_engine, engines)
    if not catalog:
        return (
            '<div class="engine-panel" data-engine="__compare__" hidden>'
            '<div class="card"><h2>Compare models</h2>'
            '<p class="meta">No bench data yet to compare.</p></div></div>'
        )

    options = []
    for e in catalog:
        options.append(
            f'<option value="{esc(e["id"])}">{esc(e["label"])}</option>'
        )
    opts_html = "\n".join(options)

    # Default: first entry of eng0 vs first of eng1 (or second overall)
    default_a = catalog[0]["id"]
    default_b = catalog[0]["id"]
    eng0 = engines[0]
    for e in catalog:
        if e["engine"] != eng0:
            default_b = e["id"]
            break
    else:
        if len(catalog) > 1:
            default_b = catalog[1]["id"]

    # Same-name auto rows (kept as secondary section)
    thr_by: dict[str, dict[str, dict]] = {}
    qual_by: dict[str, dict[str, dict]] = {}
    ctx_by: dict[str, dict[str, dict]] = {}
    for eng in engines:
        payload = by_engine.get(eng) or {}
        for m in payload.get("thr_models") or []:
            name = m.get("model") or ""
            if name:
                thr_by.setdefault(name, {})[eng] = m
        for r in payload.get("qual_rows") or []:
            name = r.get("model") or ""
            if name:
                qual_by.setdefault(name, {})[eng] = r
        for r in (payload.get("cap_latest") or {}).values():
            if r.get("mode") != "solo" or r.get("skipped") or not r.get("ok"):
                continue
            name = r.get("model") or ""
            if not name:
                continue
            prev = ctx_by.setdefault(name, {}).get(eng)
            c = int(r.get("c") or 0)
            if prev is None or c > int(prev.get("c") or 0):
                ctx_by[name][eng] = r

    def delta_pct(a, b) -> str:
        af, bf = parse_float(a), parse_float(b)
        if af is None or bf is None or af == 0:
            return "—"
        return f"{((bf - af) / abs(af)) * 100:+.0f}%"

    overlap_rows: list[str] = []
    eng_a, eng_b = engines[0], engines[1]
    for name in sorted(set(thr_by) | set(qual_by) | set(ctx_by), key=lambda n: display_name(n, 40).lower()):
        thr = thr_by.get(name) or {}
        qual = qual_by.get(name) or {}
        ctx = ctx_by.get(name) or {}
        engines_hit = set(thr) | set(qual) | set(ctx)
        if len(engines_hit) < 2:
            continue
        if thr.get(eng_a) or thr.get(eng_b):
            a_tg = (thr.get(eng_a) or {}).get("tg")
            b_tg = (thr.get(eng_b) or {}).get("tg")
            overlap_rows.append(
                f'<tr><td title="{esc(name)}">{esc(display_name(name, 36))}</td>'
                f"<td>Generation tok/s</td>"
                f'<td class="n">{esc(fmt_num(a_tg) if a_tg not in (None, "") else "—")}</td>'
                f'<td class="n">{esc(fmt_num(b_tg) if b_tg not in (None, "") else "—")}</td>'
                f'<td class="n">{esc(delta_pct(a_tg, b_tg))}</td></tr>'
            )
            a_pp = (thr.get(eng_a) or {}).get("pp")
            b_pp = (thr.get(eng_b) or {}).get("pp")
            overlap_rows.append(
                f'<tr><td title="{esc(name)}">{esc(display_name(name, 36))}</td>'
                f"<td>Prompt tok/s</td>"
                f'<td class="n">{esc(fmt_num(a_pp) if a_pp not in (None, "") else "—")}</td>'
                f'<td class="n">{esc(fmt_num(b_pp) if b_pp not in (None, "") else "—")}</td>'
                f'<td class="n">{esc(delta_pct(a_pp, b_pp))}</td></tr>'
            )
        if qual.get(eng_a) or qual.get(eng_b):
            a_p = (qual.get(eng_a) or {}).get("pass_at_1")
            b_p = (qual.get(eng_b) or {}).get("pass_at_1")
            overlap_rows.append(
                f'<tr><td title="{esc(name)}">{esc(display_name(name, 36))}</td>'
                f"<td>HumanEval pass@1</td>"
                f'<td class="n">{esc(fmt_pct(a_p))}</td>'
                f'<td class="n">{esc(fmt_pct(b_p))}</td>'
                f'<td class="n">{esc(delta_pct(a_p, b_p))}</td></tr>'
            )
        if ctx.get(eng_a) or ctx.get(eng_b):
            a_c = (ctx.get(eng_a) or {}).get("c")
            b_c = (ctx.get(eng_b) or {}).get("c")
            overlap_rows.append(
                f'<tr><td title="{esc(name)}">{esc(display_name(name, 36))}</td>'
                f"<td>Max context</td>"
                f'<td class="n">{esc(f"{int(a_c):,}" if a_c else "—")}</td>'
                f'<td class="n">{esc(f"{int(b_c):,}" if b_c else "—")}</td>'
                f'<td class="n">{esc(delta_pct(a_c, b_c))}</td></tr>'
            )

    if overlap_rows:
        overlap_html = (
            '<h3 class="compare-sub">Same name on both engines</h3>'
            "<table><thead><tr>"
            "<th>Model</th><th>Metric</th>"
            f'<th class="n">{esc(engine_label(eng_a))}</th>'
            f'<th class="n">{esc(engine_label(eng_b))}</th>'
            '<th class="n">Δ</th>'
            "</tr></thead><tbody>"
            + "".join(overlap_rows)
            + "</tbody></table>"
        )
    else:
        overlap_html = (
            '<p class="meta compare-sub">No identical model names across engines yet '
            "(use the pickers above for Flash vs Tiel, etc.).</p>"
        )

    catalog_json = json.dumps(catalog, ensure_ascii=False).replace("<", "\\u003c")

    picker = f"""
<div class="compare-pick">
  <label class="compare-field">
    <span>Model A</span>
    <select id="compare-a" aria-label="Model A">{opts_html}</select>
  </label>
  <label class="compare-field">
    <span>Model B</span>
    <select id="compare-b" aria-label="Model B">{opts_html}</select>
  </label>
</div>
<table class="compare-pair"><thead><tr>
  <th>Metric</th>
  <th class="n" id="compare-head-a">A</th>
  <th class="n" id="compare-head-b">B</th>
  <th class="n">Δ (B vs A)</th>
</tr></thead>
<tbody id="compare-pair-body">
  <tr><td colspan="4" class="meta">Pick two models.</td></tr>
</tbody></table>
<script type="application/json" id="compare-catalog">{catalog_json}</script>
<script>
(function () {{
  const catEl = document.getElementById("compare-catalog");
  const selA = document.getElementById("compare-a");
  const selB = document.getElementById("compare-b");
  const body = document.getElementById("compare-pair-body");
  const headA = document.getElementById("compare-head-a");
  const headB = document.getElementById("compare-head-b");
  if (!catEl || !selA || !selB || !body) return;
  const catalog = JSON.parse(catEl.textContent || "[]");
  const byId = Object.fromEntries(catalog.map((e) => [e.id, e]));
  selA.value = {json.dumps(default_a)};
  selB.value = {json.dumps(default_b)};

  function fmtNum(v) {{
    if (v === null || v === undefined || v === "") return "—";
    const n = Number(v);
    if (!Number.isFinite(n)) return "—";
    if (Math.abs(n) >= 1000) return n.toLocaleString(undefined, {{ maximumFractionDigits: 0 }});
    return n.toLocaleString(undefined, {{ maximumFractionDigits: 1, minimumFractionDigits: 1 }});
  }}
  function fmtPct(v) {{
    if (v === null || v === undefined || v === "") return "—";
    const n = Number(v);
    if (!Number.isFinite(n)) return "—";
    return (n * 100).toFixed(1) + "%";
  }}
  function fmtCtx(v) {{
    if (v === null || v === undefined || v === "") return "—";
    return Number(v).toLocaleString();
  }}
  function delta(a, b) {{
    const af = Number(a), bf = Number(b);
    if (!Number.isFinite(af) || !Number.isFinite(bf) || af === 0) return "—";
    const d = ((bf - af) / Math.abs(af)) * 100;
    return (d >= 0 ? "+" : "") + d.toFixed(0) + "%";
  }}
  function shortLabel(e) {{
    if (!e) return "—";
    const m = (e.model || "").replace(/-UD-Q[\\w.]+$/i, "").replace(/-MTP/g, "");
    return (e.engine_label || e.engine) + " · " + (m.length > 28 ? m.slice(0, 27) + "…" : m);
  }}
  function render() {{
    const a = byId[selA.value];
    const b = byId[selB.value];
    headA.textContent = shortLabel(a);
    headB.textContent = shortLabel(b);
    headA.title = a ? (a.engine + " / " + a.model) : "";
    headB.title = b ? (b.engine + " / " + b.model) : "";
    if (!a || !b) {{
      body.innerHTML = '<tr><td colspan="4" class="meta">Pick two models.</td></tr>';
      return;
    }}
    const rows = [
      ["Generation tok/s", fmtNum(a.tg), fmtNum(b.tg), delta(a.tg, b.tg)],
      ["Prompt tok/s", fmtNum(a.pp), fmtNum(b.pp), delta(a.pp, b.pp)],
      ["HumanEval pass@1", fmtPct(a.pass_at_1), fmtPct(b.pass_at_1), delta(a.pass_at_1, b.pass_at_1)],
      ["HumanEval pass@10", fmtPct(a.pass_at_10), fmtPct(b.pass_at_10), delta(a.pass_at_10, b.pass_at_10)],
      ["Max context", fmtCtx(a.max_c), fmtCtx(b.max_c), delta(a.max_c, b.max_c)],
    ];
    body.innerHTML = rows.map(([m, av, bv, d]) =>
      "<tr><td>" + m + '</td><td class="n">' + av + '</td><td class="n">' + bv +
      '</td><td class="n">' + d + "</td></tr>"
    ).join("");
    try {{
      localStorage.setItem("bench-compare-a", selA.value);
      localStorage.setItem("bench-compare-b", selB.value);
    }} catch (_) {{}}
  }}
  try {{
    const sa = localStorage.getItem("bench-compare-a");
    const sb = localStorage.getItem("bench-compare-b");
    if (sa && byId[sa]) selA.value = sa;
    if (sb && byId[sb]) selB.value = sb;
  }} catch (_) {{}}
  selA.addEventListener("change", render);
  selB.addEventListener("change", render);
  render();
}})();
</script>
"""

    return (
        '<div class="engine-panel" data-engine="__compare__" hidden>'
        '<div class="card"><h2>Compare models</h2>'
        '<p class="meta">Pick any two measured models (any engine). '
        "Δ is B relative to A.</p>"
        f"{picker}"
        f"{overlap_html}"
        "</div></div>"
    )


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
.engine-tabs { display: flex; flex-wrap: wrap; gap: .35rem; margin: 0 0 1.15rem;
  padding: .35rem; background: #171a21; border: 1px solid #252a35; border-radius: 10px; }
.engine-tabs button { appearance: none; border: none; cursor: pointer; font: inherit;
  color: #9aa0a6; background: transparent; padding: .45rem .85rem; border-radius: 7px;
  font-size: .88rem; font-weight: 500; }
.engine-tabs button:hover { color: #e8eaed; background: #1e2330; }
.engine-tabs button.active { color: #e8eaed; background: #2a3444; }
.engine-panel[hidden] { display: none !important; }
.engine-badge { display: inline-block; font-size: .72rem; font-weight: 600;
  padding: .1rem .4rem; border-radius: 4px; background: #1a2e24; color: #7ddea5;
  margin-left: .35rem; vertical-align: middle; }
.compare-pick { display: grid; grid-template-columns: 1fr 1fr; gap: .75rem;
  margin: 0 0 1rem; }
@media (max-width: 640px) { .compare-pick { grid-template-columns: 1fr; } }
.compare-field { display: flex; flex-direction: column; gap: .3rem; font-size: .82rem;
  color: #9aa0a6; }
.compare-field select { appearance: none; width: 100%; padding: .55rem .7rem;
  border-radius: 8px; border: 1px solid #252a35; background: #12151c; color: #e8eaed;
  font: inherit; cursor: pointer; }
.compare-field select:focus { outline: 2px solid #3d4f6f; outline-offset: 1px; }
.compare-pair { margin-bottom: 1.25rem; }
.compare-sub { margin-top: 1.25rem; }
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


def host_one_liner(host: dict | None, engines: list[str] | None = None) -> str:
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
    eng_list = engines or []
    if not eng_list:
        default = normalize_engine(host.get("engine_default") or "llama.cpp")
        eng_list = [default]
    if len(eng_list) == 1 and eng_list[0] == "llama.cpp":
        eng_bit = f'llama.cpp <code>{esc(commit)}</code>'
    elif len(eng_list) == 1:
        eng_bit = esc(engine_label(eng_list[0]))
    else:
        eng_bit = " · ".join(esc(engine_label(e)) for e in eng_list)
    return (
        f'<p class="host-line">{esc(gpu)} · {esc(ram_s)} · {esc(backend)} · '
        f'{eng_bit} · '
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


def fmt_dur(sec: Any) -> str:
    if sec is None or sec == "" or sec == "—":
        return "—"
    try:
        s = float(sec)
    except (TypeError, ValueError):
        return "—"
    if s < 90:
        return f"{s:.0f}s"
    if s < 3600:
        return f"{s / 60:.0f} min"
    return f"{s / 3600:.1f} h"


def dur_explain(row: dict) -> str:
    """Plain-language tooltip: one run → all pass@k; time is not per-k."""
    n = row.get("n_samples")
    gen = row.get("generate_s")
    wall = row.get("elapsed_s")
    bits = [
        "Wall time for this whole HumanEval run (generate all samples + score).",
        "pass@1 and pass@10 are computed from the same samples — not separate timed stages.",
    ]
    if n is not None:
        bits.append(f"This run used n={n} sample(s) per problem.")
        try:
            ni = int(n)
            if ni >= 10:
                bits.append("n≥10 is why pass@10 is filled and why it took longer than an n=1 run.")
            elif ni == 1:
                bits.append("n=1 → only pass@1; run pass@10 with --n 10 (about 10× generate time).")
        except (TypeError, ValueError):
            pass
    if gen is not None and wall is not None and float(wall) > float(gen) + 5:
        bits.append(f"Generate ≈ {fmt_dur(gen)}; total including eval ≈ {fmt_dur(wall)}.")
    return " ".join(bits)


def qual_pass_ks(row: dict) -> dict[str, Any]:
    """Normalize pass@k map from a quality latest row."""
    pks = dict(row.get("pass_ks") or {})
    if not pks:
        if row.get("pass_at_1") is not None:
            pks["pass@1"] = row["pass_at_1"]
        if row.get("pass_at_10") is not None:
            pks["pass@10"] = row["pass_at_10"]
        # also flatten metrics if present
        for k, v in (row.get("metrics") or {}).items():
            if isinstance(k, str) and k.startswith("pass@"):
                pks[k] = v
    return pks


def qual_table_html(qual_rows: list, *, fmt_stamp) -> str:
    # Discover pass@k columns across all rows (grows with n=10, n=100, …)
    all_ks: list[str] = []
    seen = set()
    for r in qual_rows or []:
        for k in qual_pass_ks(r):
            if k not in seen:
                seen.add(k)
                all_ks.append(k)
    all_ks.sort(key=lambda s: int(s.split("@", 1)[1]) if s.split("@", 1)[-1].isdigit() else 0)
    if not all_ks:
        all_ks = ["pass@1", "pass@10"]

    # Best pass@1 for subtle highlight (same style family for all pass cols)
    best_p1 = None
    for r in qual_rows or []:
        v = parse_float(qual_pass_ks(r).get("pass@1"))
        if v is None:
            continue
        if best_p1 is None or v > best_p1:
            best_p1 = v

    rows = []
    if qual_rows:
        for r in qual_rows:
            suite = r.get("suite") or "—"
            suite_label = "HumanEval" if "humaneval" in str(suite).lower() else suite
            full = r.get("model") or "—"
            pks = qual_pass_ks(r)
            p1 = parse_float(pks.get("pass@1"))
            row_best = best_p1 is not None and p1 is not None and abs(p1 - best_p1) < 1e-9
            cells = []
            for k in all_ks:
                val = pks.get(k)
                shown = fmt_pct(val) if parse_float(val) is not None else "—"
                cls = "n best" if (row_best and k == "pass@1") else "n"
                cells.append(f'<td class="{cls}">{shown}</td>')
            n_s = r.get("n_samples")
            n_label = esc(str(n_s)) if n_s is not None else "—"
            dur = fmt_dur(r.get("elapsed_s") if r.get("elapsed_s") is not None else r.get("generate_s"))
            dur_tip = dur_explain(r)
            rows.append(
                f"<tr><td>{esc(suite_label)}</td>"
                f'<td title="{esc(full)}">{esc(display_name(full, 40))}</td>'
                + "".join(cells)
                + f'<td class="n meta">{n_label}</td>'
                f'<td class="n meta">{tip(dur, dur_tip)}</td>'
                f'<td class="meta">{esc(fmt_stamp(r.get("stamp") or ""))}</td></tr>'
            )
    else:
        cols = 4 + len(all_ks)
        rows.append(f'<tr><td colspan="{cols}" class="meta">No code-quality runs yet.</td></tr>')

    head_ks = []
    for k in all_ks:
        kn = k.split("@", 1)[-1]
        explain = (
            f"Share of problems solved within {kn} sample(s). "
            "Blank if this run used fewer samples."
        )
        head_ks.append(f'<th class="n">{tip(k, explain)}</th>')
    return (
        "<table><thead><tr>"
        "<th>Benchmark</th><th>Model</th>"
        + "".join(head_ks)
        + f'<th class="n">{tip("n", "Samples drawn per problem. pass@k needs n≥k.")}</th>'
        + f'<th class="n">{tip("Duration", "Time for the whole run (all n samples + eval). Not a separate timer per pass@k — those scores come from the same run.")}</th>'
        + "<th>Measured</th></tr></thead><tbody>"
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


def overview_chart_script(thr_chart: dict, canvas_id: str = "chart-thr") -> str:
    data = json.dumps({"throughput": thr_chart}, ensure_ascii=False).replace("<", "\\u003c")
    sid = f"bench-thr-data-{canvas_id}"
    return f"""
<script id="{esc(sid)}" type="application/json">{data}</script>
<script>
(function () {{
  const raw = document.getElementById({json.dumps(sid)});
  const canvas = document.getElementById({json.dumps(canvas_id)});
  if (!raw || !canvas || typeof Chart === "undefined") return;
  let DATA;
  try {{ DATA = JSON.parse(raw.textContent); }} catch (e) {{ return; }}
  const thr = DATA.throughput || {{}};
  if (!(thr.labels || []).length) return;
  const tick = {{ color: "#9aa0a6" }};
  const grid = {{ color: "#2a2e37" }};
  new Chart(canvas, {{
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

def context_chart_script(
    cap_chart: dict,
    *,
    model_sel: str = "cap-model",
    y_sel: str = "cap-y",
    canvas_id: str = "chart-cap",
    fallback_id: str = "cap-fallback",
) -> str:
    data = json.dumps({"capacity": cap_chart}, ensure_ascii=False).replace("<", "\\u003c")
    sid = f"bench-cap-data-{canvas_id}"
    return f"""
<script id="{esc(sid)}" type="application/json">{data}</script>
<script>
(function () {{
  const raw = document.getElementById({json.dumps(sid)});
  const sel = document.getElementById({json.dumps(model_sel)});
  const ySel = document.getElementById({json.dumps(y_sel)});
  const canvas = document.getElementById({json.dumps(canvas_id)});
  const fallback = document.getElementById({json.dumps(fallback_id)});
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


def _slug(engine: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", normalize_engine(engine)).strip("-") or "engine"


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
    by_engine: dict | None = None,
    engines: list | None = None,
) -> list[str]:
    """Write overview + detail pages. Returns list of written paths."""
    written: list[str] = []

    if not by_engine:
        eng = "llama.cpp"
        if host and host.get("engine_default"):
            eng = normalize_engine(host.get("engine_default"))
        by_engine = {
            eng: {
                "thr_models": thr_models or [],
                "qual_rows": qual_rows or [],
                "cap_latest": cap_latest or {},
                "thr_chart": thr_chart or {},
                "cap_chart": cap_chart or {},
                "capacity_grid_html": capacity_grid_html or "",
                "cap_has_power": cap_has_power,
            }
        }
    engines = [normalize_engine(e) for e in (engines or list(by_engine.keys()))]
    if not engines:
        engines = ["llama.cpp"]
    engines = sorted(engines, key=lambda e: (0 if e == "llama.cpp" else 1, e))

    tabs = engine_tabs_html(engines, include_compare=len(engines) >= 2)
    switch = engine_switch_script() if len(engines) >= 2 else ""

    overview_panels: list[str] = []
    for i, eng in enumerate(engines):
        payload = by_engine.get(eng) or {}
        slug = _slug(eng)
        thr_m = payload.get("thr_models") or []
        qual = payload.get("qual_rows") or []
        cap = payload.get("cap_latest") or {}
        thr_c = payload.get("thr_chart") or {}
        canvas = f"chart-thr-{slug}"
        hidden = "" if i == 0 else " hidden"
        overview_panels.append(
            f'<div class="engine-panel" data-engine="{esc(eng)}"{hidden}>'
            f"{verdict_cards(thr_m, qual, cap)}"
            f'<div class="card" id="charts-{esc(slug)}">'
            f"<h2>Prompt vs generation</h2>"
            f'<p class="meta">Tokens per second with the model alone on the server. Higher is better.'
            f' <span class="engine-badge">{esc(engine_label(eng))}</span></p>'
            f'<div class="chart-box"><div class="chart-wrap"><canvas id="{esc(canvas)}"></canvas></div></div>'
            f"</div>"
            f"{thr_table_html(thr_m)}"
            f'<div class="card" id="quality-preview-{esc(slug)}">'
            f"<h2>Code correctness</h2>"
            f'<p class="meta">HumanEval — code only, not chat quality. <a href="quality.html">→ Quality page</a>'
            f" · Duration = whole run (see n); pass@1/@10 share the same samples when n≥10.</p>"
            f"{qual_table_html(qual, fmt_stamp=fmt_stamp)}"
            f"</div>"
            f"{overview_chart_script(thr_c, canvas)}"
            f"</div>"
        )
    overview_panels.append(compare_panel_html(by_engine, engines))

    body = f"""
<header>
<h1>LLM bench results</h1>
<p class="lede">Speed, longest usable context, and code correctness — measured on this host.</p>
</header>
{host_one_liner(host, engines)}
{tabs}
{"".join(overview_panels)}
<p class="links-row">
  <a href="context.html">Context &amp; memory →</a>
  <a href="quality.html">Quality details →</a>
  <a href="host.html">Host &amp; build →</a>
  <a href="scheduling/latest/compare.html">Under-load sweeps →</a>
</p>
{switch}
"""
    overview = shell("LLM Bench — Overview", "overview", body, chart_js=True)
    path = os.path.join(out_root, "index.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(overview)
    written.append(path)
    alias = os.path.join(out_root, "pages-index.html")
    with open(alias, "w", encoding="utf-8") as f:
        f.write(overview)
    written.append(alias)

    ctx_panels: list[str] = []
    for i, eng in enumerate(engines):
        payload = by_engine.get(eng) or {}
        slug = _slug(eng)
        cap = payload.get("cap_latest") or {}
        cap_c = payload.get("cap_chart") or {}
        power = bool(payload.get("cap_has_power", cap_has_power))
        power_opt = (
            '<option value="power_w">GPU watts (avg)</option>' if power else ""
        )
        grid = payload.get("capacity_grid_html") or capacity_grid_html or (
            '<p class="meta">No capacity grid yet.</p>'
        )
        if i > 0 and not payload.get("capacity_grid_html"):
            grid = (
                f'<p class="meta">Ledger cells for {esc(engine_label(eng))} — '
                "see capacity/latest/compare.md for the full grid.</p>"
            )
        model_sel = f"cap-model-{slug}"
        y_sel = f"cap-y-{slug}"
        canvas = f"chart-cap-{slug}"
        fallback = f"cap-fallback-{slug}"
        hidden = "" if i == 0 else " hidden"
        ctx_panels.append(
            f'<div class="engine-panel" data-engine="{esc(eng)}"{hidden}>'
            f'<div class="card">'
            f"<h2>Longest context that fits "
            f'<span class="engine-badge">{esc(engine_label(eng))}</span></h2>'
            f"{max_ctx_one_per_model(cap, cap_metrics_fn)}"
            f"</div>"
            f'<div class="card">'
            f"<h2>Prompt cost vs context</h2>"
            f'<p class="meta">Pick a model. Lower line = faster prompt processing as context grows.</p>'
            f'<label class="meta" for="{esc(model_sel)}">Model </label>'
            f'<select id="{esc(model_sel)}" class="model-pick"></select>'
            f'<label class="meta" for="{esc(y_sel)}">Y axis </label>'
            f'<select id="{esc(y_sel)}" class="model-pick">'
            f'<option value="prefill_s" selected>Prompt time (s)</option>'
            f'<option value="prefill_tok_s">Prompt speed (tok/s)</option>'
            f'<option value="gtt_gib">Memory (GiB)</option>'
            f"{power_opt}"
            f"</select>"
            f'<div class="chart-box"><div class="chart-wrap tall">'
            f'<canvas id="{esc(canvas)}"></canvas></div>'
            f'<div id="{esc(fallback)}" class="meta" hidden></div></div>'
            f"</div>"
            f'<details class="panel">'
            f"<summary>Full context × KV grid &amp; dual instances</summary>"
            f'<p class="meta">Lab detail — every measured cell. Prefer the summary table above for decisions.</p>'
            f"{grid}"
            f"</details>"
            f"{context_chart_script(cap_c, model_sel=model_sel, y_sel=y_sel, canvas_id=canvas, fallback_id=fallback)}"
            f"</div>"
        )
    if len(engines) >= 2:
        ctx_panels.append(compare_panel_html(by_engine, engines))

    ctx_body = f"""
<header>
<h1>Context &amp; memory</h1>
<p class="lede">How far context can grow, and what prompt processing costs at that point.</p>
</header>
{host_one_liner(host, engines)}
{tabs}
{"".join(ctx_panels)}
<p class="more"><a href="capacity/latest/compare.md">→ Capacity ledger (markdown)</a></p>
{switch}
"""
    path = os.path.join(out_root, "context.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(shell("LLM Bench — Context", "context", ctx_body, chart_js=True))
    written.append(path)

    q_panels: list[str] = []
    for i, eng in enumerate(engines):
        payload = by_engine.get(eng) or {}
        qual = payload.get("qual_rows") or []
        hidden = "" if i == 0 else " hidden"
        q_panels.append(
            f'<div class="engine-panel" data-engine="{esc(eng)}"{hidden}>'
            f'<div class="card">'
            f"<h2>HumanEval "
            f'<span class="engine-badge">{esc(engine_label(eng))}</span></h2>'
            f'<p class="meta"><strong>pass@k</strong> = share of problems solved within k samples '
            f"(from <em>one</em> run with <code>n≥k</code>). "
            f"<strong>Duration</strong> is wall time for that whole run — not “time for pass@1” vs “time for pass@10”. "
            f"Hover Duration for details. Higher % is better; best pass@1 is highlighted.</p>"
            f"{qual_table_html(qual, fmt_stamp=fmt_stamp)}"
            f'<p class="more"><a href="quality/latest/compare.md">→ Per-run details</a></p>'
            f"</div></div>"
        )
    if len(engines) >= 2:
        q_panels.append(compare_panel_html(by_engine, engines))

    q_body = f"""
<header>
<h1>Code correctness</h1>
<p class="lede">HumanEval-style Python coding problems. Measures whether generated code passes unit tests — not chat style, reasoning prose, or speed.</p>
</header>
{host_one_liner(host, engines)}
{tabs}
{"".join(q_panels)}
{switch}
"""
    path = os.path.join(out_root, "quality.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(shell("LLM Bench — Quality", "quality", q_body))
    written.append(path)

    eng_note = (
        "Results only compare fairly on the same machine, driver, and engine build."
    )
    h_body = f"""
<header>
<h1>Host &amp; build</h1>
<p class="lede">{esc(eng_note)}</p>
</header>
{host_one_liner(host, engines)}
{host_html_card}
{fingerprint_html}
"""
    path = os.path.join(out_root, "host.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(shell("LLM Bench — Host", "host", h_body))
    written.append(path)

    return written
