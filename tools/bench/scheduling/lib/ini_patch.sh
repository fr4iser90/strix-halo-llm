#!/usr/bin/env bash
# Patch models-bench.ini and restart bench-a (one key at a time, all sections).
set -euo pipefail

patch_bench_ini() {
  local key="$1" val="$2"
  local ini="${SCHED_BENCH_INI:-$PROJECT_ROOT/models-bench.ini}"
  [[ -f "$ini" ]] || die "missing ini: $ini"
  grep -qE "^${key}[[:space:]]*=" "$ini" || die "no ${key}= in $ini"
  sed -i "s/^${key}[[:space:]]*=.*/${key} = ${val}/" "$ini"
  log "patched ini ${key}=${val}"
}

# Set/replace a key inside one [section] of an arbitrary INI.
patch_ini_section() {
  local ini="$1" section="$2" key="$3" val="$4"
  [[ -f "$ini" ]] || die "missing ini: $ini"
  bench_python - "$ini" "$section" "$key" "$val" <<'PY'
import sys
ini, section, key, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(ini, encoding="utf-8").read().splitlines(keepends=True)
out = []
cur = None
in_section = False
replaced = False
section_found = False
i = 0
while i < len(lines):
    raw = lines[i]
    line = raw.strip()
    if line.startswith("[") and line.endswith("]"):
        if in_section and not replaced:
            out.append(f"{key} = {val}\n")
            replaced = True
        cur = line[1:-1].strip()
        in_section = cur == section
        if in_section:
            section_found = True
        out.append(raw)
        i += 1
        continue
    if in_section and "=" in line and not line.startswith(";"):
        k, _, _ = line.partition("=")
        if k.strip() == key:
            out.append(f"{key} = {val}\n")
            replaced = True
            i += 1
            continue
    out.append(raw)
    i += 1
if in_section and not replaced:
    out.append(f"{key} = {val}\n")
    replaced = True
if not section_found:
    raise SystemExit(f"section [{section}] not found in {ini}")
open(ini, "w", encoding="utf-8").writelines(out)
PY
  log "patched ini $(basename "$ini") [${section}] ${key}=${val}"
}

get_ini_section_key() {
  local ini="$1" section="$2" key="$3"
  [[ -f "$ini" ]] || die "missing ini: $ini"
  bench_python - "$ini" "$section" "$key" <<'PY'
import sys
ini, section, key = sys.argv[1], sys.argv[2], sys.argv[3]
cur = None
with open(ini, encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1].strip()
            continue
        if cur != section or "=" not in line or line.startswith(";"):
            continue
        k, _, v = line.partition("=")
        if k.strip() == key:
            print(v.strip())
            raise SystemExit(0)
print("")
PY
}

# Read a key from one [section] (empty string if missing).
get_bench_ini_section_key() {
  get_ini_section_key "${SCHED_BENCH_INI:-$PROJECT_ROOT/models-bench.ini}" "$1" "$2"
}

# Set/replace a key inside one [section] only. Creates the key if missing.
patch_bench_ini_section() {
  patch_ini_section "${SCHED_BENCH_INI:-$PROJECT_ROOT/models-bench.ini}" "$1" "$2" "$3"
}


merge_mtp_summary() {
  local sdir="$1"
  bench_python - "$sdir" <<'PY'
import glob, json, os, sys

def vram_max(path):
    if not os.path.isfile(path):
        return None
    best = None
    with open(path, encoding="utf-8") as f:
        next(f, None)
        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 2 or not parts[1]:
                continue
            try:
                v = int(float(parts[1]))
            except ValueError:
                continue
            if best is None or v > best:
                best = v
    return best

def decode_ms(slot):
    if not slot:
        return None
    p50 = slot.get("token_interval_ms_p50")
    p95 = slot.get("token_interval_ms_p95")
    if p95 is not None and (p50 is None or p50 < 1.0):
        return p95
    return p50 if p50 is not None else p95

sdir = sys.argv[1]
merged = {"scenario": "10_mtp_sweep", "runs": []}
for path in sorted(glob.glob(os.path.join(sdir, "n_*", "run", "summary.json"))):
    label = os.path.basename(os.path.dirname(os.path.dirname(path))).replace("n_", "", 1)
    run_dir = os.path.dirname(path)
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    slot_a = data.get("slot_a") or data.get("decode") or {}
    slot_b = data.get("slot_b") or data.get("prefill") or {}
    vram = None
    for m in glob.glob(os.path.join(run_dir, "**", "metrics.csv"), recursive=True):
        vram = vram_max(m)
        if vram:
            break
    entry = {
        "n": label,
        "spec_type": "none" if label == "off" else "draft-mtp",
        "spec_draft_n_max": None if label == "off" else int(label),
        "decode_ms": decode_ms(slot_a),
        "decode_tps": slot_a.get("tokens_per_sec"),
        "prefill_ttft_ms": slot_b.get("ttft_ms"),
        "prefill_tps": slot_b.get("tokens_per_sec"),
        "summary": data,
    }
    if vram is not None:
        entry["vram_mb"] = vram
    merged["runs"].append(entry)

best = None
best_score = None
for entry in merged["runs"]:
    tps = entry.get("decode_tps")
    if tps is None:
        continue
    # Prefer higher decode tok/s; tie-break lower decode_ms
    dec = entry.get("decode_ms") or 999
    score = (float(tps), -float(dec))
    if best_score is None or score > best_score:
        best_score = score
        best = entry
if best:
    merged["recommended"] = best["n"]
    merged["recommended_n"] = best["n"]

out = os.path.join(sdir, "summary.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PY
}

# shellcheck source=bench_server.sh
source "$SCHED_BENCH_ROOT/lib/bench_server.sh"

merge_sweep_summary() {
  local sdir="$1" param="$2"
  bench_python - "$sdir" "$param" <<'PY'
import glob, json, os, sys

def vram_max(path):
    if not os.path.isfile(path):
        return None
    best = None
    with open(path, encoding="utf-8") as f:
        next(f, None)
        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 2:
                continue
            try:
                v = int(float(parts[1])) if parts[1] else None
            except ValueError:
                continue
            if v is not None and (best is None or v > best):
                best = v
    return best

sdir, param = sys.argv[1], sys.argv[2]
merged = {"scenario": os.path.basename(sdir), "runs": []}
# Prefer …/{param}_*/run/summary.json; also accept …/{param}_*/summary.json
paths = sorted(glob.glob(os.path.join(sdir, f"{param}_*", "run", "summary.json")))
if not paths:
    paths = sorted(glob.glob(os.path.join(sdir, f"{param}_*", "summary.json")))
for path in paths:
    # …/b_64/run/summary.json → b_64 ; …/b_64/summary.json → b_64
    parent = os.path.basename(os.path.dirname(path))
    if parent == "run":
        label_dir = os.path.basename(os.path.dirname(os.path.dirname(path)))
    else:
        label_dir = parent
    val = label_dir.replace(f"{param}_", "", 1)
    run_dir = os.path.dirname(path)
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    vram = None
    for m in glob.glob(os.path.join(run_dir, "**", "metrics.csv"), recursive=True):
        vram = vram_max(m)
        if vram:
            break
    entry = {param: val, "summary": data}
    if vram is not None:
        entry["vram_mb"] = vram
    merged["runs"].append(entry)
out = os.path.join(sdir, "summary.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
if not merged["runs"]:
    print(f"warning: merge_sweep_summary found 0 runs under {sdir}", file=sys.stderr)
PY
}

merge_ab_summary() {
  merge_cont_batch_summary "$1"
}

merge_cont_batch_summary() {
  local sdir="$1"
  bench_python - "$sdir" <<'PY'
import glob, json, os, sys

def vram_max(path):
    if not os.path.isfile(path):
        return None
    best = None
    with open(path, encoding="utf-8") as f:
        next(f, None)
        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 2 or not parts[1]:
                continue
            try:
                v = int(float(parts[1]))
            except ValueError:
                continue
            if best is None or v > best:
                best = v
    return best

def decode_ms(slot):
    if not slot:
        return None
    p50 = slot.get("token_interval_ms_p50")
    p95 = slot.get("token_interval_ms_p95")
    if p95 is not None and (p50 is None or p50 < 1.0):
        return p95
    return p50 if p50 is not None else p95

def load_summary(path):
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)

sdir = sys.argv[1]
merged = {"scenario": "07_cont_batch", "runs": []}

def first_summary(base, *rels):
    for rel in rels:
        path = os.path.join(base, rel)
        data = load_summary(path)
        if data:
            return data
    return {}

for label in ("cont_on", "cont_off"):
    base = os.path.join(sdir, label)
    pp = first_summary(base, "pp/summary.json", "pp/pp/summary.json")
    solo = first_summary(base, "solo/run/summary.json", "solo/01_baseline_solo/summary.json")
    inter = first_summary(base, "interleave/run/summary.json", "interleave/03_interleave_np2/summary.json")
    if not pp and not solo and not inter:
        continue
    slot_a = (inter.get("slot_a") or {}) if inter else {}
    slot_b = (inter.get("slot_b") or {}) if inter else {}
    slot_solo = (solo.get("slot_a") or solo.get("decode") or {}) if solo else {}
    vram = None
    for m in glob.glob(os.path.join(base, "**", "metrics.csv"), recursive=True):
        vram = vram_max(m)
        if vram:
            break
    entry = {
        "mode": label,
        "cont_batching": label == "cont_on",
        "pp_tok_s": pp.get("pp_tok_s"),
        "pp_ttft_ms": pp.get("ttft_ms"),
        "tg_tok_s": slot_solo.get("tokens_per_sec"),
        "decode_ms": decode_ms(slot_a),
        "prefill_tok_s": slot_b.get("tokens_per_sec"),
        "prefill_ttft_ms": slot_b.get("ttft_ms"),
        "summary_interleave": inter or None,
        "summary_solo": solo or None,
        "summary_pp": pp or None,
    }
    if vram is not None:
        entry["vram_mb"] = vram
    merged["runs"].append(entry)

# Global recommendation from aggregated metrics
best = None
best_score = None
for entry in merged["runs"]:
    pp = entry.get("pp_tok_s") or 0
    pf = entry.get("prefill_tok_s") or 0
    dec = entry.get("decode_ms") or 999
    # Higher PP/prefill, lower decode is better
    score = (pp + pf) - dec * 0.05
    if best_score is None or score > best_score:
        best_score = score
        best = entry
if best:
    merged["recommended"] = "on" if best.get("cont_batching") else "off"
    merged["recommended_mode"] = best.get("mode")

out = os.path.join(sdir, "summary.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PY
}
