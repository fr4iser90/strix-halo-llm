#!/usr/bin/env bash
# Build output/bench/index.html (local: benches + apply/planner) and
# pages-index.html (GitHub Pages: measured benches only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/python.sh
source "$SCRIPT_DIR/lib/python.sh"

OUT="$PROJECT_ROOT/output/bench"
THR="$OUT/throughput"
SCH="$OUT/scheduling"
INDEX_MD="$OUT/index.md"
INDEX_HTML="$OUT/index.html"
HOST_JSON="$OUT/host.json"

# Refresh hardware snapshot when possible (non-fatal)
if [[ -x "$SCRIPT_DIR/probe-host.sh" ]]; then
  "$SCRIPT_DIR/probe-host.sh" >/dev/null 2>&1 || true
fi

mkdir -p "$OUT" "$THR/latest" "$SCH/latest"

bench_python - "$OUT" "$THR" "$SCH" "$INDEX_MD" "$INDEX_HTML" "$HOST_JSON" <<'PY'
import csv, glob, html, json, os, re, sys
from collections import defaultdict
from datetime import datetime

out_root, thr, sch, index_md, index_html, host_json = sys.argv[1:7]


def fmt_stamp(s):
    if not s or len(s) < 15:
        return s or "—"
    try:
        return datetime.strptime(s[:15], "%Y%m%dT%H%M%S").strftime("%Y-%m-%d %H:%M UTC")
    except ValueError:
        return s


def esc(s):
    return html.escape(str(s))


def fmt_num(x, digits=1):
    if x is None or x == "":
        return "—"
    if isinstance(x, (int, float)):
        if abs(x) >= 1000:
            return f"{x:,.0f}"
        return f"{x:.{digits}f}"
    return str(x)


def rel(*parts):
    return "/".join(parts)


# --- Throughput latest (lab vulkan preferred) ---
thr_models = []
thr_cmp = os.path.join(thr, "latest", "compare.md")
if os.path.isfile(thr_cmp):
    in_table = False
    with open(thr_cmp, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip()
            if line.startswith("| model |"):
                in_table = True
                continue
            if in_table:
                if not line.startswith("|") or line.startswith("| ---"):
                    if thr_models:
                        break
                    continue
                parts = [p.strip() for p in line.split("|")[1:-1]]
                if len(parts) >= 3 and parts[0] != "model" and not parts[0].startswith("---"):
                    thr_models.append({"model": parts[0], "pp": parts[1], "tg": parts[2]})

thr_runs = {}
for path in sorted(glob.glob(os.path.join(thr, "llama-bench-*-*-*.*"))):
    base = os.path.basename(path)
    m = re.match(
        r"llama-bench-(\d{8}T\d{6}Z)-(daily|mix|lab|all|heavy)-(vulkan|rocm|cpu)\.(csv|log)$",
        base,
    )
    if not m:
        continue
    stamp, suite, backend, _kind = m.groups()
    key = (stamp, suite)
    thr_runs.setdefault(key, {"stamp": stamp, "suite": suite, "backends": set()})
    thr_runs[key]["backends"].add(backend)

thr_rows = []
for key in sorted(thr_runs.keys(), reverse=True):
    r = thr_runs[key]
    cmp_path = os.path.join(thr, f"llama-bench-{r['stamp']}-compare.md")
    thr_rows.append({
        "when": fmt_stamp(r["stamp"]),
        "stamp": r["stamp"],
        "suite": r["suite"],
        "backends": ", ".join(sorted(r["backends"])),
        "run_compare": rel("throughput", os.path.basename(cmp_path)) if os.path.isfile(cmp_path) else "",
    })

# --- Scheduling recommendations ---
sch_recs = []
summary_path = os.path.join(sch, "latest", "summary.json")
if os.path.isfile(summary_path):
    with open(summary_path, encoding="utf-8") as f:
        sch_recs = json.load(f).get("recommendations") or []


def fmt_b(val):
    if val is None or val in ("", "—", "\u2014"):
        return "64†"
    return str(val)


def cont_batch_pp_for_model(model):
    pp_on = pp_off = None
    cb = "on"
    for run_dir in sorted(glob.glob(os.path.join(sch, "20*")), reverse=True):
        man_path = os.path.join(run_dir, "manifest.json")
        sweep = os.path.join(run_dir, "07_cont_batch", "summary.json")
        if not os.path.isfile(man_path) or not os.path.isfile(sweep):
            continue
        with open(man_path, encoding="utf-8") as f:
            if json.load(f).get("model") != model:
                continue
        with open(sweep, encoding="utf-8") as f:
            data = json.load(f)
        rec = data.get("recommended") or "on"
        cb = f"{rec} ★"
        for entry in data.get("runs") or []:
            if entry.get("mode") == "cont_on":
                pp_on = entry.get("pp_tok_s")
            elif entry.get("mode") == "cont_off":
                pp_off = entry.get("pp_tok_s")
        break
    return cb, pp_on, pp_off

# --- Scheduling per-model status ---
model_status = defaultdict(lambda: {
    "auto": False, "ub_sweep": False, "np_sweep": False, "b_sweep": False,
    "stamp_auto": "", "stamp_ub": "", "stamp_np": "", "stamp_b": "",
})
sch_rows = []
for run_dir in sorted(glob.glob(os.path.join(sch, "20*")), reverse=True):
    if not os.path.isdir(run_dir):
        continue
    stamp = os.path.basename(run_dir)
    man_path = os.path.join(run_dir, "manifest.json")
    if not os.path.isfile(man_path):
        continue
    with open(man_path, encoding="utf-8") as f:
        man = json.load(f)
    model = man.get("model", "—")
    scenarios = []
    for scen_dir in sorted(glob.glob(os.path.join(run_dir, "*"))):
        if not os.path.isdir(scen_dir):
            continue
        name = os.path.basename(scen_dir)
        if name == "latest":
            continue
        if os.path.isfile(os.path.join(scen_dir, "summary.json")):
            scenarios.append(name)
    has_auto = any(s.startswith("0") and "sweep" not in s for s in scenarios)
    # Sweeps count only when summary.json has non-empty runs[]
    def _sweep_ok(name):
        if name not in scenarios:
            return False
        sp = os.path.join(run_dir, name, "summary.json")
        try:
            with open(sp, encoding="utf-8") as f:
                return bool((json.load(f).get("runs") or []))
        except (OSError, json.JSONDecodeError):
            return False
    has_ub = _sweep_ok("04_ub_sweep")
    has_np = _sweep_ok("05_np_sweep")
    has_b = _sweep_ok("06_b_sweep")
    if has_auto and stamp >= model_status[model]["stamp_auto"]:
        model_status[model]["auto"] = True
        model_status[model]["stamp_auto"] = stamp
    if has_ub and stamp >= model_status[model]["stamp_ub"]:
        model_status[model]["ub_sweep"] = True
        model_status[model]["stamp_ub"] = stamp
    if has_np and stamp >= model_status[model]["stamp_np"]:
        model_status[model]["np_sweep"] = True
        model_status[model]["stamp_np"] = stamp
    if has_b and stamp >= model_status[model]["stamp_b"]:
        model_status[model]["b_sweep"] = True
        model_status[model]["stamp_b"] = stamp
    sch_rows.append({
        "when": fmt_stamp(stamp),
        "stamp": stamp,
        "model": model,
        "np": man.get("np", "—"),
        "ub": man.get("ub", "—"),
        "scenarios": ", ".join(scenarios) if scenarios else "—",
        "dir": rel("scheduling", stamp),
    })

status_rows = []
for model in sorted(model_status.keys()):
    st = model_status[model]
    parts = []
    parts.append("auto ✓" if st["auto"] else "auto ⏳")
    parts.append("ub ✓" if st["ub_sweep"] else "ub ⏳")
    parts.append("np ✓" if st["np_sweep"] else "np ⏳")
    parts.append("b ✓" if st["b_sweep"] else "b ⏳")
    status = " · ".join(parts)
    if all(st[k] for k in ("auto", "ub_sweep", "np_sweep", "b_sweep")):
        status = "✓ complete"
    rec = next((r for r in sch_recs if r.get("model") == model), {})
    status_rows.append({
        "model": model,
        "status": status,
        "best_np": rec.get("best_np", "—"),
        "best_ub": rec.get("best_ub", "—"),
        "best_b": fmt_b(rec.get("best_b")),
        "best_mtp": rec.get("best_mtp", "—"),
        "decode_ms": rec.get("decode_ms"),
        "decode_tps": rec.get("decode_tps"),
        "prefill_ttft": rec.get("prefill_ttft"),
    })

# --- Host hardware (for Pages reproducibility) ---
host = {}
if os.path.isfile(host_json):
    try:
        with open(host_json, encoding="utf-8") as f:
            host = json.load(f)
    except (OSError, json.JSONDecodeError):
        host = {}

def host_md_block(h):
    if not h:
        return [
            "## Hardware",
            "",
            "*No `host.json` yet — on the bench host run: `./tools/bench/probe-host.sh` "
            "or `./bench publish`.*",
            "",
        ]
    pin = h.get("llama_pin") or {}
    commit = pin.get("commit") or "—"
    if commit and len(commit) > 12:
        commit_s = commit[:12]
    else:
        commit_s = commit
    rows = [
        ("Host", h.get("hostname") or "—"),
        ("OS", h.get("os") or "—"),
        ("Kernel", h.get("kernel") or "—"),
        ("CPU", f"{h.get('cpu') or '—'} ({h.get('nproc') or '?'} threads)"),
        ("RAM", f"{h.get('ram_gib') or '—'} GiB" + (f" (avail ~{round((h.get('ram_available_mib') or 0)/1024, 1)} GiB)" if h.get("ram_available_mib") else "")),
        ("Swap", f"{h.get('swap_gib') or '—'} GiB"),
        ("GTT (UMA)", f"{h.get('gtt_total_gib') or '—'} GiB" + (f" (used ~{round((h.get('gtt_used_mib') or 0)/1024, 1)} GiB)" if h.get("gtt_used_mib") else "")),
        ("Visible VRAM", f"{h.get('vram_total_mib') or '—'} MiB"),
        ("GPU", h.get("gpu") or "—"),
        ("Backend", h.get("backend_default") or "—"),
        ("Image", f"{h.get('docker_image') or '—'} (`{h.get('docker_image_id_short') or '—'}`)"),
        ("llama.cpp", f"{pin.get('ref') or '—'} @ `{commit_s}`"),
        ("Sidecar", (
            f"{'ok' if (h.get('sidecar') or {}).get('power_ok') else 'down'} · "
            f"{(h.get('sidecar') or {}).get('watts') if (h.get('sidecar') or {}).get('power_ok') else '—'} W · "
            f"`{(h.get('sidecar') or {}).get('power_url') or '—'}`"
        )),
        ("Probed", h.get("collected_at") or "—"),
    ]
    lines_h = [
        "## Hardware",
        "",
        "Compare results only across similar RAM/GTT/backends. "
        f"[host.json]({rel('host.json')})",
        "",
        "| | |",
        "|---|---|",
    ]
    for k, v in rows:
        lines_h.append(f"| {k} | {v} |")
    if h.get("notes"):
        lines_h += ["", f"> {h['notes']}", ""]
    else:
        lines_h.append("")
    return lines_h


def host_html_card(h):
    if not h:
        return (
            '<div class="card"><h2>Hardware</h2>'
            '<p class="meta">No <code>host.json</code> yet — '
            'run <code>./bench publish</code> on the bench host.</p></div>'
        )
    pin = h.get("llama_pin") or {}
    commit = pin.get("commit") or "—"
    commit_s = commit[:12] if isinstance(commit, str) and len(commit) > 12 else commit
    def row(k, v):
        return f"<tr><th>{esc(k)}</th><td>{esc(v)}</td></tr>"
    ram = f"{h.get('ram_gib') or '—'} GiB"
    if h.get("ram_available_mib"):
        ram += f" (avail ~{round((h.get('ram_available_mib') or 0)/1024, 1)} GiB)"
    gtt = f"{h.get('gtt_total_gib') or '—'} GiB"
    if h.get("gtt_used_mib"):
        gtt += f" (used ~{round((h.get('gtt_used_mib') or 0)/1024, 1)} GiB)"
    rows = [
        row("Host", h.get("hostname") or "—"),
        row("OS", h.get("os") or "—"),
        row("Kernel", h.get("kernel") or "—"),
        row("CPU", f"{h.get('cpu') or '—'} ({h.get('nproc') or '?'} threads)"),
        row("RAM", ram),
        row("Swap", f"{h.get('swap_gib') or '—'} GiB"),
        row("GTT (UMA)", gtt),
        row("Visible VRAM", f"{h.get('vram_total_mib') or '—'} MiB"),
        row("GPU", h.get("gpu") or "—"),
        row("Backend", h.get("backend_default") or "—"),
        row("Image", f"{h.get('docker_image') or '—'} ({h.get('docker_image_id_short') or '—'})"),
        row("llama.cpp", f"{pin.get('ref') or '—'} @ {commit_s}"),
        row("Sidecar", (
            f"{'ok' if (h.get('sidecar') or {}).get('power_ok') else 'down'} · "
            f"{(h.get('sidecar') or {}).get('watts') if (h.get('sidecar') or {}).get('power_ok') else '—'} W · "
            f"{(h.get('sidecar') or {}).get('temperature_c') if (h.get('sidecar') or {}).get('thermal_ok') else '—'} °C · "
            f"{(h.get('sidecar') or {}).get('power_url') or '—'}"
        )),
        row("Probed", h.get("collected_at") or "—"),
    ]
    note = f'<p class="meta">{esc(h.get("notes") or "")}</p>' if h.get("notes") else ""
    return (
        '<div class="card" id="hardware"><h2>Hardware <span class="meta">'
        '<a href="host.json">host.json</a></span></h2>'
        f"{note}"
        '<table><tbody>' + "".join(rows) + "</tbody></table></div>"
    )

# --- Markdown ---
lines = [
    "# Bench — Dashboard",
    "",
    "**Start here.** Hardware first (comparability), then recommendations, history below.",
    "",
]
lines += host_md_block(host)
lines += [
    "## Scheduling — which `ub`? (np=2, keep decode low)",
    "",
    "Decode latency + prefill throughput **under load**. "
    f"[Details →]({rel('scheduling/latest/compare.html')})",
    "",
]
if sch_recs:
    lines += [
        "| Model | np ★ | ub ★ | b ★ | c ★ | MTP ★ | cont-batch | Prefill tok/s | TTFT ms | Decode tok/s | Decode ms | TG tok/s | Interleave |",
        "| --- | ---: | ---: | ---: | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for r in sch_recs:
        gain = "—"
        if r.get("interleave_gain") and r["interleave_gain"] > 2:
            gain = f"{r['interleave_gain']:.0f}×"
        cb, _pp_on, _pp_off = cont_batch_pp_for_model(r["model"])
        lines.append(
            f"| {r['model']} | **{r.get('best_np', '—')}** | **{r.get('best_ub', '—')}** | "
            f"**{fmt_b(r.get('best_b'))}** | **{r.get('best_c', '—')}** | **{r.get('best_mtp', '—')}** | {cb} | "
            f"{fmt_num(r.get('prefill_tps'))} | {fmt_num(r.get('prefill_ttft'))} | "
            f"{fmt_num(r.get('decode_tps'))} | {fmt_num(r.get('decode_ms'))} | "
            f"{fmt_num(r.get('tg_idle'))} | {gain} |"
        )
    lines += [
        "",
        "† `b` (n_batch): sweep **06_b_sweep** still pending — currently bench default **64**.",
        "",
        "## Apply settings",
        "",
        "```bash",
        "./bench apply-ini --dry-run --lab   # Plan",
        "./bench apply-ini --lab             # models-lab.ini (INI keys only)",
        "docker compose --profile lab up -d llama-lab",
        "```",
        "",
        f"Plan: [`scheduling/latest/apply-plan.json`]({rel('scheduling/latest/apply-plan.json')})",
        "",
    ]
else:
    lines.append("*No scheduling recommendations yet — `./bench sched --auto`*")

lines += [
    "",
    "## Throughput — which model is fastest?",
    "",
    f"[Details →]({rel('throughput/latest/compare.html')}) · PP = Prompt tok/s · TG = Generation tok/s · **higher = better**",
    "",
]
if thr_models:
    lines += ["| Model | PP (512 tok) | TG (128 tok) |", "| --- | ---: | ---: |"]
    for m in thr_models:
        lines.append(f"| {m['model']} | {m['pp']} | {m['tg']} |")
else:
    lines.append("*No throughput bench yet — `./bench throughput --lab --vulkan`*")

# Quality (HumanEval etc.)
qual_root = os.path.join(out_root, "quality")
qual_rows = []
qual_cmp = os.path.join(qual_root, "latest", "compare.md")
qual_sum = os.path.join(qual_root, "latest", "summary.json")
if os.path.isfile(qual_sum):
    try:
        with open(qual_sum, encoding="utf-8") as f:
            qdata = json.load(f)
        qual_rows = qdata.get("rows") or []
    except (OSError, json.JSONDecodeError):
        qual_rows = []

lines += ["", "## Quality — task correctness", ""]
if qual_rows:
    lines += [
        f"[Details →]({rel('quality/latest/compare.md')}) · plugins: `./bench quality list`",
        "",
        "| Suite | Model | pass@1 | pass@10 | Stamp |",
        "| --- | --- | ---: | ---: | --- |",
    ]
    for r in qual_rows:
        p1 = r.get("pass_at_1")
        p10 = r.get("pass_at_10")
        lines.append(
            f"| {r.get('suite','—')} | `{r.get('model','—')}` | "
            f"{fmt_num(p1, 3) if isinstance(p1, float) else (p1 if p1 is not None else '—')} | "
            f"{fmt_num(p10, 3) if isinstance(p10, float) else (p10 if p10 is not None else '—')} | "
            f"`{r.get('stamp','—')}` |"
        )
else:
    lines.append(
        "*No quality runs yet — "
        "`./bench quality humaneval --setup` then "
        "`./bench quality humaneval --model … --limit 10`*"
    )

# Capacity (KV×ctx / dual) — full tables from ledger
cap_root = os.path.join(out_root, "capacity")
cap_cmp = os.path.join(cap_root, "latest", "compare.md")
cap_ledger = os.path.join(cap_root, "cells.jsonl")
cap_latest = {}
if os.path.isfile(cap_ledger):
    with open(cap_ledger, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            key = row.get("key")
            if key:
                cap_latest[key] = row
cap_cells = len(cap_latest)


def cap_metrics(r):
    """Derive GTT / prefill_s / prefill_tok_s / watts from a ledger row (incl. legacy)."""
    if not r or r.get("skipped") or not r.get("ok"):
        return None
    peak = r.get("metrics_peak") or {}
    gtt = peak.get("gtt_used_mb") or (r.get("mem_after") or {}).get("gtt_used_mb")
    prefill_s = r.get("prefill_s")
    prefill_tok_s = r.get("prefill_tok_s")
    stream = r.get("stream") or {}
    fill_n = r.get("fill_tokens")
    if fill_n is None:
        c = int(r.get("c") or 0)
        fill_n = max(1024, int(c * 0.90)) if c else None
    ttft_ms = stream.get("ttft_ms")
    if prefill_s is None and ttft_ms and ttft_ms > 0:
        prefill_s = round(ttft_ms / 1000.0, 3)
    if prefill_s is None and r.get("elapsed_s"):
        prefill_s = float(r["elapsed_s"])
    if prefill_tok_s is None and prefill_s and fill_n and prefill_s > 0:
        prefill_tok_s = round(float(fill_n) / float(prefill_s), 2)
    return {
        "gtt_mb": int(gtt) if gtt is not None else None,
        "gtt_gib": round(float(gtt) / 1024.0, 2) if gtt is not None else None,
        "prefill_s": prefill_s,
        "prefill_tok_s": prefill_tok_s,
        "fill_tokens": fill_n,
        "power_w_avg": peak.get("power_w_avg"),
        "power_w_peak": peak.get("power_w_peak"),
        "temp_c_peak": peak.get("temp_c_peak"),
    }


def cap_cell_label(r, metric="all"):
    if not r:
        return "—"
    if r.get("skipped"):
        return "skip"
    if not r.get("ok"):
        return f"FAIL:{r.get('phase') or '?'}"
    m = cap_metrics(r)
    if not m:
        return "ok"
    if metric == "gtt":
        return f"{m['gtt_mb']} MiB" if m["gtt_mb"] is not None else "—"
    if metric == "prefill_s":
        return f"{m['prefill_s']} s" if m["prefill_s"] is not None else "—"
    if metric == "prefill_tok_s":
        return f"{m['prefill_tok_s']} t/s" if m["prefill_tok_s"] is not None else "—"
    if metric == "power":
        w = m.get("power_w_avg") if m.get("power_w_avg") is not None else m.get("power_w_peak")
        return f"{w} W" if w is not None else "—"
    parts = []
    if m["gtt_mb"] is not None:
        parts.append(f"{m['gtt_mb']} MiB")
    if m["prefill_s"] is not None:
        parts.append(f"{m['prefill_s']} s")
    if m["prefill_tok_s"] is not None:
        parts.append(f"{m['prefill_tok_s']} t/s PP")
    w = m.get("power_w_avg") if m.get("power_w_avg") is not None else m.get("power_w_peak")
    if w is not None:
        parts.append(f"{w} W")
    return " · ".join(parts) if parts else "ok"


def capacity_md_tables():
    out = []
    solo = [r for r in cap_latest.values() if r.get("mode") == "solo" and not r.get("skipped")]
    if not solo and not any(r.get("mode") == "dual" for r in cap_latest.values()):
        return out
    for model in sorted({r["model"] for r in solo}):
        sub = [r for r in solo if r["model"] == model]
        kvs = sorted({r["kv"] for r in sub})
        cs = sorted({int(r["c"]) for r in sub})
        by = {(r["kv"], int(r["c"])): r for r in sub}
        out += [
            f"### {model} (solo)",
            "",
            "Cell = **GTT MiB · prefill s · prefill tok/s** (TTFT ≈ prefill of ~0.9×c tokens)",
            "",
            "| c \\ kv | " + " | ".join(kvs) + " |",
            "| ---: | " + " | ".join(["---"] * len(kvs)) + " |",
        ]
        for c in cs:
            cells = [cap_cell_label(by.get((kv, c))) for kv in kvs]
            out.append(f"| {c} | " + " | ".join(cells) + " |")
        out.append("")
    dual = [r for r in cap_latest.values() if r.get("mode") == "dual"]
    if dual:
        out += [
            "### Dual (2× same model)",
            "",
            "| model | kv | c | ok | GTT peak | Mem avail | W avg | °C peak | phase |",
            "| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | --- |",
        ]
        for r in sorted(dual, key=lambda x: (x.get("model") or "", x.get("kv") or "", int(x.get("c") or 0))):
            peak = r.get("metrics_peak") or {}
            mem_a = r.get("mem_after") or {}
            gtt = peak.get("gtt_used_mb") or mem_a.get("gtt_used_mb")
            mem = peak.get("mem_avail_mb_min") or mem_a.get("mem_avail_mb")
            ok = "✓" if r.get("ok") else "FAIL"
            gtt_s = f"{int(gtt)} MiB" if gtt is not None else "—"
            mem_s = f"{int(mem)} MiB" if mem is not None else "—"
            w = peak.get("power_w_avg") if peak.get("power_w_avg") is not None else peak.get("power_w_peak")
            w_s = f"{w} W" if w is not None else "—"
            t = peak.get("temp_c_peak")
            t_s = f"{t}" if t is not None else "—"
            out.append(
                f"| {r.get('model')} | {r.get('kv')} | {r.get('c')} | {ok} | {gtt_s} | {mem_s} | {w_s} | {t_s} | {r.get('phase') or '—'} |"
            )
        out.append("")
    return out


def capacity_html_card():
    solo = [r for r in cap_latest.values() if r.get("mode") == "solo" and not r.get("skipped")]
    dual = [r for r in cap_latest.values() if r.get("mode") == "dual"]
    if not solo and not dual:
        return (
            '<div class="card" id="capacity"><h2>Capacity — KV×ctx</h2>'
            '<p class="meta">No capacity runs yet — <code>./bench capacity kv-ctx</code> / matrix</p></div>'
        )
    parts = [
        '<div class="card" id="capacity">',
        '<h2>Capacity — KV×ctx <span class="meta">GTT · prefill · watts (sidecar)</span></h2>',
        f'<p class="more"><a href="capacity/latest/compare.md">→ Details</a> · ledger cells: <strong>{cap_cells}</strong></p>',
        '<p class="meta"><strong>Prefill s</strong> ≈ TTFT for ~0.9×c prompt tokens · '
        '<strong>Prefill tok/s</strong> = fill_tokens / prefill_s · '
        '<strong>W</strong> = avg GPU draw via sidecar (only if <code>GPU_POWER_URL</code> set).</p>',
        '<div class="metric-tabs" id="cap-metric-tabs">'
        '<button type="button" class="btn secondary active" data-metric="all">All</button>'
        '<button type="button" class="btn secondary" data-metric="gtt">GTT only</button>'
        '<button type="button" class="btn secondary" data-metric="prefill_s">Prefill time</button>'
        '<button type="button" class="btn secondary" data-metric="prefill_tok_s">Prefill tok/s</button>'
        '<button type="button" class="btn secondary" data-metric="power">Watts</button>'
        '</div>',
    ]
    for model in sorted({r["model"] for r in solo}):
        sub = [r for r in solo if r["model"] == model]
        kvs = sorted({r["kv"] for r in sub})
        cs = sorted({int(r["c"]) for r in sub})
        by = {(r["kv"], int(r["c"])): r for r in sub}
        parts.append(f"<h3>{esc(model)}</h3>")
        parts.append('<div class="scroll"><table class="cap-grid"><thead><tr><th class="n">c \\ kv</th>')
        for kv in kvs:
            parts.append(f"<th class=\"n\">{esc(kv)}</th>")
        parts.append("</tr></thead><tbody>")
        for c in cs:
            parts.append(f'<tr><td class="n">{c}</td>')
            for kv in kvs:
                r = by.get((kv, c))
                if not r:
                    parts.append('<td class="n">—</td>')
                    continue
                if r.get("skipped"):
                    parts.append('<td class="n">skip</td>')
                    continue
                if not r.get("ok"):
                    parts.append(f'<td class="n fail">FAIL:{esc(r.get("phase") or "?")}</td>')
                    continue
                m = cap_metrics(r) or {}
                parts.append(
                    '<td class="n ok cap-cell" '
                    f'data-gtt="{esc(cap_cell_label(r, "gtt"))}" '
                    f'data-prefill_s="{esc(cap_cell_label(r, "prefill_s"))}" '
                    f'data-prefill_tok_s="{esc(cap_cell_label(r, "prefill_tok_s"))}" '
                    f'data-power="{esc(cap_cell_label(r, "power"))}" '
                    f'data-all="{esc(cap_cell_label(r, "all"))}">'
                    f'{esc(cap_cell_label(r, "all"))}</td>'
                )
            parts.append("</tr>")
        parts.append("</tbody></table></div>")
    if dual:
        parts.append(
            "<h3>Dual (2× same model)</h3>"
            '<p class="meta">Peak GTT + MemAvailable + watts after fill — UMA coexistence pressure.</p>'
            "<table><thead><tr>"
            "<th>Model</th><th>kv</th><th class=\"n\">c</th><th>ok</th>"
            "<th class=\"n\">GTT peak</th><th class=\"n\">Mem avail</th>"
            "<th class=\"n\">W avg</th><th class=\"n\">°C peak</th><th>phase</th>"
            "</tr></thead><tbody>"
        )
        for r in sorted(dual, key=lambda x: (x.get("model") or "", x.get("kv") or "", int(x.get("c") or 0))):
            peak = r.get("metrics_peak") or {}
            mem_a = r.get("mem_after") or {}
            gtt = peak.get("gtt_used_mb") or mem_a.get("gtt_used_mb")
            mem = peak.get("mem_avail_mb_min") or mem_a.get("mem_avail_mb")
            ok = "✓" if r.get("ok") else "FAIL"
            ocls = "ok" if r.get("ok") else "fail"
            gtt_s = f"{int(gtt)} MiB" if gtt is not None else "—"
            mem_s = f"{int(mem)} MiB" if mem is not None else "—"
            w = peak.get("power_w_avg") if peak.get("power_w_avg") is not None else peak.get("power_w_peak")
            w_s = f"{w} W" if w is not None else "—"
            t = peak.get("temp_c_peak")
            t_s = f"{t} °C" if t is not None else "—"
            parts.append(
                f"<tr><td>{esc(r.get('model'))}</td><td>{esc(r.get('kv'))}</td>"
                f'<td class="n">{esc(r.get("c"))}</td>'
                f'<td class="{ocls}">{ok}</td>'
                f'<td class="n">{esc(gtt_s)}</td><td class="n">{esc(mem_s)}</td>'
                f'<td class="n">{esc(w_s)}</td><td class="n">{esc(t_s)}</td>'
                f"<td>{esc(r.get('phase') or '—')}</td></tr>"
            )
        parts.append("</tbody></table>")
    parts.append("""
<script>
(function(){
  const tabs = document.getElementById("cap-metric-tabs");
  if (!tabs) return;
  tabs.addEventListener("click", (e) => {
    const btn = e.target.closest("button[data-metric]");
    if (!btn) return;
    tabs.querySelectorAll("button").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    const m = btn.getAttribute("data-metric");
    document.querySelectorAll("td.cap-cell").forEach(td => {
      td.textContent = td.getAttribute("data-" + m) || "—";
    });
  });
})();
</script>
""")
    parts.append("</div>")
    return "\n".join(parts)


def max_ok_context_html():
    """Per model × kv: largest ok context + GTT / prefill at that cell."""
    solo = [r for r in cap_latest.values() if r.get("mode") == "solo" and not r.get("skipped") and r.get("ok")]
    if not solo:
        return ""
    # (model, kv) -> best row by c
    best = {}
    for r in solo:
        key = (r.get("model"), r.get("kv"))
        c = int(r.get("c") or 0)
        prev = best.get(key)
        if prev is None or c > int(prev.get("c") or 0):
            best[key] = r
    rows = []
    for (model, kv), r in sorted(best.items(), key=lambda x: (x[0][0] or "", x[0][1] or "")):
        m = cap_metrics(r) or {}
        gtt = f"{m['gtt_mb']} MiB" if m.get("gtt_mb") is not None else "—"
        pps = f"{m['prefill_tok_s']} t/s" if m.get("prefill_tok_s") is not None else "—"
        ps = f"{m['prefill_s']} s" if m.get("prefill_s") is not None else "—"
        w = m.get("power_w_avg") if m.get("power_w_avg") is not None else m.get("power_w_peak")
        ws = f"{w} W" if w is not None else "—"
        rows.append(
            f"<tr><td>{esc(model)}</td><td>{esc(kv)}</td>"
            f'<td class="n best">{esc(r.get("c"))}</td>'
            f'<td class="n">{esc(gtt)}</td>'
            f'<td class="n">{esc(ps)}</td>'
            f'<td class="n">{esc(pps)}</td>'
            f'<td class="n">{esc(ws)}</td></tr>'
        )
    return (
        '<div class="card" id="max-ctx">'
        '<h2>Max safe context <span class="meta">largest ok c per model × KV</span></h2>'
        '<p class="meta">Scan this first on Strix Halo — will 64k / 128k / 256k fit at this KV?</p>'
        "<table><thead><tr>"
        "<th>Model</th><th>kv</th><th class=\"n\">max c ★</th>"
        "<th class=\"n\">GTT @ max</th><th class=\"n\">Prefill s</th><th class=\"n\">Prefill tok/s</th>"
        "<th class=\"n\">W avg</th>"
        "</tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table></div>"
    )


def fingerprint_html(h):
    """Compare ledger fingerprints to host.json current image."""
    cur_img = (h.get("docker_image_id") or h.get("docker_image_id_short") or "").strip()
    cur_img_short = (h.get("docker_image_id_short") or cur_img[:12] or "—").strip()
    pin = (h.get("llama_pin") or {})
    cur_commit = (pin.get("commit") or "")[:12] or "—"

    fps = {}  # (ver, img) -> count
    stale = 0
    fresh = 0
    unknown = 0
    for r in cap_latest.values():
        if r.get("skipped"):
            continue
        ver = (r.get("server_version") or "").strip() or "?"
        img = (r.get("image_id") or "").strip() or "?"
        fps[(ver, img)] = fps.get((ver, img), 0) + 1
        if not r.get("server_version") and not r.get("image_id"):
            unknown += 1
        elif cur_img and img not in ("?", "") and cur_img not in img and img not in cur_img:
            # loose match: short vs full
            if cur_img_short not in img and img[:12] != cur_img_short:
                stale += 1
            else:
                fresh += 1
        else:
            fresh += 1

    if not fps and not cap_cells:
        return (
            '<div class="card" id="fingerprint"><h2>Fingerprint</h2>'
            '<p class="meta">No capacity ledger yet — fingerprints appear after kv-ctx runs.</p></div>'
        )

    body = [
        '<div class="card" id="fingerprint">',
        '<h2>Fingerprint <span class="meta">reproducibility</span></h2>',
        '<p class="meta">Capacity cells are only comparable if server/image match. '
        'Stale cells re-run on next <code>./bench capacity kv-ctx</code>.</p>',
        "<table><tbody>",
        f"<tr><th>Current image</th><td><code>{esc(cur_img_short)}</code> · {esc(h.get('docker_image') or '—')}</td></tr>",
        f"<tr><th>llama.cpp</th><td>{esc(pin.get('ref') or '—')} @ <code>{esc(cur_commit)}</code></td></tr>",
        f"<tr><th>Ledger cells</th><td>{cap_cells} · approx fresh≈{fresh} · stale/mismatch≈{stale} · no-fp≈{unknown}</td></tr>",
        "</tbody></table>",
        "<h3>Seen in ledger</h3>",
        "<table><thead><tr><th>server_version</th><th>image_id</th><th class=\"n\">cells</th><th>vs host</th></tr></thead><tbody>",
    ]
    for (ver, img), n in sorted(fps.items(), key=lambda x: -x[1]):
        img_s = img if len(img) <= 20 else img[:19] + "…"
        match = "—"
        if img not in ("?", "") and cur_img_short not in ("—", ""):
            if cur_img_short in img or img[:12] == cur_img_short or (cur_img and cur_img in img):
                match = '<span class="ok">match</span>'
            else:
                match = '<span class="fail">stale?</span>'
        body.append(
            f"<tr><td><code>{esc(ver[:48])}</code></td>"
            f"<td><code>{esc(img_s)}</code></td>"
            f'<td class="n">{n}</td><td>{match}</td></tr>'
        )
    body.append("</tbody></table></div>")
    return "\n".join(body)


def matrix_phase_html():
    mx_path = os.path.join(out_root, "matrix", "progress.json")
    if not os.path.isfile(mx_path):
        return ""
    try:
        with open(mx_path, encoding="utf-8") as f:
            mx = json.load(f)
    except (OSError, json.JSONDecodeError):
        return ""
    cap = mx.get("capacity") or {}
    return (
        '<div class="card" id="matrix-phase">'
        '<h2>Matrix run <span class="meta">progress.json</span></h2>'
        "<table><tbody>"
        f"<tr><th>Phase</th><td><strong>{esc(mx.get('phase') or '—')}</strong> · {esc(mx.get('detail') or '')}</td></tr>"
        f"<tr><th>Updated</th><td><code>{esc(mx.get('updated') or '—')}</code></td></tr>"
        f"<tr><th>Capacity</th><td>{esc(cap.get('index', '—'))}/{esc(cap.get('total', '—'))} "
        f"({esc(cap.get('pct', '—'))}%) · ETA {esc(cap.get('eta') or '—')}</td></tr>"
        "</tbody></table></div>"
    )


lines += ["", "## Capacity — KV×ctx / dual", ""]
if cap_cells:
    lines += [
        f"Ledger cells: **{cap_cells}** · [compare.md]({rel('capacity/latest/compare.md')})",
        "",
        "Cell = GTT MiB · prefill s · prefill tok/s",
        "",
    ]
    # Max-ok summary for MD
    lines += ["### Max safe context", "", "| Model | kv | max c | GTT | Prefill tok/s | W avg |", "| --- | --- | ---: | ---: | ---: | ---: |"]
    solo_ok = [r for r in cap_latest.values() if r.get("mode") == "solo" and not r.get("skipped") and r.get("ok")]
    best = {}
    for r in solo_ok:
        key = (r.get("model"), r.get("kv"))
        c = int(r.get("c") or 0)
        if key not in best or c > int(best[key].get("c") or 0):
            best[key] = r
    for (model, kv), r in sorted(best.items()):
        m = cap_metrics(r) or {}
        w = m.get("power_w_avg") if m.get("power_w_avg") is not None else m.get("power_w_peak")
        lines.append(
            f"| {model} | {kv} | **{r.get('c')}** | {m.get('gtt_mb') or '—'} MiB | {m.get('prefill_tok_s') or '—'} | {w if w is not None else '—'} |"
        )
    lines.append("")
    lines += capacity_md_tables()
else:
    lines.append(
        "*No capacity runs yet — "
        "`./bench capacity kv-ctx` / `dual` or `./bench matrix --profile full`*"
    )

# Matrix orchestrator progress
mx_prog = os.path.join(out_root, "matrix", "progress.json")
lines += ["", "## Matrix — long-run status", ""]
if os.path.isfile(mx_prog):
    try:
        with open(mx_prog, encoding="utf-8") as f:
            mx = json.load(f)
        lines += [
            f"Phase: **{mx.get('phase','—')}** · {mx.get('detail','')} · updated `{mx.get('updated','—')}`",
            "",
            "```bash",
            "./bench matrix status",
            "./bench matrix --profile full",
            "```",
        ]
    except (OSError, json.JSONDecodeError):
        lines.append("*progress.json unreadable*")
else:
    lines.append(
        "*No matrix run yet — profiles: `default` (recommended) / `full` (multi-day). "
        "`./bench matrix --profile full --dry-run`*"
    )

if status_rows:
    lines += [
        "",
        "## Matrix progress",
        "",
        "| Model | Status | np ★ | ub ★ | b ★ | MTP ★ | TTFT ms | Decode tok/s | Decode ms |",
        "| --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |",
    ]
    for r in status_rows:
        lines.append(
            f"| {r['model']} | {r['status']} | {r['best_np']} | {r['best_ub']} | "
            f"{r['best_b']} | {r.get('best_mtp', '—')} | {fmt_num(r.get('prefill_ttft'))} | "
            f"{fmt_num(r.get('decode_tps'))} | {fmt_num(r.get('decode_ms'))} |"
        )

lines += [
    "",
    "---",
    "",
    "<details>",
    "<summary>Run history (raw)</summary>",
    "",
    "### Throughput runs",
    "",
    "| When | Stamp | Suite | Backends |",
    "| --- | --- | --- | --- |",
]
for r in thr_rows:
    lines.append(f"| {r['when']} | `{r['stamp']}` | {r['suite']} | {r['backends']} |")
if not thr_rows:
    lines.append("| — | — | — | — |")

lines += [
    "",
    "### Scheduling runs",
    "",
    "| When | Model | Scenarios | Folder |",
    "| --- | --- | --- | --- |",
]
for r in sch_rows:
    lines.append(
        f"| {r['when']} | {r['model']} | {r['scenarios']} | [{r['stamp']}]({r['dir']}/) |"
    )
if not sch_rows:
    lines.append("| — | — | — | — |")

lines += ["", "</details>", "", "Neu bauen: `./bench index`", ""]
with open(index_md, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

# --- HTML ---
sch_table = ""
if sch_recs:
    for r in sch_recs:
        gain = "—"
        gcls = ""
        if r.get("interleave_gain") and r["interleave_gain"] > 2:
            gain = f"{r['interleave_gain']:.0f}×"
            gcls = "pos"
        cb, _pp_on, _pp_off = cont_batch_pp_for_model(r["model"])
        b_disp = fmt_b(r.get("best_b"))
        b_cls = "best" if b_disp != "64†" else "pending"
        mtp = r.get("best_mtp") or "—"
        mtp_cls = "best" if mtp not in ("—", "off", "") else ""
        sch_table += (
            f"<tr><td>{esc(r['model'])}</td>"
            f'<td class="n best">{esc(r.get("best_np", "—"))}</td>'
            f'<td class="n best">{esc(r.get("best_ub", "—"))}</td>'
            f'<td class="n {b_cls}" title="n_batch — Sweep 06 noch offen">{esc(b_disp)}</td>'
            f'<td class="n best">{esc(r.get("best_c", "—"))}</td>'
            f'<td class="n {mtp_cls}">{esc(mtp)}</td>'
            f'<td>{esc(cb)}</td>'
            f'<td class="n">{fmt_num(r.get("prefill_tps"))}</td>'
            f'<td class="n">{fmt_num(r.get("prefill_ttft"))}</td>'
            f'<td class="n">{fmt_num(r.get("decode_tps"))}</td>'
            f'<td class="n">{fmt_num(r.get("decode_ms"))}</td>'
            f'<td class="n">{fmt_num(r.get("tg_idle"))}</td>'
            f'<td class="n {gcls}">{gain}</td></tr>'
        )
else:
    sch_table = '<tr><td colspan="13" class="meta">No data yet — <code>./bench sched --auto</code></td></tr>'

apply_plan_path = os.path.join(sch, "latest", "apply-plan.json")
apply_table = ""
global_cb = "1"
if os.path.isfile(apply_plan_path):
    with open(apply_plan_path, encoding="utf-8") as f:
        apply_data = json.load(f)
    for p in apply_data.get("plans") or []:
        apply_table += (
            f"<tr><td>{esc(p.get('model', '—'))}</td>"
            f'<td class="n">{esc(p.get("np") or "—")}</td>'
            f'<td class="n">{esc(p.get("ub") or "—")}</td>'
            f'<td class="n">{esc(fmt_b(p.get("b")))}</td>'
            f'<td class="n">{esc(p.get("c") or "—")}</td>'
            f'<td>{esc(p.get("cont_batching", "—"))}</td></tr>'
        )
    if apply_data.get("global_cont_batching") is not None:
        global_cb = "1" if apply_data["global_cont_batching"] else "0"

thr_table = ""
if thr_models:
    for m in thr_models:
        thr_table += (
            f"<tr><td>{esc(m['model'])}</td>"
            f'<td class="n pos">{esc(m["pp"])}</td>'
            f'<td class="n">{esc(m["tg"])}</td></tr>'
        )
else:
    thr_table = '<tr><td colspan="3" class="meta">No data yet</td></tr>'

status_table = ""
for r in status_rows:
    done = "done" if "complete" in r["status"] else ""
    status_table += (
        f'<tr class="{done}"><td>{esc(r["model"])}</td>'
        f'<td>{esc(r["status"])}</td>'
        f'<td class="n best">{esc(r["best_np"])}</td>'
        f'<td class="n best">{esc(r["best_ub"])}</td>'
        f'<td class="n best">{esc(r["best_b"])}</td>'
        f'<td class="n">{esc(r.get("best_mtp", "—"))}</td>'
        f'<td class="n">{fmt_num(r.get("prefill_ttft"))}</td>'
        f'<td class="n">{fmt_num(r.get("decode_tps"))}</td>'
        f'<td class="n">{fmt_num(r.get("decode_ms"))}</td></tr>'
    )

hist_thr = ""
for r in thr_rows:
    hist_thr += (
        f"<tr><td>{esc(r['when'])}</td><td><code>{esc(r['stamp'])}</code></td>"
        f"<td>{esc(r['suite'])}</td><td>{esc(r['backends'])}</td></tr>"
    )
hist_sch = ""
for r in sch_rows:
    hist_sch += (
        f"<tr><td>{esc(r['when'])}</td><td>{esc(r['model'])}</td>"
        f"<td>{esc(r['scenarios'])}</td>"
        f'<td><a href="{esc(r["dir"])}/">{esc(r["stamp"])}</a></td></tr>'
    )

page = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Bench Dashboard</title>
<style>
:root {{ color-scheme: dark; }}
body {{ font: 15px/1.5 system-ui, sans-serif; margin: 2rem; max-width: 1100px;
  background: #12141a; color: #e8eaed; }}
h1 {{ font-size: 1.4rem; margin-bottom: .2rem; }}
h2 {{ font-size: 1.05rem; margin: 2rem 0 .6rem; color: #c4c7cc; }}
.meta {{ color: #9aa0a6; font-size: .9rem; }}
a {{ color: #8ab4f8; }}
.more {{ font-size: .85rem; margin: .25rem 0 1rem; }}
table {{ border-collapse: collapse; width: 100%; margin: .5rem 0 1rem; }}
th, td {{ padding: .45rem .65rem; border-bottom: 1px solid #2a2e37; }}
th {{ text-align: left; color: #9aa0a6; font-weight: 600; }}
td.n, th.n {{ text-align: right; font-variant-numeric: tabular-nums;
  font-family: ui-monospace, monospace; }}
.best {{ color: #7ddea5; font-weight: 600; }}
.pos {{ color: #7ddea5; }}
tr.done td {{ opacity: .85; }}
.card {{ background: #1a1d24; border-radius: 8px; padding: 1rem 1.25rem; margin: 1rem 0; }}
.card h2 {{ margin-top: 0; }}
details {{ margin-top: 2.5rem; }}
summary {{ cursor: pointer; color: #9aa0a6; font-weight: 600; }}
.legend {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: .5rem; margin: .75rem 0; font-size: .85rem; }}
.legend span {{ background: #12141a; padding: .4rem .6rem; border-radius: 4px; display: block; }}
.pending {{ color: #f0c674; }}
.ok {{ color: #7ddea5; }}
.fail {{ color: #f28b82; }}
.scroll {{ overflow-x: auto; margin: .5rem 0 1.25rem; }}
.scroll table {{ min-width: 520px; }}
.btn {{ display: inline-block; margin: .35rem .5rem .35rem 0; padding: .55rem 1rem;
  background: #3d5a3d; color: #e8eaed; border: none; border-radius: 6px; cursor: pointer;
  font: inherit; text-decoration: none; }}
.btn:hover {{ background: #4a6b4a; }}
.btn.secondary {{ background: #2a3444; }}
.btn.secondary:hover {{ background: #354152; }}
.cmd {{ background: #12141a; padding: .75rem 1rem; border-radius: 6px; font-family: ui-monospace, monospace;
  font-size: .85rem; margin: .5rem 0; overflow-x: auto; }}
h3 {{ font-size: .95rem; margin: 1.25rem 0 .4rem; color: #c4c7cc; }}
.charts {{ display: grid; grid-template-columns: 1fr; gap: 1.25rem; }}
@media (min-width: 900px) {{
  .charts.two {{ grid-template-columns: 1fr 1fr; }}
}}
.chart-box {{ background: #12141a; border-radius: 6px; padding: .75rem 1rem 1rem; }}
.chart-box h3 {{ margin-top: 0; }}
.chart-wrap {{ position: relative; height: 280px; }}
.metric-tabs {{ margin: .5rem 0 1rem; }}
.metric-tabs .btn {{ margin-right: .35rem; }}
.metric-tabs .btn.active {{ background: #3d5a3d; }}
select.model-pick {{ background: #12141a; color: #e8eaed; border: 1px solid #2a2e37;
  border-radius: 4px; padding: .35rem .5rem; font: inherit; margin: .25rem 0 .75rem; }}
</style>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
</head><body>

<h1>Bench Dashboard</h1>
<p class="meta">Measured benches · Prefill/TG tok/s = under load / idle · Capacity = GTT · prefill time · prefill tok/s by KV</p>
{{LOCAL_NAV}}

{host_html_card(host)}

{fingerprint_html(host)}

{matrix_phase_html()}

<div class="card" id="charts">
<h2>Charts</h2>
<p class="meta">Overview (Chart.js). Capacity lines = solo + dual GTT / Prefill vs context — pick metric + model.</p>
<div class="charts two">
  <div class="chart-box">
    <h3>Throughput — PP vs TG (tok/s)</h3>
    <div class="chart-wrap"><canvas id="chart-thr"></canvas></div>
  </div>
  <div class="chart-box">
    <h3>Scheduling — Prefill tok/s &amp; Decode ms</h3>
    <div class="chart-wrap"><canvas id="chart-sched"></canvas></div>
  </div>
</div>
<div class="chart-box" style="margin-top:1.25rem">
  <h3>Capacity vs context (per KV quant)</h3>
  <label class="meta" for="cap-model">Model </label>
  <select id="cap-model" class="model-pick"></select>
  <label class="meta" for="cap-y">Y </label>
  <select id="cap-y" class="model-pick">
    <option value="gtt_gib">GTT GiB</option>
    <option value="prefill_tok_s">Prefill tok/s</option>
    <option value="prefill_s">Prefill time (s)</option>
    <option value="power_w">GPU watts (avg)</option>
  </select>
  <div class="chart-wrap" style="height:320px"><canvas id="chart-cap"></canvas></div>
</div>
</div>

{max_ok_context_html()}

{capacity_html_card()}

<div class="card">
<h2>Scheduling — np / ub / b / MTP <span class="meta">sweep winners · under load</span></h2>
<p class="more"><a href="scheduling/latest/compare.html">→ Details &amp; sweeps per model</a></p>
<div class="legend">
  <span><strong>np ★</strong> parallel slots (--parallel)</span>
  <span><strong>ub ★</strong> Micro-Batch / PP-Chunk (n_ubatch)</span>
  <span><strong>b ★</strong> Max-Batch (n_batch) — † = default 64, sweep still pending</span>
  <span><strong>MTP ★</strong> draft-mtp n-max (or off)</span>
  <span><strong>TTFT</strong> prefill time-to-first-token under load (ms)</span>
  <span><strong>Decode tok/s</strong> generation under load (slot A)</span>
  <span><strong>Prefill tok/s</strong> prompt throughput under load (interleave)</span>
  <span><strong>TG tok/s</strong> Generation solo (Throughput-Bench)</span>
  <span><strong>cont-batch</strong> continuous batching on/off</span>
</div>
<table><thead><tr>
<th>Model</th><th class="n">np ★</th><th class="n">ub ★</th><th class="n">b ★</th><th class="n">c ★</th>
<th class="n">MTP ★</th>
<th>cont-batch</th><th class="n">Prefill tok/s</th><th class="n">TTFT ms</th>
<th class="n">Decode tok/s</th><th class="n">Decode ms</th>
<th class="n">TG tok/s</th><th class="n">Interleave</th>
</tr></thead><tbody>{sch_table}</tbody></table>
</div>

<div class="card">
<h2>Throughput — which model is fastest?</h2>
<p class="more"><a href="throughput/latest/compare.html">→ Details</a> · PP/TG tok/s · <strong>higher = better</strong></p>
<table><thead><tr>
<th>Model</th><th class="n">PP (512 tok)</th><th class="n">TG (128 tok)</th>
</tr></thead><tbody>{thr_table}</tbody></table>
</div>
"""

# Quality card
qual_table = ""
if qual_rows:
    for r in qual_rows:
        p1, p10 = r.get("pass_at_1"), r.get("pass_at_10")
        qual_table += (
            f"<tr><td>{esc(r.get('suite','—'))}</td>"
            f"<td><code>{esc(r.get('model','—'))}</code></td>"
            f'<td class="n">{fmt_num(p1, 3) if isinstance(p1, float) else esc(p1 or "—")}</td>'
            f'<td class="n">{fmt_num(p10, 3) if isinstance(p10, float) else esc(p10 or "—")}</td>'
            f"<td><code>{esc(r.get('stamp','—'))}</code></td></tr>"
        )
else:
    qual_table = (
        '<tr><td colspan="5" class="meta">No data yet — '
        '<code>./bench quality humaneval --model …</code></td></tr>'
    )

page += f"""
<div class="card">
<h2>Quality — HumanEval &amp; plugins</h2>
<p class="more"><a href="quality/latest/compare.md">→ Details</a> · <code>./bench quality list</code></p>
<table><thead><tr>
<th>Suite</th><th>Model</th><th class="n">pass@1</th><th class="n">pass@10</th><th>Stamp</th>
</tr></thead><tbody>{qual_table}</tbody></table>
</div>
"""

if status_table:
    page += f"""
<div class="card">
<h2>Matrix progress</h2>
<table><thead><tr>
<th>Model</th><th>Status</th><th class="n">np ★</th><th class="n">ub ★</th><th class="n">b ★</th>
<th class="n">MTP ★</th><th class="n">TTFT ms</th><th class="n">Decode tok/s</th><th class="n">Decode ms</th>
</tr></thead><tbody>{status_table}</tbody></table>
</div>
"""

local_tools = f"""
<div class="card" id="local-tools">
<h2>Local only — recommendations / apply</h2>
<p class="meta">Not published to GitHub Pages. Planner + INI apply stay on the bench host.</p>
<p class="more"><a href="planner.html"><strong>→ Recommendation planner</strong></a>
  — host RAM/GTT · capacity max c · download plan.json</p>
<p class="meta"><code>models-*.ini</code> · cont-batch advisory</p>
<div class="cmd" id="apply-cmd">./bench apply-ini --dry-run</div>
<button type="button" class="btn" onclick="navigator.clipboard.writeText('./bench apply-ini --dry-run')">Copy dry-run</button>
<button type="button" class="btn secondary" onclick="navigator.clipboard.writeText('./bench apply-ini')">Copy apply</button>
<p class="more"><a href="scheduling/latest/apply-plan.json">→ apply-plan.json</a> · cont-batching global: <strong>{'on' if global_cb == '1' else 'off'}</strong></p>
<table><thead><tr>
<th>Model</th><th class="n">np</th><th class="n">ub</th><th class="n">b</th><th class="n">c</th><th>cont-batch</th>
</tr></thead><tbody>{apply_table or '<tr><td colspan="6" class="meta">No plan yet — run <code>./bench apply-ini --dry-run</code> first</td></tr>'}</tbody></table>
</div>
"""

# Chart.js payloads (Pages-safe measured data only)
def _short(name, n=28):
    s = str(name or "")
    return s if len(s) <= n else s[: n - 1] + "…"

def _num(x):
    if x is None or x == "" or x == "—":
        return None
    if isinstance(x, (int, float)):
        return float(x)
    try:
        return float(str(x).replace(",", ""))
    except ValueError:
        return None

thr_chart = {
    "labels": [_short(m["model"]) for m in thr_models],
    "pp": [_num(m.get("pp")) for m in thr_models],
    "tg": [_num(m.get("tg")) for m in thr_models],
}
sch_chart = {
    "labels": [_short(r.get("model")) for r in sch_recs],
    "prefill": [_num(r.get("prefill_tps")) for r in sch_recs],
    "decode": [_num(r.get("decode_ms")) for r in sch_recs],
}
# capacity: model -> {kv|kv dual -> [{c, gtt_gib, prefill_s, prefill_tok_s}]}
cap_chart = {}
for r in cap_latest.values():
    if r.get("skipped") or not r.get("ok"):
        continue
    mode = r.get("mode") or "solo"
    if mode not in ("solo", "dual"):
        continue
    model = r.get("model") or "?"
    kv = r.get("kv") or "?"
    if mode == "dual":
        kv = f"{kv} dual"
        peak = r.get("metrics_peak") or {}
        mem_a = r.get("mem_after") or {}
        gtt_mb = peak.get("gtt_used_mb") or mem_a.get("gtt_used_mb")
        gtt_gib = round(float(gtt_mb) / 1024.0, 2) if gtt_mb is not None else None
        point = {
            "c": int(r.get("c") or 0),
            "gtt_gib": gtt_gib,
            "prefill_s": None,
            "prefill_tok_s": None,
            "power_w": peak.get("power_w_avg") if peak.get("power_w_avg") is not None else peak.get("power_w_peak"),
        }
    else:
        m = cap_metrics(r)
        if not m:
            continue
        point = {
            "c": int(r.get("c") or 0),
            "gtt_gib": m.get("gtt_gib"),
            "prefill_s": m.get("prefill_s"),
            "prefill_tok_s": m.get("prefill_tok_s"),
            "power_w": m.get("power_w_avg") if m.get("power_w_avg") is not None else m.get("power_w_peak"),
        }
    cap_chart.setdefault(model, {}).setdefault(kv, []).append(point)
for model in cap_chart:
    for kv in cap_chart[model]:
        cap_chart[model][kv] = sorted(cap_chart[model][kv], key=lambda p: p["c"])

chart_json = json.dumps(
    {"throughput": thr_chart, "scheduling": sch_chart, "capacity": cap_chart},
    ensure_ascii=False,
)

footer = f"""
<details>
<summary>Run history ({len(thr_rows)} throughput · {len(sch_rows)} scheduling)</summary>
<h2>Throughput runs</h2>
<table><thead><tr><th>When</th><th>Stamp</th><th>Suite</th><th>Backends</th></tr></thead>
<tbody>{hist_thr or '<tr><td colspan="4">—</td></tr>'}</tbody></table>
<h2>Scheduling runs</h2>
<table><thead><tr><th>When</th><th>Model</th><th>Scenarios</th><th>Folder</th></tr></thead>
<tbody>{hist_sch or '<tr><td colspan="4">—</td></tr>'}</tbody></table>
</details>

<script id="bench-chart-data" type="application/json">{chart_json.replace("<", "\\\\u003c")}</script>
<script>
(function () {{
  const raw = document.getElementById("bench-chart-data");
  if (!raw || typeof Chart === "undefined") return;
  const DATA = JSON.parse(raw.textContent);
  const tick = {{ color: "#9aa0a6" }};
  const grid = {{ color: "#2a2e37" }};
  const common = {{
    responsive: true,
    maintainAspectRatio: false,
    plugins: {{ legend: {{ labels: {{ color: "#c4c7cc" }} }} }},
  }};

  const thr = DATA.throughput || {{}};
  if ((thr.labels || []).length) {{
    new Chart(document.getElementById("chart-thr"), {{
      type: "bar",
      data: {{
        labels: thr.labels,
        datasets: [
          {{ label: "PP tok/s", data: thr.pp, backgroundColor: "#5b8def" }},
          {{ label: "TG tok/s", data: thr.tg, backgroundColor: "#7ddea5" }},
        ],
      }},
      options: {{
        ...common,
        scales: {{
          x: {{ ticks: tick, grid }},
          y: {{ ticks: tick, grid, title: {{ display: true, text: "tok/s", color: "#9aa0a6" }} }},
        }},
      }},
    }});
  }}

  const sch = DATA.scheduling || {{}};
  if ((sch.labels || []).length) {{
    new Chart(document.getElementById("chart-sched"), {{
      type: "bar",
      data: {{
        labels: sch.labels,
        datasets: [
          {{ label: "Prefill tok/s", data: sch.prefill, backgroundColor: "#5b8def", yAxisID: "y" }},
          {{ label: "Decode ms", data: sch.decode, backgroundColor: "#f0c674", yAxisID: "y1" }},
        ],
      }},
      options: {{
        ...common,
        scales: {{
          x: {{ ticks: tick, grid }},
          y: {{ position: "left", ticks: tick, grid, title: {{ display: true, text: "tok/s", color: "#9aa0a6" }} }},
          y1: {{ position: "right", ticks: tick, grid: {{ drawOnChartArea: false }}, title: {{ display: true, text: "ms", color: "#9aa0a6" }} }},
        }},
      }},
    }});
  }}

  const cap = DATA.capacity || {{}};
  const models = Object.keys(cap).sort();
  const sel = document.getElementById("cap-model");
  const ySel = document.getElementById("cap-y");
  const canvas = document.getElementById("chart-cap");
  let capChart = null;
  const palette = ["#5b8def", "#7ddea5", "#f0c674", "#f28b82", "#c58af9", "#78d4e8"];
  const yLabels = {{ gtt_gib: "GTT GiB", prefill_tok_s: "Prefill tok/s", prefill_s: "Prefill s", power_w: "Watts" }};

  function renderCap(model) {{
    const yKey = (ySel && ySel.value) || "gtt_gib";
    const series = cap[model] || {{}};
    const kvs = Object.keys(series).sort();
    const datasets = kvs.map((kv, i) => ({{
      label: kv,
      data: (series[kv] || [])
        .filter((p) => p[yKey] != null)
        .map((p) => ({{ x: p.c, y: p[yKey] }})),
      borderColor: palette[i % palette.length],
      backgroundColor: palette[i % palette.length],
      tension: 0.15,
      showLine: true,
    }}));
    if (capChart) capChart.destroy();
    capChart = new Chart(canvas, {{
      type: "scatter",
      data: {{ datasets }},
      options: {{
        ...common,
        scales: {{
          x: {{
            type: "linear",
            ticks: tick,
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
      o.textContent = m;
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

<p class="meta">Rebuild: <code>./bench index</code></p>
</body></html>"""

# Local full dashboard (benches + capacity + local apply/planner)
LOCAL_NAV = '<p class="more"><a href="#fingerprint">Fingerprint</a> · <a href="#charts">Charts</a> · <a href="#max-ctx">Max context</a> · <a href="#capacity">Capacity</a> · <a href="#local-tools">Local apply / planner</a></p>'
page_local = page.replace("{LOCAL_NAV}", LOCAL_NAV) + local_tools + footer

# GitHub Pages: measured benches only (no recommendations / apply / planner)
LOCAL_NAV = '<p class="more"><a href="#fingerprint">Fingerprint</a> · <a href="#charts">Charts</a> · <a href="#max-ctx">Max context</a> · <a href="#capacity">Capacity</a></p>'
page_pages = page.replace("{LOCAL_NAV}", LOCAL_NAV) + footer
page_pages = page_pages.replace(
    "<h1>Bench Dashboard</h1>",
    "<h1>Bench Dashboard</h1>\n<p class=\"meta\">Public benchmark results only — recommendations stay local.</p>",
    1,
)

pages_html = os.path.join(out_root, "pages-index.html")
with open(index_html, "w", encoding="utf-8") as f:
    f.write(page_local)
with open(pages_html, "w", encoding="utf-8") as f:
    f.write(page_pages)

# Refresh capacity compare.md with tok/s if ledger exists
if cap_cells:
    cap_md_out = os.path.join(cap_root, "latest", "compare.md")
    os.makedirs(os.path.dirname(cap_md_out), exist_ok=True)
    with open(cap_md_out, "w", encoding="utf-8") as f:
        f.write("# Capacity ledger (latest per cell)\n\n")
        f.write(f"Cells: {cap_cells}\n\nCell = GTT MiB · prefill s · prefill tok/s (TTFT ≈ prefill)\n\n")
        f.write("\n".join(capacity_md_tables()) + "\n")

print(f"Wrote {index_md}")
print(f"Wrote {index_html} (local: benches + apply/planner)")
print(f"Wrote {pages_html} (GitHub Pages: benches only)")
print(f"  scheduling models: {len(sch_recs)}")
print(f"  throughput models: {len(thr_models)}")
print(f"  capacity cells: {cap_cells}")
PY

# Interactive dual/solo recommendation planner (local only — not published)
bash "$SCRIPT_DIR/build-planner.sh"
