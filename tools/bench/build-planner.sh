#!/usr/bin/env bash
# Build interactive sticky planner (capacity + sched ★) → output/bench/planner.html
# Published to docs/ via ./bench publish.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/python.sh
source "$SCRIPT_DIR/lib/python.sh"

OUT="$PROJECT_ROOT/output/bench"
SCH="$OUT/scheduling/latest"
SUMMARY="$SCH/summary.json"
HOST_JSON="$OUT/host.json"
CELLS="$OUT/capacity/cells.jsonl"
PLANNER="$OUT/planner.html"

mkdir -p "$OUT" "$SCH"

bench_python - "$SUMMARY" "$PLANNER" "$HOST_JSON" "$CELLS" <<'PY'
import json, os, re, sys
from pathlib import Path

summary_path, out_path, host_path, cells_path = sys.argv[1:5]

recs = []
if os.path.isfile(summary_path):
    with open(summary_path, encoding="utf-8") as f:
        data = json.load(f)
    recs = data.get("recommendations") or []

host = {
    "gtt_gib": 100.0,
    "ram_gib": 124.0,
    "os_reserve_gib": 16.0,
    "kv_gib_per_token_slot": 30.0 / (262144 * 4),
}
if os.path.isfile(host_path):
    with open(host_path, encoding="utf-8") as f:
        hj = json.load(f)
    # probe-host uses various shapes — be tolerant
    gtt = hj.get("gtt_total_gib") or hj.get("gtt_gib")
    ram = hj.get("ram_gib") or hj.get("mem_total_gib")
    if gtt is None and hj.get("gtt_total_mib"):
        gtt = float(hj["gtt_total_mib"]) / 1024.0
    if ram is None and hj.get("ram_mib"):
        ram = float(hj["ram_mib"]) / 1024.0
    if gtt is None and hj.get("gtt_total_mb"):
        gtt = float(hj["gtt_total_mb"]) / 1024.0
    if ram is None and hj.get("mem_total_mb"):
        ram = float(hj["mem_total_mb"]) / 1024.0
    if gtt:
        host["gtt_gib"] = float(gtt)
    if ram:
        host["ram_gib"] = float(ram)

root = Path(out_path).resolve().parents[2]  # …/output/bench/planner.html → repo root
models_dir = root / "models"

KV_RANK = {"q8_0": 4, "q5_1": 3, "q5_0": 2, "q4_0": 1, "q4_1": 1, "iq4_nl": 1, "f16": 0}

def parse_ini_model_paths(path: Path):
    """section → {model, mmproj} paths from INI (container /models/… or relative)."""
    if not path.is_file():
        return {}
    out = {}
    cur = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1].strip()
            out.setdefault(cur, {})
            continue
        if cur is None or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip()
        if k in ("model", "mmproj"):
            out[cur][k] = v
    return out

def host_gguf_path(rel: str):
    if not rel:
        return None
    p = rel
    if p.startswith("/models/"):
        p = p[len("/models/"):]
    elif p.startswith("models/"):
        p = p[len("models/"):]
    return models_dir / p

def gguf_bytes(path: Path) -> int:
    """Single file or sum of multipart shards *-00001-of-N.gguf …"""
    if path is None:
        return 0
    if path.is_file():
        name = path.name
        m = re.match(r"^(.*?)-(\d+)-of-(\d+)\.gguf$", name, re.I)
        if m:
            stem, idx, total = m.group(1), int(m.group(2)), int(m.group(3))
            total_b = 0
            width = len(m.group(2))
            for i in range(1, total + 1):
                shard = path.with_name(f"{stem}-{i:0{width}d}-of-{total:0{width}d}.gguf")
                if not shard.is_file():
                    return path.stat().st_size if i == 1 else total_b
                total_b += shard.stat().st_size
            return total_b
        return path.stat().st_size
    return 0

def discover_weights_gib() -> dict:
    """Build section→GiB from live INIs + on-disk GGUF sizes (no hardcoded model names)."""
    weights = {}
    ini_files = [
        root / "models.ini",
        root / "models-coder.ini",
        root / "models-lab.ini",
        root / "models-bench.ini",
    ]
    for ini in ini_files:
        for section, keys in parse_ini_model_paths(ini).items():
            total = 0
            for key in ("model", "mmproj"):
                rel = keys.get(key)
                if not rel:
                    continue
                hp = host_gguf_path(rel)
                total += gguf_bytes(hp) if hp else 0
            if total > 0:
                gib = round(total / (1024.0 ** 3), 2)
                if section not in weights or gib > weights[section]:
                    weights[section] = gib
    # Also index by GGUF stem for fuzzy JS fallback
    if models_dir.is_dir():
        for p in models_dir.rglob("*.gguf"):
            name = p.name
            if re.search(r"-0*\d*[2-9]\d*-of-\d+\.gguf$", name, re.I):
                # skip non-first multipart shards (…-00002-of-… etc.)
                m = re.search(r"-(\d+)-of-(\d+)\.gguf$", name, re.I)
                if m and int(m.group(1)) != 1:
                    continue
            if "mmproj" in name.lower() or name.lower().startswith("mtp-"):
                continue
            stem = re.sub(r"-\d+-of-\d+\.gguf$", "", name, flags=re.I)
            stem = stem[: -5] if stem.lower().endswith(".gguf") else stem
            if name.lower().endswith(".gguf") and stem == name:
                stem = name[:-5]
            b = gguf_bytes(p)
            if b <= 0:
                continue
            gib = round(b / (1024.0 ** 3), 2)
            if stem not in weights or gib > weights[stem]:
                weights[stem] = gib
    return weights

WEIGHTS = discover_weights_gib()

def load_capacity(path: str):
    """Per model: solo/dual max ok c + best kv at that c."""
    cap = {}
    if not os.path.isfile(path):
        return cap
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("skipped") and not r.get("ok"):
                continue
            if not r.get("ok"):
                continue
            model = r.get("model")
            mode = r.get("mode") or "solo"
            kv = r.get("kv") or ""
            try:
                c = int(r.get("c") or 0)
            except (TypeError, ValueError):
                continue
            if not model or c <= 0:
                continue
            entry = cap.setdefault(model, {"solo": {}, "dual": {}})
            bucket = entry.setdefault(mode if mode in ("solo", "dual") else "solo", {})
            prev = bucket.get(kv)
            if prev is None or c > prev:
                bucket[kv] = c
            # Fallback weight from low-ctx GTT peak if disk size unknown
            peak = (r.get("metrics_peak") or {}).get("gtt_used_mb")
            if peak and model not in WEIGHTS and mode == "solo" and c <= 65536:
                WEIGHTS[model] = round(float(peak) / 1024.0, 1)
    out = {}
    for model, modes in cap.items():
        sm = {}
        for mode, by_kv in modes.items():
            if not by_kv:
                continue
            best_c = max(by_kv.values())
            candidates = [kv for kv, c in by_kv.items() if c == best_c]
            best_kv = max(candidates, key=lambda k: KV_RANK.get(k, 0))
            sm[mode] = {
                "max_c": best_c,
                "kv": best_kv,
                "by_kv": by_kv,
            }
        out[model] = sm
    return out

capacity = load_capacity(cells_path)

# Sticky advice: high-RAM hosts usually want 2 containers (models ~256k context ceiling),
# not one oversized sticky. Don't push dual on tight hosts without dual capacity proof.
any_dual_ok = any((v.get("dual") or {}).get("max_c") for v in capacity.values())
any_solo_ok = any((v.get("solo") or {}).get("max_c") for v in capacity.values())
ram = float(host["ram_gib"])
gtt = float(host["gtt_gib"])
high_mem = ram >= 64.0 or gtt >= 48.0
allow_dual = bool(any_dual_ok) or high_mem
if any_solo_ok and not any_dual_ok and not high_mem:
    allow_dual = False
# Prefer 2 stickys whenever allowed on high-mem (256k ceiling → second model beats one sticky)
# or whenever dual capacity already proved fit.
prefer_dual = allow_dual and (high_mem or any_dual_ok)

if prefer_dual and high_mem:
    reason = (
        "High RAM/GTT: prefer 2 stickys (chat+coder). One model tops out near ~256k context — "
        "a second container uses headroom better than one mega sticky."
    )
elif prefer_dual and any_dual_ok:
    reason = "Dual capacity passed — 2 stickys are feasible; prefer chat+coder over one mega sticky."
elif not allow_dual:
    reason = (
        "No dual capacity ok on this host class — stay on 1 sticky "
        "(or run ./bench capacity dual after freeing GTT)."
    )
else:
    reason = "1 sticky is fine; switch to 2 stickys only if dual capacity / GTT allows."

advice = {
    "prefer_mode": "dual" if prefer_dual else "solo",
    "allow_dual": allow_dual,
    "prefer_dual": prefer_dual,
    "any_dual_ok": any_dual_ok,
    "any_solo_ok": any_solo_ok,
    "high_mem": high_mem,
    "reason": reason,
}

payload = {
    "host": host,
    "weights_gib": WEIGHTS,
    "recommendations": recs,
    "capacity": capacity,
    "advice": advice,
}

html = r'''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Bench planner — sticky recommendations</title>
<style>
:root { color-scheme: dark; --bg:#12141a; --card:#1a1d24; --line:#2a2e37; --muted:#9aa0a6; --text:#e8eaed; --accent:#8ab4f8; --ok:#7ddea5; --warn:#f0c674; --bad:#f0a0a0; }
* { box-sizing: border-box; }
body { font: 15px/1.5 system-ui, sans-serif; margin: 0; background: var(--bg); color: var(--text); }
main { max-width: 1100px; margin: 0 auto; padding: 1.5rem 1.25rem 3rem; }
h1 { font-size: 1.35rem; margin: 0 0 .35rem; }
h2 { font-size: 1.05rem; margin: 0 0 .75rem; color: #c4c7cc; }
.meta { color: var(--muted); font-size: .9rem; }
a { color: var(--accent); }
.grid { display: grid; gap: 1rem; grid-template-columns: 1fr; }
@media (min-width: 900px) { .grid { grid-template-columns: 1fr 1fr; } }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 1rem 1.15rem; }
label { display: block; font-size: .8rem; color: var(--muted); margin: .55rem 0 .2rem; }
select, input[type=number] { width: 100%; background: #12141a; color: var(--text); border: 1px solid var(--line); border-radius: 6px; padding: .45rem .55rem; font: inherit; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: .75rem; }
.modes { display: flex; flex-wrap: wrap; gap: .5rem; margin: .5rem 0 0; }
.modes button { background: #12141a; color: var(--text); border: 1px solid var(--line); border-radius: 999px; padding: .35rem .8rem; cursor: pointer; font: inherit; }
.modes button.active { border-color: var(--accent); color: var(--accent); }
.kpi { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: .5rem; margin: .75rem 0; }
.kpi div { background: #12141a; border-radius: 6px; padding: .55rem .65rem; }
.kpi strong { display: block; font-size: 1.0rem; font-variant-numeric: tabular-nums; word-break: break-all; }
.kpi span { color: var(--muted); font-size: .75rem; }
.ok { color: var(--ok); }
.warn { color: var(--warn); }
.bad { color: var(--bad); }
pre { background: #12141a; border-radius: 6px; padding: .75rem .9rem; overflow-x: auto; font: .8rem/1.4 ui-monospace, monospace; margin: .5rem 0 0; white-space: pre-wrap; }
ul.notes { margin: .4rem 0 0; padding-left: 1.1rem; color: var(--muted); font-size: .9rem; }
.bar { height: 10px; background: #12141a; border-radius: 999px; overflow: hidden; margin: .5rem 0; }
.bar > i { display: block; height: 100%; background: var(--accent); width: 0; }
.bar > i.warn { background: var(--warn); }
.bar > i.bad { background: var(--bad); }
table { width: 100%; border-collapse: collapse; font-size: .85rem; margin-top: .5rem; }
th, td { padding: .35rem .45rem; border-bottom: 1px solid var(--line); text-align: left; }
th { color: var(--muted); font-weight: 600; }
td.n, th.n { text-align: right; font-variant-numeric: tabular-nums; font-family: ui-monospace, monospace; }
button.copy, button.dl { background:#2a3444;color:var(--text);border:1px solid var(--line);border-radius:6px;padding:.4rem .7rem;cursor:pointer;font:inherit;margin-right:.4rem; }
.modes button:disabled { opacity: .45; cursor: not-allowed; }
.banner { background: #12141a; border: 1px solid var(--line); border-radius: 8px; padding: .75rem 1rem; margin: 0 0 1rem; font-size: .92rem; }
.banner.prefer { border-color: var(--ok); }
.banner.warn { border-color: var(--warn); }
.cap-pill { display:inline-block; font-size:.75rem; padding:.1rem .45rem; border-radius:999px; border:1px solid var(--line); margin-left:.35rem; }
.cap-pill.ok { border-color: var(--ok); color: var(--ok); }
.cap-pill.bad { border-color: var(--bad); color: var(--bad); }
</style></head><body>
<main>
  <h1>Recommendation planner</h1>
  <p class="meta">Defaults from host RAM/GTT + capacity dual: high-memory hosts prefer <strong>2 stickys</strong>
  (models top out near ~256k context — better a second container than one mega sticky).
  Tight hosts without dual capacity stay on <strong>1 sticky</strong>.
  Sched ★ + capacity max <code>c</code>. Pages = view/copy — apply on the host.
  <a href="index.html">Overview</a> · <a href="ops.html">Ops</a> · <a href="capacity/latest/compare.md">Capacity</a> · <a href="scheduling/latest/compare.html">Sweeps</a></p>
  <div class="banner" id="adviceBanner"></div>

  <div class="grid">
    <section class="card">
      <h2>Scenario</h2>
      <div class="modes" id="modes">
        <button type="button" data-mode="solo">1 sticky</button>
        <button type="button" data-mode="dual" id="btnDual">2 stickys (chat + coder)</button>
        <button type="button" data-mode="lab">Lab only</button>
      </div>
      <label for="chatModel">Chat / sticky model</label>
      <select id="chatModel"></select>
      <div class="coder-wrap" id="coderWrap">
        <label for="coderModel">Coder sticky model</label>
        <select id="coderModel"></select>
      </div>
      <div class="row">
        <div>
          <label for="npChat">np chat override</label>
          <input id="npChat" type="number" min="1" max="8" step="1" placeholder="use ★">
        </div>
        <div>
          <label for="npCoder">np coder override</label>
          <input id="npCoder" type="number" min="1" max="8" step="1" placeholder="use ★">
        </div>
      </div>
      <div class="row">
        <div>
          <label for="cChat">c chat override</label>
          <input id="cChat" type="number" min="4096" max="262144" step="4096" placeholder="★ / capacity">
        </div>
        <div>
          <label for="cCoder">c coder override</label>
          <input id="cCoder" type="number" min="4096" max="262144" step="4096" placeholder="★ / capacity">
        </div>
      </div>
      <p class="meta" style="margin-top:.75rem">Empty overrides → sched ★, capped by capacity solo max <code>c</code> when available.</p>
    </section>

    <section class="card">
      <h2>Live recommendation</h2>
      <div id="status" class="meta"></div>
      <div class="kpi" id="kpis"></div>
      <div class="bar" title="Estimated GTT use"><i id="gttBar"></i></div>
      <ul class="notes" id="notes"></ul>
      <h2 style="margin-top:1.1rem">INI snippet</h2>
      <pre id="snippet"></pre>
      <p class="meta" style="margin-top:.6rem">
        <button type="button" class="copy" id="copyBtn">Copy snippet</button>
        <button type="button" class="dl" id="dlPlan">Download plan.json</button>
      </p>
      <h2 style="margin-top:1.1rem">Apply on host</h2>
      <pre id="applyCmd"></pre>
      <p class="meta"><button type="button" class="copy" id="copyApply">Copy apply command</button></p>
    </section>
  </div>

  <section class="card" style="margin-top:1rem">
    <h2>Capacity (ok cells)</h2>
    <p class="meta">Max context that loaded + streamed. Dual = two containers, same model.</p>
    <table>
      <thead><tr><th>Model</th><th>solo max c</th><th>solo kv</th><th>dual max c</th><th>dual kv</th></tr></thead>
      <tbody id="capTable"></tbody>
    </table>
  </section>

  <section class="card" style="margin-top:1rem">
    <h2>Sched ★ catalogue</h2>
    <p class="meta">Missing ★ = sweep not run yet.</p>
    <table>
      <thead><tr><th>Model</th><th class="n">np</th><th class="n">ub</th><th class="n">b</th><th class="n">c</th><th>cont</th><th class="n">decode ms</th><th class="n">GiB</th></tr></thead>
      <tbody id="catalog"></tbody>
    </table>
  </section>
</main>
<script>
const DATA = __DATA__;

function dash(v) {
  return v === null || v === undefined || v === "" || v === "—" || v === "\u2014";
}
function num(v, fallback) {
  if (dash(v)) return fallback;
  const n = Number(String(v).replace(/[^0-9.]/g, ""));
  return Number.isFinite(n) ? n : fallback;
}
function recFor(name) {
  return (DATA.recommendations || []).find(r => r.model === name) || null;
}
function capFor(name) {
  return (DATA.capacity || {})[name] || {};
}
function weightGiB(name) {
  // From on-disk GGUF sizes / INI paths (built at index time). Last resort ≈24 GiB.
  if (DATA.weights_gib[name] != null) return DATA.weights_gib[name];
  const base = name.replace(/-VL$/, "");
  if (base !== name && DATA.weights_gib[base] != null) return DATA.weights_gib[base] + 1;
  return 24;
}
function kvGiB(c, np) {
  return c * np * DATA.host.kv_gib_per_token_slot;
}
function models() {
  const fromRec = (DATA.recommendations || []).map(r => r.model);
  const fromW = Object.keys(DATA.weights_gib);
  const fromCap = Object.keys(DATA.capacity || {});
  return [...new Set([...fromCap, ...fromRec, ...fromW])].sort();
}
function fillSelect(sel, preferred) {
  const list = models();
  sel.innerHTML = "";
  for (const m of list) {
    const o = document.createElement("option");
    o.value = m;
    const solo = (capFor(m).solo || {}).max_c;
    o.textContent = solo ? `${m}  (solo≤${solo})` : m;
    sel.appendChild(o);
  }
  if (preferred && list.includes(preferred)) sel.value = preferred;
  else if (list.length) sel.selectedIndex = 0;
}
function esc(s) {
  return String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
}
function defaultC(model) {
  const r = recFor(model) || {};
  const solo = (capFor(model).solo || {}).max_c;
  const dual = (capFor(model).dual || {}).max_c;
  let c = num(r.best_c, solo || 131072);
  if (mode === "dual" && dual) {
    // Prefer proven dual ceiling; don't default above what dual capacity passed
    c = Math.min(c, dual);
    if (!solo && dash(r.best_c)) c = dual;
  } else if (solo && c > solo) {
    c = solo;
  }
  if (!solo && !dual && dash(r.best_c)) c = 131072;
  return c;
}
function defaultKv(model) {
  return (capFor(model).solo || {}).kv || "q8_0";
}
function effective(model, role) {
  const r = recFor(model) || {};
  const npEl = role === "chat" ? document.getElementById("npChat") : document.getElementById("npCoder");
  const cEl = role === "chat" ? document.getElementById("cChat") : document.getElementById("cCoder");
  const npO = npEl.value === "" ? null : Number(npEl.value);
  const cO = cEl.value === "" ? null : Number(cEl.value);
  const np = (npO != null && Number.isFinite(npO)) ? npO : num(r.best_np, 2);
  let c = (cO != null && Number.isFinite(cO)) ? cO : defaultC(model);
  const soloMax = (capFor(model).solo || {}).max_c;
  const dualMax = (capFor(model).dual || {}).max_c;
  const ub = num(r.best_ub, 128);
  const b = num(r.best_b, 64);
  let cont = "on";
  if (r.cont_batch_recommended) cont = r.cont_batch_recommended;
  else if (String(r.cont_batching || "").includes("off")) cont = "off";
  const missing = [];
  if (dash(r.best_c) && !soloMax) missing.push("c");
  if (dash(r.best_b)) missing.push("b");
  if (!r.cont_batch_recommended) missing.push("cont-batch A/B");
  const kv = defaultKv(model);
  return { model, np, c, ub, b, cont, kv, decode: r.decode_ms, prefill: r.prefill_tps, missing, soloMax, dualMax };
}

let mode = (DATA.advice && DATA.advice.prefer_mode) || "solo";

function setMode(next) {
  const advice = DATA.advice || {};
  if (next === "dual" && advice.allow_dual === false) return;
  mode = next;
  document.querySelectorAll("#modes button").forEach(b => {
    b.classList.toggle("active", b.dataset.mode === mode);
  });
  render();
}

function updateAdviceBanner() {
  const a = DATA.advice || {};
  const el = document.getElementById("adviceBanner");
  if (!el) return;
  const prefer = a.prefer_mode || "solo";
  el.className = "banner " + (a.prefer_dual ? "prefer" : "warn");
  const dualNote = a.any_dual_ok
    ? " Dual capacity has ok cells."
    : (a.high_mem ? " Run ./bench capacity dual to confirm 2× fit." : "");
  el.innerHTML = `<strong>Host advice:</strong> prefer <code>${esc(prefer)}</code>. ${esc(a.reason || "")}${esc(dualNote)}`
    + ` <span class="meta">(RAM ${DATA.host.ram_gib} GiB · GTT ${DATA.host.gtt_gib} GiB)</span>`;
  const btn = document.getElementById("btnDual");
  if (btn) {
    btn.disabled = a.allow_dual === false;
    btn.title = a.allow_dual === false
      ? "Disabled: no dual capacity ok on this host class"
      : "Two containers — recommended when RAM/GTT allows (256k context ceiling per model)";
  }
}

function buildPlan(chat, coder) {
  const sticky = mode === "dual" ? 2 : 1;
  const plan = {
    version: 1,
    sticky_count: mode === "lab" ? 0 : sticky,
    mode,
    host: DATA.host,
    chat: {
      model: chat.model, np: chat.np, c: chat.c, ub: chat.ub, b: chat.b,
      kv: chat.kv, cont_batch: chat.cont,
      ini: mode === "lab" ? "models-lab.ini" : "models.ini",
    },
    coder: null,
    apply: {
      cmd: "",
    },
  };
  if (mode === "dual") {
    plan.coder = {
      model: coder.model, np: coder.np, c: coder.c, ub: coder.ub, b: coder.b,
      kv: coder.kv, cont_batch: coder.cont, ini: "models-coder.ini",
    };
    plan.apply.cmd = "./bench apply-ini --plan plan.json";
  } else if (mode === "lab") {
    plan.apply.cmd = "./bench apply-ini --plan plan.json";
  } else {
    plan.apply.cmd = "./bench apply-ini --plan plan.json";
  }
  return plan;
}

function render() {
  const chat = effective(document.getElementById("chatModel").value, "chat");
  const coder = effective(document.getElementById("coderModel").value, "coder");
  const notes = [];
  let used = DATA.host.os_reserve_gib;
  const parts = [];

  document.getElementById("coderWrap").classList.toggle("hidden", mode !== "dual");
  document.getElementById("npCoder").disabled = mode !== "dual";
  document.getElementById("cCoder").disabled = mode !== "dual";

  if (mode === "solo" || mode === "lab") {
    used += weightGiB(chat.model) + kvGiB(chat.c, chat.np);
    parts.push(chat);
    notes.push(mode === "lab"
      ? "Lab-only: stop sticky for heavy MoE / full GTT. Compose: --profile lab."
      : "1 sticky: only llama (:11535). Leave llama-coder stopped.");
  } else {
    used += weightGiB(chat.model) + kvGiB(chat.c, chat.np);
    used += weightGiB(coder.model) + kvGiB(coder.c, coder.np);
    parts.push(chat, coder);
    notes.push("2 stickys: models.ini → :11535 + models-coder.ini → :11538.");
    if (chat.model === coder.model) {
      notes.push("Same model twice is fine for capacity proof; for daily use pick distinct chat + coder.");
    }
    if (chat.c >= 262144 && coder.c >= 262144) {
      notes.push("Both at 256k is the training ceiling — expect long prefills; np=1 is safer.");
    }
    if (chat.dualMax) notes.push(`${chat.model}: dual capacity ok ≤ ${chat.dualMax}.`);
    if (coder.dualMax && coder.model !== chat.model) {
      notes.push(`${coder.model}: dual capacity ok ≤ ${coder.dualMax}.`);
    }
  }

  // capacity warnings
  for (const p of parts) {
    if (p.soloMax && p.c > p.soloMax) {
      notes.push(`${p.model}: c=${p.c} above capacity solo max ${p.soloMax} — may OOM.`);
    } else if (p.soloMax) {
      notes.push(`${p.model}: capacity solo ok ≤ ${p.soloMax} (${p.kv}).`);
    }
    if (mode === "dual" && p.dualMax && p.c > p.dualMax) {
      notes.push(`${p.model}: dual capacity only ≤ ${p.dualMax}.`);
    }
  }

  const budget = DATA.host.gtt_gib;
  const pct = Math.min(100, (used / budget) * 100);
  let cls = "ok";
  if (pct >= 92) cls = "bad";
  else if (pct >= 80) cls = "warn";

  const bar = document.getElementById("gttBar");
  bar.style.width = pct.toFixed(1) + "%";
  bar.className = cls;

  document.getElementById("status").innerHTML =
    `<span class="${cls}">Est. footprint ~${used.toFixed(1)} GiB / GTT ${budget} GiB (${pct.toFixed(0)}%)</span>` +
    ` · OS reserve ${DATA.host.os_reserve_gib} GiB`;

  document.getElementById("kpis").innerHTML = parts.map(p => {
    const short = p.model.length > 42 ? p.model.slice(0, 40) + "…" : p.model;
    const pill = p.soloMax
      ? `<span class="cap-pill ${p.c <= p.soloMax ? "ok" : "bad"}">cap≤${p.soloMax}</span>`
      : `<span class="cap-pill">no cap data</span>`;
    return `<div><span>${esc(short)}${pill}</span><strong>np=${p.np} · c=${p.c}</strong>` +
      `<span>ub=${p.ub} · b=${p.b} · kv=${p.kv} · cont=${p.cont}</span></div>`;
  }).join("") + `<div><span>decode ms</span><strong>${parts.map(p => p.decode != null ? Number(p.decode).toFixed(1) : "—").join(" / ")}</strong>
    <span>prefill ${parts.map(p => p.prefill != null ? Number(p.prefill).toFixed(1) : "—").join(" · ")} tok/s</span></div>`;

  for (const p of parts) {
    for (const m of p.missing) notes.push(`${p.model}: missing ★ ${m}`);
  }
  if (cls === "bad") notes.push("Over budget — lower c/np or use 1 sticky.");
  if (cls === "warn") notes.push("Tight — OK idle; watch GTT when contexts are filled.");

  document.getElementById("notes").innerHTML = notes.map(n => `<li>${esc(n)}</li>`).join("");

  let snip = "";
  if (mode === "dual") {
    snip =
`; models.ini — sticky chat (:11535)
[${chat.model}]
np = ${chat.np}
c = ${chat.c}
ub = ${chat.ub}
b = ${chat.b}
ctk = ${chat.kv}
ctv = ${chat.kv}
fit = off
load-on-startup = true

; models-coder.ini — sticky coder (:11538)
[${coder.model}]
np = ${coder.np}
c = ${coder.c}
ub = ${coder.ub}
b = ${coder.b}
ctk = ${coder.kv}
ctv = ${coder.kv}
fit = off
load-on-startup = true
`;
  } else {
    const file = mode === "lab" ? "models-lab.ini" : "models.ini";
    snip =
`; ${file}
[${chat.model}]
np = ${chat.np}
c = ${chat.c}
ub = ${chat.ub}
b = ${chat.b}
ctk = ${chat.kv}
ctv = ${chat.kv}
fit = off
` + (mode === "solo" ? "load-on-startup = true\n" : "");
  }
  document.getElementById("snippet").textContent = snip;

  const plan = buildPlan(chat, coder);
  window.__PLAN__ = plan;
  const applyLines = [
    "# save Download → plan.json in repo root, then:",
    plan.apply.cmd,
    mode === "solo" ? "docker compose up -d --force-recreate llama" :
      mode === "dual" ? "docker compose up -d --force-recreate llama llama-coder" :
      "docker compose --profile lab up -d --force-recreate llama-lab",
  ].join("\n");
  document.getElementById("applyCmd").textContent = applyLines;

  // capacity table
  const capRows = Object.keys(DATA.capacity || {}).sort().map(m => {
    const s = DATA.capacity[m].solo || {};
    const d = DATA.capacity[m].dual || {};
    return `<tr><td>${esc(m)}</td>
      <td class="n">${s.max_c != null ? s.max_c : "—"}</td>
      <td>${esc(s.kv || "—")}</td>
      <td class="n">${d.max_c != null ? d.max_c : "—"}</td>
      <td>${esc(d.kv || "—")}</td></tr>`;
  }).join("");
  document.getElementById("capTable").innerHTML = capRows ||
    `<tr><td colspan="5" class="meta">No capacity cells yet — run ./bench capacity / matrix</td></tr>`;

  const rows = (DATA.recommendations || []).map(r => {
    const w = weightGiB(r.model);
    return `<tr><td>${esc(r.model)}</td>
      <td class="n">${esc(r.best_np || "—")}</td>
      <td class="n">${esc(r.best_ub || "—")}</td>
      <td class="n">${esc(r.best_b || "—")}</td>
      <td class="n">${esc(r.best_c || "—")}</td>
      <td>${esc(r.cont_batching || "—")}</td>
      <td class="n">${r.decode_ms != null ? Number(r.decode_ms).toFixed(1) : "—"}</td>
      <td class="n">${w.toFixed(1)}</td></tr>`;
  }).join("");
  document.getElementById("catalog").innerHTML = rows ||
    `<tr><td colspan="8">No sched ★ yet — run ./bench sched / matrix</td></tr>`;
}

function bind() {
  updateAdviceBanner();
  const list = models();
  const preferChat = list.find(m => /Qwen3\.6.*35B/.test(m) && !m.endsWith("-VL"))
    || list.find(m => /Qwen3\.6/.test(m))
    || list[0];
  const preferCoder = list.find(m => /Cyber-Tiel/.test(m) && !m.endsWith("-VL"))
    || list.find(m => /Tiel-Coder/.test(m) && !m.endsWith("-VL"))
    || list.find(m => m !== preferChat)
    || list[0];
  fillSelect(document.getElementById("chatModel"), preferChat);
  fillSelect(document.getElementById("coderModel"), preferCoder);
  document.querySelectorAll("#modes button").forEach(b => {
    b.classList.toggle("active", b.dataset.mode === mode);
  });
  document.getElementById("modes").addEventListener("click", (e) => {
    const btn = e.target.closest("button[data-mode]");
    if (!btn || btn.disabled) return;
    setMode(btn.dataset.mode);
  });
  ["chatModel","coderModel","npChat","npCoder","cChat","cCoder"].forEach(id => {
    document.getElementById(id).addEventListener("input", render);
    document.getElementById(id).addEventListener("change", render);
  });
  document.getElementById("copyBtn").addEventListener("click", () => {
    navigator.clipboard.writeText(document.getElementById("snippet").textContent);
  });
  document.getElementById("copyApply").addEventListener("click", () => {
    navigator.clipboard.writeText(document.getElementById("applyCmd").textContent);
  });
  document.getElementById("dlPlan").addEventListener("click", () => {
    const blob = new Blob([JSON.stringify(window.__PLAN__ || {}, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "plan.json";
    a.click();
    URL.revokeObjectURL(a.href);
  });
  render();
}
bind();
</script>
</body></html>
'''

html = html.replace("__DATA__", json.dumps(payload, ensure_ascii=False))
Path(out_path).write_text(html, encoding="utf-8")
n_cap = len(capacity)
print(f"Wrote {out_path} (sched={len(recs)} models, capacity={n_cap} models)")
PY
