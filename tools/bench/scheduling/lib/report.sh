#!/usr/bin/env bash
# Build scheduling compare.md + compare.html from run directories.
set -euo pipefail

report_latest() {
  local out_root="${SCHED_OUT:-$PROJECT_ROOT/output/bench/scheduling}"
  local thr_root="${PROJECT_ROOT}/output/bench/throughput"
  local latest_dir="$out_root/latest"
  local latest_md="$latest_dir/compare.md"
  local latest_html="$latest_dir/compare.html"
  mkdir -p "$latest_dir"
  bench_python - "$out_root" "$thr_root" "$latest_md" "$latest_html" <<'PY'
import glob, html, json, os, re, sys
from collections import defaultdict

out_root, thr_root, latest_md, latest_html = sys.argv[1:5]

TTFT_INVALID_MS = 5000.0
DECODE_OK_MS = 50.0


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def fmt_num(x, digits=1):
    if x is None or x == "":
        return "—"
    if isinstance(x, (int, float)):
        if abs(x) >= 1000:
            return f"{x:,.0f}"
        return f"{x:.{digits}f}"
    return str(x)


def decode_ms(slot):
    if not slot:
        return None
    p50 = slot.get("token_interval_ms_p50")
    p95 = slot.get("token_interval_ms_p95")
    if p95 is not None and (p50 is None or p50 < 1.0):
        return p95
    return p50 if p50 is not None else p95


def slot_ok(slot, need_chunks=True):
    if not slot:
        return False
    if need_chunks and not slot.get("chunks"):
        return False
    return True


def ttft_valid(v):
    return v is not None and v < TTFT_INVALID_MS


def load_throughput():
    """Latest lab vulkan PP/TG per model basename."""
    import csv
    pp, tg = {}, {}
    csvs = sorted(glob.glob(os.path.join(thr_root, "llama-bench-*-lab-vulkan.csv")), reverse=True)
    for path in csvs:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.reader(f)
            header = None
            for row in reader:
                if not row:
                    continue
                if row[0] == "build_commit":
                    header = row
                    continue
                if header is None or len(row) < len(header):
                    continue
                data = dict(zip(header, row))
                name = os.path.basename(data.get("model_filename", "")).replace(".gguf", "")
                if not name:
                    continue
                try:
                    ts = float(data.get("avg_ts") or 0)
                except ValueError:
                    continue
                if ts <= 0:
                    continue
                n_prompt = data.get("n_prompt", "0")
                n_gen = data.get("n_gen", "0")
                if n_prompt != "0" and name not in pp:
                    pp[name] = ts
                if n_gen != "0" and name not in tg:
                    tg[name] = ts
        if pp:
            break
    return pp, tg


def throughput_key(model):
    """Map scheduling model name to throughput CSV basename."""
    base = model.replace("-VL", "").replace("-MTP", "")
    if base.endswith("-Q4_K_M") or base.endswith("-Q5_K_XL"):
        return base
    return base


def extract_scenario_row(man, scen, summ, ub_override=None):
    if summ.get("scenario") in ("04_ub_sweep", "05_np_sweep", "06_b_sweep", "08_ctx_sweep"):
        return None
    slot_a = summ.get("slot_a") or summ.get("decode") or {}
    slot_b = summ.get("slot_b") or summ.get("prefill") or {}
    if scen in ("01_baseline_solo", "03_interleave_np2") and not slot_ok(slot_a):
        return None
    if scen == "02_blocked_np1" and not slot_ok(slot_a) and not slot_ok(slot_b):
        return None
    return {
        "stamp": man.get("stamp", ""),
        "model": man.get("model", ""),
        "np": man.get("np", ""),
        "ub": ub_override if ub_override is not None else man.get("ub", ""),
        "scenario": scen,
        "decode_ms": decode_ms(slot_a),
        "decode_tps": slot_a.get("tokens_per_sec"),
        "prefill_ttft": slot_b.get("ttft_ms"),
        "prefill_tps": slot_b.get("tokens_per_sec"),
    }


def extract_sweep_rows(man, summ, param):
    rows = []
    if summ.get("scenario") not in ("04_ub_sweep", "05_np_sweep", "06_b_sweep", "08_ctx_sweep"):
        return rows
    for entry in summ.get("runs") or []:
        val = entry.get(param, "")
        inner = entry.get("summary") or {}
        slot_a = inner.get("slot_a") or inner.get("decode") or {}
        slot_b = inner.get("slot_b") or inner.get("prefill") or {}
        if param == "c":
            if not slot_ok(slot_a):
                continue
        elif not slot_ok(slot_a):
            continue
        row = {
            "stamp": man.get("stamp", ""),
            "model": man.get("model", ""),
            "np": man.get("np", ""),
            "ub": man.get("ub", ""),
            "b": man.get("b", ""),
            param: val,
            "scenario": inner.get("scenario", "03_interleave_np2"),
            "decode_ms": decode_ms(slot_a),
            "decode_tps": slot_a.get("tokens_per_sec"),
            "prefill_ttft": slot_b.get("ttft_ms") if slot_b else None,
            "prefill_tps": slot_b.get("tokens_per_sec") if slot_b else None,
            "vram_mb": entry.get("vram_mb"),
            "valid": True if param == "c" else ttft_valid((slot_b or {}).get("ttft_ms")),
        }
        rows.append(row)
    return rows


def pick_best_sweep(rows, param):
    valid = [r for r in rows if r.get("valid")]
    if not valid:
        return None, []
    def score(r):
        d = r.get("decode_ms") or 999
        t = r.get("prefill_ttft") or 999999
        p = -(r.get("prefill_tps") or 0)
        return (d, t, p)
    ranked = sorted(valid, key=score)
    best = ranked[0][param]
    for r in ranked:
        r["best"] = r[param] == best
    return best, ranked


def pick_best_c(c_rows):
    valid = [r for r in c_rows if r.get("valid")]
    if not valid:
        return None, []
    ranked = sorted(valid, key=lambda r: int(r.get("c") or 0))
    best = ranked[-1]["c"]
    for r in ranked:
        r["best"] = str(r["c"]) == str(best)
    return best, ranked


def cont_batch_verdict(cont):
    if not cont:
        return "on (default)", None, {}
    rec = cont.get("recommended") or "on"
    on = off = {}
    for entry in cont.get("runs") or []:
        if entry.get("mode") == "cont_on":
            on = entry
        elif entry.get("mode") == "cont_off":
            off = entry
    label = f"{rec} ★" if rec in ("on", "off") else "on"
    return label, on.get("pp_tok_s"), {"on": on, "off": off, "recommended": rec}


SWEEP_MAP = {
    "04_ub_sweep": "ub",
    "05_np_sweep": "np",
    "06_b_sweep": "b",
    "08_ctx_sweep": "c",
}


# Collect per-model latest auto + sweeps
models = defaultdict(lambda: {
    "auto_stamp": "", "ub_stamp": "", "np_stamp": "", "b_stamp": "", "c_stamp": "",
    "cont_stamp": "", "fit_stamp": "", "mtp_stamp": "",
    "auto": {}, "ub_rows": [], "np_rows": [], "b_rows": [], "c_rows": [],
    "cont_batch": None, "fit_ctx": None, "mtp_sweep": None,
})

for run_dir in sorted(glob.glob(os.path.join(out_root, "20*"))):
    if not os.path.isdir(run_dir):
        continue
    man_path = os.path.join(run_dir, "manifest.json")
    if not os.path.isfile(man_path):
        continue
    man = load_json(man_path)
    model = man.get("model", "")
    stamp = man.get("stamp", os.path.basename(run_dir))
    if not model:
        continue

    auto = {}
    sweeps = {"ub_rows": [], "np_rows": [], "b_rows": [], "c_rows": []}
    cont_batch = None
    fit_ctx = None
    mtp_sweep = None
    for scen_dir in sorted(glob.glob(os.path.join(run_dir, "*"))):
        if not os.path.isdir(scen_dir):
            continue
        scen = os.path.basename(scen_dir)
        if scen == "latest":
            continue
        summ_path = os.path.join(scen_dir, "summary.json")
        if not os.path.isfile(summ_path):
            continue
        summ = load_json(summ_path)
        if scen == "07_cont_batch":
            if stamp >= models[model].get("cont_stamp", ""):
                cont_batch = summ
                models[model]["cont_stamp"] = stamp
            continue
        if scen in ("10_mtp_sweep", "05_mtp_compare"):
            if stamp >= models[model].get("mtp_stamp", ""):
                mtp_sweep = summ
                models[model]["mtp_stamp"] = stamp
            continue
        if scen == "09_fit_probe":
            if stamp >= models[model].get("fit_stamp", ""):
                fit_ctx = summ.get("context_length")
                models[model]["fit_stamp"] = stamp
            continue
        param = SWEEP_MAP.get(scen)
        if param:
            key = {"ub": "ub_rows", "np": "np_rows", "b": "b_rows", "c": "c_rows"}[param]
            sweeps[key].extend(extract_sweep_rows(man, summ, param))
        else:
            row = extract_scenario_row(man, scen, summ)
            if row:
                auto[scen] = row

    if auto and stamp >= models[model]["auto_stamp"]:
        models[model]["auto"] = auto
        models[model]["auto_stamp"] = stamp
    for key, stamp_key in [
        ("ub_rows", "ub_stamp"), ("np_rows", "np_stamp"), ("b_rows", "b_stamp"), ("c_rows", "c_stamp"),
    ]:
        if sweeps[key] and stamp >= models[model][stamp_key]:
            models[model][key] = sweeps[key]
            models[model][stamp_key] = stamp
    if cont_batch:
        models[model]["cont_batch"] = cont_batch
    if mtp_sweep:
        models[model]["mtp_sweep"] = mtp_sweep
    if fit_ctx:
        models[model]["fit_ctx"] = fit_ctx

pp_map, tg_map = load_throughput()

if not models:
    empty = "# Scheduling — compare\n\nNo runs yet. Start: `./bench sched --auto`\n"
    with open(latest_md, "w", encoding="utf-8") as f:
        f.write(empty)
    with open(latest_html, "w", encoding="utf-8") as f:
        f.write(f"<!DOCTYPE html><html><body><pre>{html.escape(empty)}</pre></body></html>")
    print(f"Wrote empty {latest_md}")
    sys.exit(0)

recommendations = []
model_sections_md = []
model_sections_html = []

for model in sorted(models.keys()):
    data = models[model]
    auto = data["auto"]
    ub_rows = data["ub_rows"]
    np_rows = data["np_rows"]
    b_rows = data["b_rows"]
    c_rows = data["c_rows"]
    best_ub, ranked_ub = pick_best_sweep(ub_rows, "ub")
    best_np, ranked_np = pick_best_sweep(np_rows, "np")
    best_b, ranked_b = pick_best_sweep(b_rows, "b")
    best_c, ranked_c = pick_best_c(c_rows)
    cb_verdict, _cb_pp, cb_detail = cont_batch_verdict(data.get("cont_batch"))
    mtp = data.get("mtp_sweep") or {}
    mtp_rec = mtp.get("recommended")
    fit_ctx = data.get("fit_ctx")
    vram_mb = None
    if ranked_c:
        for r in ranked_c:
            if r.get("best") and r.get("vram_mb"):
                vram_mb = r.get("vram_mb")

    solo = auto.get("01_baseline_solo", {})
    blocked = auto.get("02_blocked_np1", {})
    inter = auto.get("03_interleave_np2", {})

    inter_ttft = inter.get("prefill_ttft")
    blocked_ttft = blocked.get("prefill_ttft")
    interleave_gain = None
    if blocked_ttft and inter_ttft and ttft_valid(inter_ttft):
        interleave_gain = blocked_ttft / max(inter_ttft, 1)

    best_row = next((r for r in ranked_ub if r.get("best")), None)
    rec_decode = None
    if best_row:
        rec_decode = best_row.get("decode_ms")
    elif inter:
        rec_decode = inter.get("decode_ms")
    elif solo:
        rec_decode = solo.get("decode_ms")

    pp_idle, tg_idle = None, None
    for key in [model, model.replace("-VL", ""), model.replace("-MTP", "").replace("-VL", "")]:
        if key in pp_map:
            pp_idle = pp_map[key]
            tg_idle = tg_map.get(key)
            break
    if pp_idle is None:
        base = model.replace("-VL", "").replace("-MTP", "")
        for name, val in pp_map.items():
            if base.rstrip("-") in name or name in base:
                pp_idle = val
                tg_idle = tg_map.get(name)
                break

    rec = {
        "model": model,
        "best_ub": best_ub or "—",
        "best_np": best_np or "—",
        "best_b": best_b or "—",
        "best_c": best_c or "—",
        "best_mtp": mtp_rec or "—",
        "vram_mb": vram_mb,
        "cont_batching": cb_verdict,
        "cont_batch_recommended": (data.get("cont_batch") or {}).get("recommended"),
        "fit_ctx_hint": fit_ctx,
        "decode_ms": rec_decode,
        "prefill_tps": best_row.get("prefill_tps") if best_row else inter.get("prefill_tps"),
        "prefill_ttft": best_row.get("prefill_ttft") if best_row else inter.get("prefill_ttft"),
        "pp_idle": pp_idle,
        "tg_idle": tg_idle,
        "interleave_gain": interleave_gain,
    }
    recommendations.append(rec)

    # --- Markdown section ---
    md = [f"## {model}", ""]
    if pp_idle or tg_idle:
        md.append(f"**Throughput (idle, lab Vulkan):** PP {fmt_num(pp_idle)} tok/s · TG {fmt_num(tg_idle)} tok/s")
        md.append("")

    md += [
        "### Interleaving — lohnt sich np=2?",
        "",
        "| Scenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for key, label in [
        ("01_baseline_solo", "01 solo (reference)"),
        ("02_blocked_np1", "02 blocked (np=1, schlecht)"),
        ("03_interleave_np2", "03 interleave (np=2)"),
    ]:
        r = auto.get(key, {})
        if not r:
            continue
        ttft = r.get("prefill_ttft")
        ttft_s = fmt_num(ttft)
        if ttft and not ttft_valid(ttft):
            ttft_s += " ⚠"
        md.append(
            f"| {label} | {fmt_num(r.get('decode_ms'))} | {fmt_num(r.get('decode_tps'))} | "
            f"{fmt_num(r.get('prefill_tps'))} | {ttft_s} |"
        )
    if interleave_gain and interleave_gain > 2:
        md.append("")
        md.append(f"→ **Interleaving:** Prefill-TTFT **{interleave_gain:.0f}× faster** than blocked "
                  f"({fmt_num(blocked_ttft)} ms → {fmt_num(inter_ttft)} ms). Decode bleibt ~{fmt_num(inter.get('decode_ms'))} ms.")
    md.append("")

    if ranked_ub:
        md += [
            "### ub-sweep — best batch size under load",
            "",
            "Tested with scenario 03 (decode + 4k prefill in parallel). "
            "**Goal:** low decode latency + high prefill throughput + low TTFT.",
            "",
            "| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |",
            "| --- | ---: | ---: | ---: | ---: | --- |",
        ]
        for r in ranked_ub:
            flag = ""
            if r.get("best"):
                flag = "**★ best**"
            elif not r.get("valid"):
                flag = "⚠ invalid"
            ttft_s = fmt_num(r.get("prefill_ttft"))
            md.append(
                f"| {r.get('ub')} | {fmt_num(r.get('decode_ms'))} | {fmt_num(r.get('decode_tps'))} | "
                f"{fmt_num(r.get('prefill_tps'))} | {ttft_s} | {flag} |"
            )
        if best_ub:
            md.append("")
            md.append(f"→ **Recommendation:** `ub = {best_ub}`")

    for title, param, ranked, best, note in [
        ("np-sweep — parallel slots (ub=128 fixed)", "np", ranked_np, best_np, "np"),
        ("b-Sweep — n_batch (np=2, ub=128 fix)", "b", ranked_b, best_b, "b"),
        ("ctx-Sweep — Kontext vs VRAM", "c", ranked_c, best_c, "c"),
    ]:
        if not ranked:
            continue
        if param == "c":
            md += ["", f"### {title}", "", "Scenario 01 solo per ctx.", "",
                   "| c | Decode ms | Decode tok/s | VRAM MB | |",
                   "| --- | ---: | ---: | ---: | --- |"]
            for r in ranked:
                flag = "**★ best**" if r.get("best") else ""
                md.append(
                    f"| {r.get(param)} | {fmt_num(r.get('decode_ms'))} | {fmt_num(r.get('decode_tps'))} | "
                    f"{fmt_num(r.get('vram_mb'))} | {flag} |"
                )
        else:
            md += ["", f"### {title}", "", "Scenario 03 under load.", "",
                   f"| {param} | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |",
                   "| --- | ---: | ---: | ---: | ---: | --- |"]
            for r in ranked:
                flag = "**★ best**" if r.get("best") else ("⚠ invalid" if not r.get("valid") else "")
                md.append(
                    f"| {r.get(param)} | {fmt_num(r.get('decode_ms'))} | {fmt_num(r.get('decode_tps'))} | "
                    f"{fmt_num(r.get('prefill_tps'))} | {fmt_num(r.get('prefill_ttft'))} | {flag} |"
                )
        if best:
            md.append("")
            md.append(f"→ **Recommendation:** `{param} = {best}`")

    if cb_detail.get("on") or cb_detail.get("off"):
        md += [
            "",
            "### cont-batching — on vs off",
            "",
            "| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
        for label, key in [("an (cont-batching)", "on"), ("aus (--no-cont-batching)", "off")]:
            e = cb_detail.get(key) or {}
            md.append(
                f"| {label} | {fmt_num(e.get('pp_tok_s'))} | {fmt_num(e.get('tg_tok_s'))} | "
                f"{fmt_num(e.get('decode_ms'))} | {fmt_num(e.get('prefill_tok_s'))} | "
                f"{fmt_num(e.get('prefill_ttft_ms'))} |"
            )
        if cb_detail.get("recommended"):
            md.append("")
            md.append(f"→ **Recommendation:** cont-batching **{cb_detail['recommended']}**")

    if mtp.get("runs"):
        md += [
            "",
            "### MTP — off vs draft-mtp n-max",
            "",
            "| n | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |",
            "| --- | ---: | ---: | ---: | ---: | --- |",
        ]
        for e in mtp.get("runs") or []:
            flag = "**★ best**" if e.get("n") == mtp_rec else ""
            md.append(
                f"| {e.get('n')} | {fmt_num(e.get('decode_ms'))} | {fmt_num(e.get('decode_tps'))} | "
                f"{fmt_num(e.get('prefill_tps'))} | {fmt_num(e.get('prefill_ttft_ms'))} | {flag} |"
            )
        if mtp_rec:
            md.append("")
            md.append(f"→ **Recommendation:** `spec-draft-n-max = {mtp_rec}`" if mtp_rec != "off" else "→ **Recommendation:** MTP **off** (`spec-type = none`)")

    md.append("")
    model_sections_md.extend(md)

    # --- HTML section ---
    gain_html = ""
    if interleave_gain and interleave_gain > 2:
        gain_html = (
            f'<p class="gain">Interleaving: Prefill-TTFT <strong>{interleave_gain:.0f}× faster</strong> '
            f"({fmt_num(blocked_ttft)} → {fmt_num(inter_ttft)} ms), Decode ~{fmt_num(inter.get('decode_ms'))} ms</p>"
        )
    tp_html = ""
    if pp_idle or tg_idle:
        tp_html = f'<p class="meta">Throughput idle: PP <strong>{fmt_num(pp_idle)}</strong> · TG <strong>{fmt_num(tg_idle)}</strong> tok/s</p>'

    rows_html = ""
    for key, label in [
        ("01_baseline_solo", "01 solo"),
        ("02_blocked_np1", "02 blocked"),
        ("03_interleave_np2", "03 interleave"),
    ]:
        r = auto.get(key, {})
        if not r:
            continue
        ttft = r.get("prefill_ttft")
        cls = "bad" if ttft and not ttft_valid(ttft) else ""
        rows_html += (
            f"<tr><td>{html.escape(label)}</td>"
            f'<td class="n">{fmt_num(r.get("decode_ms"))}</td>'
            f'<td class="n">{fmt_num(r.get("decode_tps"))}</td>'
            f'<td class="n">{fmt_num(r.get("prefill_tps"))}</td>'
            f'<td class="n {cls}">{fmt_num(ttft)}</td></tr>'
        )

    ub_html = ""
    if ranked_ub:
        ub_rows_html = ""
        for r in ranked_ub:
            tr_cls = "best" if r.get("best") else ("bad" if not r.get("valid") else "")
            note = "★ best" if r.get("best") else ("⚠" if not r.get("valid") else "")
            ub_rows_html += (
                f'<tr class="{tr_cls}"><td class="n">{html.escape(str(r.get("ub")))}</td>'
                f'<td class="n">{fmt_num(r.get("decode_ms"))}</td>'
                f'<td class="n">{fmt_num(r.get("decode_tps"))}</td>'
                f'<td class="n">{fmt_num(r.get("prefill_tps"))}</td>'
                f'<td class="n">{fmt_num(r.get("prefill_ttft"))}</td>'
                f'<td>{note}</td></tr>'
            )
        rec_ub = f'<p class="rec">Empfohlen: <code>ub = {best_ub}</code></p>' if best_ub else ""
        ub_html = f"""
<h4>ub-sweep (interleave under load)</h4>
{rec_ub}
<table><thead><tr>
<th>ub</th><th class="n">Decode ms</th><th class="n">Decode tok/s</th>
<th class="n">Prefill tok/s</th><th class="n">Prefill TTFT</th><th></th>
</tr></thead><tbody>{ub_rows_html}</tbody></table>"""

    def sweep_html(title, param, ranked, best):
        if not ranked:
            return ""
        rows = ""
        for r in ranked:
            tr_cls = "best" if r.get("best") else ("bad" if not r.get("valid") else "")
            note = "★ best" if r.get("best") else ("⚠" if not r.get("valid") else "")
            rows += (
                f'<tr class="{tr_cls}"><td class="n">{html.escape(str(r.get(param)))}</td>'
                f'<td class="n">{fmt_num(r.get("decode_ms"))}</td>'
                f'<td class="n">{fmt_num(r.get("decode_tps"))}</td>'
                f'<td class="n">{fmt_num(r.get("prefill_tps"))}</td>'
                f'<td class="n">{fmt_num(r.get("prefill_ttft"))}</td>'
                f'<td>{note}</td></tr>'
            )
        rec = f'<p class="rec">Empfohlen: <code>{param} = {best}</code></p>' if best else ""
        return f"""<h4>{html.escape(title)}</h4>{rec}
<table><thead><tr>
<th>{html.escape(param)}</th><th class="n">Decode ms</th><th class="n">Decode tok/s</th>
<th class="n">Prefill tok/s</th><th class="n">Prefill TTFT</th><th></th>
</tr></thead><tbody>{rows}</tbody></table>"""

    np_html = sweep_html("np-Sweep (ub=128 fix)", "np", ranked_np, best_np)
    b_html = sweep_html("b-Sweep (np=2, ub=128 fix)", "b", ranked_b, best_b)

    badges = []
    if best_ub:
        badges.append(f"ub={best_ub}")
    if best_np:
        badges.append(f"np={best_np}")
    if best_b:
        badges.append(f"b={best_b}")
    best_badge = " ".join(f'<span class="badge">{html.escape(b)}</span>' for b in badges)
    model_sections_html.append(f"""
<section class="model">
<h3>{html.escape(model)} {best_badge}</h3>
{tp_html}
{gain_html}
<h4>Interleaving np=2</h4>
<table><thead><tr>
<th>Scenario</th><th class="n">Decode ms</th><th class="n">Decode tok/s</th>
<th class="n">Prefill tok/s</th><th class="n">Prefill TTFT</th>
</tr></thead><tbody>{rows_html}</tbody></table>
{ub_html}
{np_html}
{b_html}
</section>""")

# --- Write compare.md ---
lines = [
    "# Scheduling — compare & recommendations",
    "",
    "Decode latency and prefill throughput **under load** (2 slots, rolling prefill). "
    "Lab-Router `:11537`, `np=2`.",
    "",
    "## Metrics",
    "",
    "| Metric | Meaning | Target |",
    "| --- | --- | --- |",
    "| **Decode ms** | time per generated token (slot A, under load) | low (~33 ms) |",
    "| **Prefill tok/s** | prompt throughput while decode runs (≈ PP under load) | high |",
    "| **Prefill TTFT** | ms until first prefill token (4k prompt) | low |",
    "| **PP idle** | prompt tok/s idle (from throughput bench) | reference |",
    "",
    "## Recommendation per model",
    "",
    "| Model | np ★ | ub ★ | b ★ | c ★ | cont-batch | PP on | PP off | Decode ms | Prefill tok/s |",
    "| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |",
]
for r in recommendations:
    pp_on = pp_off = "—"
    cb_detail = cont_batch_verdict(models.get(r["model"], {}).get("cont_batch"))[2]
    if cb_detail.get("on"):
        pp_on = fmt_num(cb_detail["on"].get("pp_tok_s"))
    if cb_detail.get("off"):
        pp_off = fmt_num(cb_detail["off"].get("pp_tok_s"))
    lines.append(
        f"| {r['model']} | {r.get('best_np', '—')} | {r.get('best_ub', '—')} | {r.get('best_b', '—')} | "
        f"{r.get('best_c', '—')} | {r.get('cont_batching', 'on')} | {pp_on} | {pp_off} | "
        f"{fmt_num(r.get('decode_ms'))} | {fmt_num(r.get('prefill_tps'))} |"
    )
lines += ["", "---", ""] + model_sections_md

with open(latest_md, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

# --- Write compare.html ---
rec_rows = ""
for r in recommendations:
    gain = "—"
    cls = ""
    if r.get("interleave_gain") and r["interleave_gain"] > 2:
        gain = f"{r['interleave_gain']:.0f}×"
        cls = "pos"
    cb_detail = cont_batch_verdict(models.get(r["model"], {}).get("cont_batch"))[2]
    pp_on = fmt_num((cb_detail.get("on") or {}).get("pp_tok_s"))
    pp_off = fmt_num((cb_detail.get("off") or {}).get("pp_tok_s"))
    rec_rows += (
        f"<tr><td>{html.escape(r['model'])}</td>"
        f'<td class="n best">{html.escape(str(r.get("best_np", "—")))}</td>'
        f'<td class="n best">{html.escape(str(r.get("best_ub", "—")))}</td>'
        f'<td class="n best">{html.escape(str(r.get("best_b", "—")))}</td>'
        f'<td class="n best">{html.escape(str(r.get("best_c", "—")))}</td>'
        f'<td class="n">{html.escape(str(r.get("cont_batching", "on")))}</td>'
        f'<td class="n">{pp_on}</td>'
        f'<td class="n">{pp_off}</td>'
        f'<td class="n">{fmt_num(r.get("decode_ms"))}</td>'
        f'<td class="n">{fmt_num(r.get("prefill_tps"))}</td>'
        f'<td class="n {cls}">{gain}</td></tr>'
    )

page = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Scheduling compare</title>
<style>
:root {{ color-scheme: dark; }}
body {{ font: 15px/1.5 system-ui, sans-serif; margin: 2rem; max-width: 1100px;
  background: #12141a; color: #e8eaed; }}
h1 {{ font-size: 1.35rem; margin-bottom: .25rem; }}
h3 {{ font-size: 1.1rem; margin: 0 0 .5rem; }}
h4 {{ font-size: .95rem; color: #9aa0a6; margin: 1.25rem 0 .5rem; }}
.meta, .foot {{ color: #9aa0a6; font-size: .9rem; }}
.gain {{ color: #7ddea5; margin: .5rem 0; }}
.rec {{ color: #8ab4f8; margin: .25rem 0 .75rem; }}
table {{ border-collapse: collapse; width: 100%; margin: .5rem 0 1rem; }}
th, td {{ padding: .45rem .65rem; border-bottom: 1px solid #2a2e37; }}
th {{ text-align: left; color: #9aa0a6; font-weight: 600; }}
td.n, th.n {{ text-align: right; font-variant-numeric: tabular-nums;
  font-family: ui-monospace, monospace; }}
tr.best td {{ background: #1a2e24; }}
tr.best td.n {{ color: #7ddea5; font-weight: 600; }}
td.bad, tr.bad td.n {{ color: #f0a0a0; }}
.pos {{ color: #7ddea5; }}
.badge {{ background: #1a3a2a; color: #7ddea5; font-size: .75rem;
  padding: .15rem .45rem; border-radius: 4px; margin-left: .5rem; }}
section.model {{ margin: 2rem 0; padding: 1rem 0; border-top: 1px solid #2a2e37; }}
.legend {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: .75rem; margin: 1rem 0; }}
.legend div {{ background: #1a1d24; padding: .65rem .85rem; border-radius: 6px; }}
.legend strong {{ display: block; margin-bottom: .2rem; }}
</style></head><body>
<h1>Scheduling — compare & recommendations</h1>
<p class="meta">Decode latency + prefill throughput under load · np=2 · ★ = recommended ub</p>

<div class="legend">
  <div><strong>Decode ms</strong>Low = tokens stream smoothly while generating</div>
  <div><strong>Prefill tok/s</strong>High = long prompts block less (≈ PP under load)</div>
  <div><strong>Prefill TTFT</strong>Low = prefill starts quickly alongside decode</div>
  <div><strong>PP on/off</strong>prompt tok/s solo (4k) with cont-batching on vs off</div>
</div>

<h2>Recommendation per model</h2>
<table><thead><tr>
<th>Model</th><th class="n">np ★</th><th class="n">ub ★</th><th class="n">b ★</th><th class="n">c ★</th>
<th>cont-batch</th><th class="n">PP on</th><th class="n">PP off</th>
<th class="n">Decode ms</th><th class="n">Prefill tok/s</th>
<th class="n">Interleave</th>
</tr></thead><tbody>{rec_rows}</tbody></table>

<h2>Details per model</h2>
{"".join(model_sections_html)}

<p class="foot">Markdown: output/bench/scheduling/latest/compare.md · Rebuild: ./bench compare-sched</p>
</body></html>"""

with open(latest_html, "w", encoding="utf-8") as f:
    f.write(page)

summary_path = os.path.join(os.path.dirname(latest_md), "summary.json")
with open(summary_path, "w", encoding="utf-8") as f:
    json.dump({"recommendations": recommendations, "models": len(models)}, f, indent=2)
    f.write("\n")

print(f"Wrote {latest_md} ({len(models)} models)")
print(f"Wrote {latest_html}")
print(f"Wrote {summary_path}")
PY
  log "compare → $latest_md + compare.html"
}

report_run() {
  local run_dir
  run_dir="$(run_dir)"
  [[ -n "$run_dir" && -d "$run_dir" ]] || die "no SCHED_RUN_DIR for report_run"
  mkdir -p "$SCHED_OUT/latest"
  cp -f "$run_dir/manifest.json" "$SCHED_OUT/latest/manifest.json" 2>/dev/null || true
  report_latest || true
  [[ -f "$PROJECT_ROOT/tools/bench/build-index.sh" ]] && bash "$PROJECT_ROOT/tools/bench/build-index.sh" || true
}
