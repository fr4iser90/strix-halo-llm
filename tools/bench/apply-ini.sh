#!/usr/bin/env bash
# Apply scheduling benchmark recommendations to models-lab.ini / models.ini.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/python.sh
source "$SCRIPT_DIR/lib/python.sh"

DRY_RUN=0
TARGET="lab"
SUMMARY="${BENCH_APPLY_SUMMARY:-$PROJECT_ROOT/output/bench/scheduling/latest/summary.json}"
INI_LAB="$PROJECT_ROOT/models-lab.ini"
INI_DAILY="$PROJECT_ROOT/models.ini"
BACKUP=1

die() { printf '[bench apply-ini] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./bench apply-ini [options]

Patch model sections in models-lab.ini (and optionally models.ini) from
output/bench/scheduling/latest/summary.json + latest ctx/cont_batch runs.

Options:
  --dry-run          show plan only, do not write
  --lab              patch models-lab.ini only (default)
  --daily            patch models.ini only (matching sections)
  --both             patch lab + daily where section exists
  --summary FILE     recommendations JSON (default: scheduling/latest/summary.json)
  --no-backup        skip .bak.<timestamp> before write

Keys applied per model (when bench data exists):
  np, ub, b          from scheduling sweeps
  c                  from 08_ctx_sweep (largest ctx with valid run, else keep)
  fit                off (bench uses explicit c); see 09_fit_probe for hint

Cont-batching is NOT applied to any file (process CLI flag, not INI).
Scenario 07 measures on/off; the recommendation stays in apply-plan.json
for the dashboard. Daily/lab keep llama.cpp default (cont-batching ON).

After apply: restart routers manually or ./bench sched triggers lab restart.

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-backup) BACKUP=0 ;;
    --lab) TARGET="lab" ;;
    --daily) TARGET="daily" ;;
    --both) TARGET="both" ;;
    --summary)
      shift
      SUMMARY="${1:?--summary needs file}"
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ -f "$SUMMARY" ]] || die "missing summary: $SUMMARY (run ./bench compare-sched first)"

bench_python - "$PROJECT_ROOT" "$SUMMARY" "$INI_LAB" "$INI_DAILY" "$TARGET" "$DRY_RUN" "$BACKUP" <<'PY'
import glob, json, os, re, shutil, sys
from datetime import datetime, timezone

root, summary_path, ini_lab, ini_daily, target, dry_run, backup = sys.argv[1:8]
dry_run = dry_run == "1"
backup = backup == "1"

with open(summary_path, encoding="utf-8") as f:
    summary = json.load(f)
recs = {r["model"]: r for r in summary.get("recommendations") or []}

sch = os.path.join(root, "output/bench/scheduling")

def latest_ctx(model):
    best_c = None
    best_vram = None
    for run in sorted(glob.glob(os.path.join(sch, "20*")), reverse=True):
        man = os.path.join(run, "manifest.json")
        sweep = os.path.join(run, "08_ctx_sweep", "summary.json")
        if not os.path.isfile(man) or not os.path.isfile(sweep):
            continue
        with open(man, encoding="utf-8") as f:
            if json.load(f).get("model") != model:
                continue
        with open(sweep, encoding="utf-8") as f:
            data = json.load(f)
        for entry in data.get("runs") or []:
            c = entry.get("c")
            inner = entry.get("summary") or {}
            slot = inner.get("slot_a") or {}
            if not slot.get("chunks"):
                continue
            try:
                c_int = int(c)
            except (TypeError, ValueError):
                continue
            if best_c is None or c_int > best_c:
                best_c = c_int
                best_vram = entry.get("vram_mb")
    return best_c, best_vram

def cont_batch_recommend(model):
    """Return (label, recommended_on_off, detail_dict) from latest 07 run."""
    for run in sorted(glob.glob(os.path.join(sch, "20*")), reverse=True):
        man = os.path.join(run, "manifest.json")
        sweep = os.path.join(run, "07_cont_batch", "summary.json")
        if not os.path.isfile(man) or not os.path.isfile(sweep):
            continue
        with open(man, encoding="utf-8") as f:
            if json.load(f).get("model") != model:
                continue
        with open(sweep, encoding="utf-8") as f:
            data = json.load(f)
        rec = data.get("recommended") or "on"
        on = off = {}
        for entry in data.get("runs") or []:
            if entry.get("mode") == "cont_on":
                on = entry
            elif entry.get("mode") == "cont_off":
                off = entry
        return f"{rec} ★", rec, {"on": on, "off": off}
    return "on (default)", "on", {}


def global_cont_batch_recommend():
    for run in sorted(glob.glob(os.path.join(sch, "20*")), reverse=True):
        sweep = os.path.join(run, "07_cont_batch", "summary.json")
        if not os.path.isfile(sweep):
            continue
        with open(sweep, encoding="utf-8") as f:
            data = json.load(f)
        if data.get("recommended") in ("on", "off"):
            return data["recommended"]
    return "on"

def fit_ctx_hint(model):
    for run in sorted(glob.glob(os.path.join(sch, "20*")), reverse=True):
        man = os.path.join(run, "manifest.json")
        probe = os.path.join(run, "09_fit_probe", "summary.json")
        if not os.path.isfile(man) or not os.path.isfile(probe):
            continue
        with open(man, encoding="utf-8") as f:
            if json.load(f).get("model") != model:
                continue
        with open(probe, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("context_length")
    return None

plans = []
global_cb = global_cont_batch_recommend()
for model, rec in sorted(recs.items()):
    best_c, vram = latest_ctx(model)
    if best_c is None:
        bc = rec.get("best_c")
        if bc not in (None, "", "—", "\u2014"):
            try:
                best_c = int(str(bc).replace(",", ""))
            except ValueError:
                pass
    cb_label, cb_val, cb_detail = cont_batch_recommend(model)
    fit_c = fit_ctx_hint(model)
    on = cb_detail.get("on") or {}
    bb = rec.get("best_b")
    if bb in (None, "", "—", "\u2014"):
        bb = None
    plan = {
        "model": model,
        "np": rec.get("best_np"),
        "ub": rec.get("best_ub"),
        "b": bb,
        "b_default": 64,
        "c": best_c,
        "vram_mb": vram,
        "cont_batching": cb_label,
        "cont_batching_apply": cb_val,
        "pp_tok_s_cont_on": on.get("pp_tok_s"),
        "pp_tok_s_cont_off": (cb_detail.get("off") or {}).get("pp_tok_s"),
        "fit_vram_ctx_hint": fit_c,
    }
    for k in ("np", "ub", "b"):
        v = plan.get(k)
        if v in (None, "", "—", "\u2014"):
            plan[k] = None
    plans.append(plan)

def patch_ini(path, updates_by_section):
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    changes = []
    current = None
    out = []
    key_re = re.compile(r"^([A-Za-z0-9_-]+)\s*=")
    for line in lines:
        sec = re.match(r"^\[([^\]]+)\]\s*$", line)
        if sec:
            current = sec.group(1)
            out.append(line)
            continue
        if current in updates_by_section:
            m = key_re.match(line)
            if m:
                key = m.group(1)
                if key in updates_by_section[current]:
                    new = str(updates_by_section[current][key])
                    old = line.strip().split("=", 1)[-1].strip()
                    if old != new:
                        changes.append((current, key, old, new))
                        line = f"{key} = {new}\n"
        out.append(line)
    if not changes:
        return []
    if dry_run:
        return changes
    if backup:
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        shutil.copy2(path, f"{path}.bak.{ts}")
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    return changes

updates = {}
for plan in plans:
    sec = plan["model"]
    upd = {}
    for key in ("np", "ub", "b", "c"):
        val = plan.get(key)
        if key == "b" and val is None:
            val = plan.get("b_default")
        if val is not None:
            upd[key] = val
    upd["fit"] = "off"
    if upd:
        updates[sec] = upd

paths = []
if target in ("lab", "both"):
    paths.append(ini_lab)
if target in ("daily", "both"):
    paths.append(ini_daily)

plan_path = os.path.join(root, "output/bench/scheduling/latest/apply-plan.json")
with open(plan_path, "w", encoding="utf-8") as f:
    json.dump({
        "plans": plans,
        "target": target,
        "dry_run": dry_run,
        "global_cont_batching": global_cb,
    }, f, indent=2)
    f.write("\n")

print(f"Wrote {plan_path}")
print("")
print("| model | np | ub | b | c | cont-batch (advisory) | PP on | PP off |")
print("| --- | --- | --- | --- | --- | --- | --- | --- |")
for p in plans:
    print(
        f"| {p['model']} | {p.get('np') or '—'} | {p.get('ub') or '—'} | {p.get('b') or '—'} | "
        f"{p.get('c') or '—'} | {p.get('cont_batching')} | "
        f"{p.get('pp_tok_s_cont_on') or '—'} | {p.get('pp_tok_s_cont_off') or '—'} |"
    )

print("")
print(
    f"Cont-batching global majority (advisory only, not written to disk): {global_cb or '—'}"
)
print("  Toggle for A/B lives in scenario 07 via ephemeral compose overlay — no .env.")

all_changes = []
for path in paths:
    ch = patch_ini(path, updates)
    for section, key, old, new in ch:
        all_changes.append((path, section, key, old, new))

print("")
if dry_run:
    print("DRY RUN — no files written.")
elif not all_changes:
    print("No ini changes (already up to date or sections missing).")
else:
    print("Applied changes:")
    for path, section, key, old, new in all_changes:
        print(f"  {os.path.basename(path)} [{section}] {key}: {old} → {new}")
    print("")
    print("Restart lab/daily router to pick up ini changes:")
    print("  docker compose --profile lab up -d llama-lab")
    print("  docker compose up -d llama")
PY
