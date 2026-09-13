#!/usr/bin/env bash
# Build output/bench/index.md + index.html — dashboard with recommendations.
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
    has_ub = "04_ub_sweep" in scenarios
    has_np = "05_np_sweep" in scenarios
    has_b = "06_b_sweep" in scenarios
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
        status = "✓ komplett"
    rec = next((r for r in sch_recs if r.get("model") == model), {})
    status_rows.append({
        "model": model,
        "status": status,
        "best_np": rec.get("best_np", "—"),
        "best_ub": rec.get("best_ub", "—"),
        "best_b": fmt_b(rec.get("best_b")),
        "decode_ms": rec.get("decode_ms"),
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
    rows = [
        row("Host", h.get("hostname") or "—"),
        row("OS", h.get("os") or "—"),
        row("Kernel", h.get("kernel") or "—"),
        row("CPU", f"{h.get('cpu') or '—'} ({h.get('nproc') or '?'} threads)"),
        row("RAM", f"{h.get('ram_gib') or '—'} GiB"),
        row("GTT (UMA)", f"{h.get('gtt_total_gib') or '—'} GiB"),
        row("Visible VRAM", f"{h.get('vram_total_mib') or '—'} MiB"),
        row("GPU", h.get("gpu") or "—"),
        row("Backend", h.get("backend_default") or "—"),
        row("Image", f"{h.get('docker_image') or '—'} ({h.get('docker_image_id_short') or '—'})"),
        row("llama.cpp", f"{pin.get('ref') or '—'} @ {commit_s}"),
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
        "| Model | np ★ | ub ★ | b ★ | c ★ | cont-batch | Prefill tok/s | TG tok/s | PP on | PP off | Decode ms | Interleave |",
        "| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for r in sch_recs:
        gain = "—"
        if r.get("interleave_gain") and r["interleave_gain"] > 2:
            gain = f"{r['interleave_gain']:.0f}×"
        cb, pp_on, pp_off = cont_batch_pp_for_model(r["model"])
        lines.append(
            f"| {r['model']} | **{r.get('best_np', '—')}** | **{r.get('best_ub', '—')}** | "
            f"**{fmt_b(r.get('best_b'))}** | **{r.get('best_c', '—')}** | {cb} | "
            f"{fmt_num(r.get('prefill_tps'))} | {fmt_num(r.get('tg_idle'))} | "
            f"{fmt_num(pp_on)} | {fmt_num(pp_off)} | {fmt_num(r.get('decode_ms'))} | {gain} |"
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

# Capacity (KV×ctx / dual)
cap_root = os.path.join(out_root, "capacity")
cap_cmp = os.path.join(cap_root, "latest", "compare.md")
cap_cells = 0
cap_ledger = os.path.join(cap_root, "cells.jsonl")
if os.path.isfile(cap_ledger):
    with open(cap_ledger, encoding="utf-8") as f:
        cap_cells = sum(1 for line in f if line.strip())
lines += ["", "## Capacity — KV×ctx / dual", ""]
if os.path.isfile(cap_cmp):
    lines += [
        f"[Details →]({rel('capacity/latest/compare.md')}) · "
        f"ledger cells: **{cap_cells}** · `./bench capacity kv-ctx`",
        "",
        "```bash",
        "./bench capacity kv-ctx --model Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL",
        "./bench capacity dual --kv q5_0,q4_0   # c auto from RAM/GTT",
        "```",
    ]
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
        "| Model | Status | np ★ | ub ★ | b ★ | Decode ms |",
        "| --- | --- | ---: | ---: | ---: | ---: |",
    ]
    for r in status_rows:
        lines.append(
            f"| {r['model']} | {r['status']} | {r['best_np']} | {r['best_ub']} | "
            f"{r['best_b']} | {fmt_num(r.get('decode_ms'))} |"
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
        cb, pp_on, pp_off = cont_batch_pp_for_model(r["model"])
        b_disp = fmt_b(r.get("best_b"))
        b_cls = "best" if b_disp != "64†" else "pending"
        sch_table += (
            f"<tr><td>{esc(r['model'])}</td>"
            f'<td class="n best">{esc(r.get("best_np", "—"))}</td>'
            f'<td class="n best">{esc(r.get("best_ub", "—"))}</td>'
            f'<td class="n {b_cls}" title="n_batch — Sweep 06 noch offen">{esc(b_disp)}</td>'
            f'<td class="n best">{esc(r.get("best_c", "—"))}</td>'
            f'<td>{esc(cb)}</td>'
            f'<td class="n">{fmt_num(r.get("prefill_tps"))}</td>'
            f'<td class="n">{fmt_num(r.get("tg_idle"))}</td>'
            f'<td class="n">{fmt_num(pp_on)}</td>'
            f'<td class="n">{fmt_num(pp_off)}</td>'
            f'<td class="n">{fmt_num(r.get("decode_ms"))}</td>'
            f'<td class="n {gcls}">{gain}</td></tr>'
        )
else:
    sch_table = '<tr><td colspan="12" class="meta">No data yet — <code>./bench sched --auto</code></td></tr>'

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
    done = "done" if "komplett" in r["status"] else ""
    status_table += (
        f'<tr class="{done}"><td>{esc(r["model"])}</td>'
        f'<td>{esc(r["status"])}</td>'
        f'<td class="n best">{esc(r["best_np"])}</td>'
        f'<td class="n best">{esc(r["best_ub"])}</td>'
        f'<td class="n best">{esc(r["best_b"])}</td>'
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
.btn {{ display: inline-block; margin: .35rem .5rem .35rem 0; padding: .55rem 1rem;
  background: #3d5a3d; color: #e8eaed; border: none; border-radius: 6px; cursor: pointer;
  font: inherit; text-decoration: none; }}
.btn:hover {{ background: #4a6b4a; }}
.btn.secondary {{ background: #2a3444; }}
.btn.secondary:hover {{ background: #354152; }}
.cmd {{ background: #12141a; padding: .75rem 1rem; border-radius: 6px; font-family: ui-monospace, monospace;
  font-size: .85rem; margin: .5rem 0; overflow-x: auto; }}
</style></head><body>

<h1>Bench Dashboard</h1>
<p class="meta">★ = recommended sweep value · Prefill/TG tok/s = under load / idle</p>
<p class="more"><a href="planner.html"><strong>→ Recommendation planner</strong></a> (1 vs 2 stickys · capacity max c · download plan.json)</p>

{host_html_card(host)}

<div class="card" id="apply">
<h2>Apply settings</h2>
<p class="meta"><code>models-lab.ini</code> (np/ub/b/c) · cont-batch = advisory in apply-plan</p>
<div class="cmd" id="apply-cmd">./bench apply-ini --lab</div>
<button type="button" class="btn" onclick="navigator.clipboard.writeText(document.getElementById('apply-cmd').textContent)">Copy apply command</button>
<button type="button" class="btn secondary" onclick="navigator.clipboard.writeText('./bench apply-ini --dry-run --lab')">Copy dry-run</button>
<p class="more"><a href="scheduling/latest/apply-plan.json">→ apply-plan.json</a> · cont-batching global: <strong>{'on' if global_cb == '1' else 'off'}</strong></p>
<table><thead><tr>
<th>Model</th><th class="n">np</th><th class="n">ub</th><th class="n">b</th><th class="n">c</th><th>cont-batch</th>
</tr></thead><tbody>{apply_table or '<tr><td colspan="6" class="meta">No plan yet — run <code>./bench apply-ini --dry-run --lab</code> first</td></tr>'}</tbody></table>
</div>

<div class="card">
<h2>Scheduling — np / ub / b <span class="meta">low decode · fast prefill</span></h2>
<p class="more"><a href="scheduling/latest/compare.html">→ Details &amp; sweeps per model</a></p>
<div class="legend">
  <span><strong>np ★</strong> parallel slots (--parallel)</span>
  <span><strong>ub ★</strong> Micro-Batch / PP-Chunk (n_ubatch)</span>
  <span><strong>b ★</strong> Max-Batch (n_batch) — † = default 64, sweep still pending</span>
  <span><strong>Prefill tok/s</strong> prompt throughput under load (interleave)</span>
  <span><strong>TG tok/s</strong> Generation solo (Throughput-Bench)</span>
  <span><strong>cont-batch</strong> continuous batching on/off</span>
  <span><strong>PP on/off</strong> solo 4k prefill tok/s</span>
</div>
<table><thead><tr>
<th>Model</th><th class="n">np ★</th><th class="n">ub ★</th><th class="n">b ★</th><th class="n">c ★</th>
<th>cont-batch</th><th class="n">Prefill tok/s</th><th class="n">TG tok/s</th>
<th class="n">PP on</th><th class="n">PP off</th>
<th class="n">Decode ms</th><th class="n">Interleave</th>
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
<th>Model</th><th>Status</th><th class="n">np ★</th><th class="n">ub ★</th><th class="n">b ★</th><th class="n">Decode ms</th>
</tr></thead><tbody>{status_table}</tbody></table>
</div>
"""

page += f"""
<details>
<summary>Run history ({len(thr_rows)} throughput · {len(sch_rows)} scheduling)</summary>
<h2>Throughput runs</h2>
<table><thead><tr><th>When</th><th>Stamp</th><th>Suite</th><th>Backends</th></tr></thead>
<tbody>{hist_thr or '<tr><td colspan="4">—</td></tr>'}</tbody></table>
<h2>Scheduling runs</h2>
<table><thead><tr><th>When</th><th>Model</th><th>Scenarios</th><th>Folder</th></tr></thead>
<tbody>{hist_sch or '<tr><td colspan="4">—</td></tr>'}</tbody></table>
</details>

<p class="meta">Rebuild: <code>./bench index</code></p>
</body></html>"""

with open(index_html, "w", encoding="utf-8") as f:
    f.write(page)

print(f"Wrote {index_md}")
print(f"Wrote {index_html}")
print(f"  scheduling models: {len(sch_recs)}")
print(f"  throughput models: {len(thr_models)}")
PY

# Interactive dual/solo recommendation planner
bash "$SCRIPT_DIR/build-planner.sh"
