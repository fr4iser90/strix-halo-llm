#!/usr/bin/env bash
# 09: fit=vram — record auto-chosen context from /v1/models after load.
set -euo pipefail
SCENARIO="09_fit_probe"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/ini_patch.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

if [[ "${SCHED_RESTART_LAB:-0}" == "1" ]]; then
  log "enable fit=on and restart lab"
  patch_lab_ini fit on
  restart_lab_server 0
else
  log "fit probe (set SCHED_RESTART_LAB=1 to patch ini)"
fi

preflight
bench_python - "$sdir" "${SCHED_MODEL:-}" "${SCHED_BASE_URL:-http://localhost:11537}" <<'PY'
import json, os, sys, urllib.request

sdir, model, base = sys.argv[1], sys.argv[2], sys.argv[3]
out = {"scenario": "09_fit_probe", "model": model, "fit": "on"}
try:
    with urllib.request.urlopen(f"{base.rstrip('/')}/v1/models", timeout=30) as r:
        data = json.load(r)
    for item in data.get("data") or []:
        if item.get("id") == model:
            out["context_length"] = item.get("context_length") or item.get("max_context_length")
            break
    if "context_length" not in out and data.get("data"):
        out["context_length"] = data["data"][0].get("context_length")
except Exception as e:
    out["error"] = str(e)
path = os.path.join(sdir, "summary.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
print(f"wrote {path}")
PY

if [[ "${SCHED_RESTART_LAB:-0}" == "1" ]]; then
  patch_lab_ini fit off
  restart_lab_server 0
fi

log "done $SCENARIO → $sdir/summary.json"
