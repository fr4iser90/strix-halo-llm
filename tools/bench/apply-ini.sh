#!/usr/bin/env bash
# Apply scheduling / planner recommendations to models*.ini.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/python.sh
source "$SCRIPT_DIR/lib/python.sh"

DRY_RUN=0
TARGET="lab"
SUMMARY="${BENCH_APPLY_SUMMARY:-$PROJECT_ROOT/output/bench/scheduling/latest/summary.json}"
INI_LAB="$LLAMA_INI_DIR/models-lab.ini"
INI_DAILY="$LLAMA_INI_DIR/models.ini"
INI_CODER="$LLAMA_INI_DIR/models-coder.ini"
BACKUP=1
PLAN_FILE=""

die() { printf '[bench apply-ini] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./bench apply-ini [options]

Patch model sections from sched recommendations OR from planner plan.json.

Options:
  --dry-run          show plan only, do not write
  --lab              patch models-lab.ini only (default; sched mode)
  --daily            patch models.ini only (matching sections)
  --both             patch lab + daily where section exists
  --plan FILE        apply planner export (plan.json) → sticky INIs
  --summary FILE     recommendations JSON (default: scheduling/latest/summary.json)
  --no-backup        skip .bak.<timestamp> before write

Planner (--plan): writes np/c/ub/b/ctk/ctv/fit into:
  mode solo → models.ini
  mode dual → models.ini + models-coder.ini
  mode lab  → models-lab.ini
Section must already exist (or only keys present are updated; missing section = warn).

Sched mode keys: np, ub, b, c, fit=off. Cont-batching is advisory only.

After apply: recreate routers, e.g.
  docker compose up -d --force-recreate llama
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
    --plan)
      shift
      PLAN_FILE="${1:?--plan needs file}"
      ;;
    --summary)
      shift
      SUMMARY="${1:?--summary needs file}"
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

# --- Planner plan.json path -------------------------------------------------
if [[ -n "$PLAN_FILE" ]]; then
  [[ -f "$PLAN_FILE" ]] || die "missing plan: $PLAN_FILE"
  bench_python - "$PROJECT_ROOT" "$PLAN_FILE" "$INI_DAILY" "$INI_CODER" "$INI_LAB" "$DRY_RUN" "$BACKUP" <<'PY'
import json, os, re, shutil, sys
from datetime import datetime, timezone

root, plan_path, ini_daily, ini_coder, ini_lab, dry_run, backup = sys.argv[1:8]
dry_run = dry_run == "1"
backup = backup == "1"

with open(plan_path, encoding="utf-8") as f:
    plan = json.load(f)

mode = plan.get("mode") or "solo"
chat = plan.get("chat") or {}
coder = plan.get("coder")

def patch_ini(path, updates_by_section):
    if not os.path.isfile(path):
        print(f"  warn: missing {path}", file=sys.stderr)
        return []
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    changes = []
    current = None
    out = []
    key_re = re.compile(r"^([A-Za-z0-9_-]+)\s*=")
    wanted = set(updates_by_section.keys())
    found = set()
    for line in lines:
        sec = re.match(r"^\[([^\]]+)\]\s*$", line)
        if sec:
            current = sec.group(1)
            if current in wanted:
                found.add(current)
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
    missing = wanted - found
    for m in missing:
        print(f"  warn: section [{m}] not in {os.path.basename(path)} — skip (add section or sync-models)", file=sys.stderr)
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

def section_upd(block):
    if not block or not block.get("model"):
        return None, {}
    name = block["model"]
    upd = {"fit": "off"}
    for k in ("np", "c", "ub", "b"):
        if block.get(k) is not None:
            upd[k] = block[k]
    kv = block.get("kv")
    if kv:
        upd["ctk"] = kv
        upd["ctv"] = kv
    if mode in ("solo", "dual") and block.get("ini") != "models-lab.ini":
        upd["load-on-startup"] = "true"
    return name, upd

jobs = []
if mode == "lab":
    name, upd = section_upd(chat)
    if name:
        jobs.append((ini_lab, {name: upd}))
elif mode == "dual":
    name, upd = section_upd(chat)
    if name:
        jobs.append((ini_daily, {name: upd}))
    if coder:
        name2, upd2 = section_upd(coder)
        if name2:
            jobs.append((ini_coder, {name2: upd2}))
else:  # solo
    name, upd = section_upd(chat)
    if name:
        jobs.append((ini_daily, {name: upd}))

print(f"plan mode={mode} sticky_count={plan.get('sticky_count')}")
all_changes = []
for path, updates in jobs:
    ch = patch_ini(path, updates)
    for section, key, old, new in ch:
        all_changes.append((path, section, key, old, new))

# stash copy under output for audit
out_dir = os.path.join(root, "output/bench/scheduling/latest")
os.makedirs(out_dir, exist_ok=True)
audit = os.path.join(out_dir, "planner-plan-applied.json")
if not dry_run:
    with open(audit, "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=2)
        f.write("\n")
    print(f"Wrote {audit}")

if dry_run:
    print("DRY RUN — no files written.")
elif not all_changes:
    print("No ini changes (already up to date or sections missing).")
else:
    print("Applied changes:")
    for path, section, key, old, new in all_changes:
        print(f"  {os.path.basename(path)} [{section}] {key}: {old} → {new}")

if mode == "solo":
    print("Restart: docker compose up -d --force-recreate llama")
elif mode == "dual":
    print("Restart: docker compose up -d --force-recreate llama llama-coder")
else:
    print("Restart: docker compose --profile lab up -d --force-recreate llama-lab")
PY
  exit $?
fi

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
