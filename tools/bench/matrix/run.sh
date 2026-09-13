#!/usr/bin/env bash
# Full / default multi-suite matrix orchestrator (multi-day capable, resume via suite skips).
#
#   ./bench matrix --profile full
#   ./bench matrix --profile default
#   ./bench matrix status
#   ./bench matrix list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROFILES="$SCRIPT_DIR/profiles"
OUT="$ROOT/output/bench/matrix"
PROGRESS="$OUT/progress.json"
CAPACITY="$ROOT/tools/bench/capacity/run.sh"
SCHED="$ROOT/tools/bench/scheduling/run.sh"
THROUGHPUT="$ROOT/tools/bench/throughput/llama-bench-all.sh"
QUALITY="$ROOT/tools/bench/quality/run.sh"
BUILD_INDEX="$ROOT/tools/bench/build-index.sh"

# shellcheck source=../lib/python.sh
source "$ROOT/tools/bench/lib/python.sh"

die() { printf '[bench matrix] error: %s\n' "$*" >&2; exit 1; }
log() { printf '[bench matrix] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./bench matrix [command] [options]

Commands:
  run                      run matrix (default if profile given)
  status                   show progress.json
  list                     list profiles
  help

Options:
  --profile NAME|FILE      default | full | path/to.json  (default: default)
  --from LIST              override sync_from (coder,chat,lab)
  --only SUITE             capacity|sched|throughput|quality (repeatable)
  --skip-suite SUITE       disable a suite for this run
  --dry-run                print plan only

Profiles live in tools/bench/matrix/profiles/*.json — edit freely.
Full profile is multi-day; safe to Ctrl+C and re-run (capacity/sched skip done cells).

Examples:
  ./bench matrix --profile full
  ./bench matrix --profile full --only capacity
  ./bench matrix --profile default --from coder
  tmux new -s bench './bench matrix --profile full'
EOF
}

PROFILE="default"
DRY=0
FROM_OVERRIDE=""
ONLY=()
SKIP_SUITE=()

resolve_profile() {
  local p="$1"
  if [[ -f "$p" ]]; then
    printf '%s\n' "$p"
    return
  fi
  if [[ -f "$PROFILES/${p}.json" ]]; then
    printf '%s\n' "$PROFILES/${p}.json"
    return
  fi
  die "profile not found: $p (try: default, full)"
}

write_progress() {
  local phase="$1" detail="${2:-}"
  mkdir -p "$OUT"
  local cap_prog="$ROOT/output/bench/capacity/progress.json"
  bench_python - "$PROGRESS" "$phase" "$detail" "${PROFILE_PATH-}" "$cap_prog" <<'PY'
import json, os, sys, time
path, phase, detail, profile, cap_prog = sys.argv[1:6]
data = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
data["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
data["phase"] = phase
data["detail"] = detail
if profile:
    data["profile"] = profile
# Merge live capacity cell progress when present
if os.path.isfile(cap_prog):
    try:
        with open(cap_prog, encoding="utf-8") as f:
            cap = json.load(f)
        data["capacity"] = {
            "index": cap.get("index"),
            "total": cap.get("total"),
            "pct": cap.get("pct"),
            "eta": cap.get("eta"),
            "detail": cap.get("detail"),
            "updated": cap.get("updated"),
        }
        if phase.startswith("capacity") and cap.get("detail"):
            data["detail"] = f"{detail} | {cap.get('index')}/{cap.get('total')} ({cap.get('pct')}%) ETA ~{cap.get('eta')} | {cap.get('detail')}"
    except Exception:
        pass
data.setdefault("log", [])
data["log"].append({"t": data["updated"], "phase": phase, "detail": data.get("detail", detail)})
data["log"] = data["log"][-200:]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

load_profile() {
  local path
  path="$(resolve_profile "$PROFILE")"
  PROFILE_PATH="$path"
  export PROFILE_PATH
  bench_python - "$path" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    p = json.load(f)
print(f"PROFILE_PATH={sys.argv[1]!r}")
print(f"PROFILE_NAME={p.get('name','')!r}")
sf = p.get("sync_from", "coder,chat")
print(f"SYNC_FROM={sf!r}")
suites = p.get("suites") or {}
for name in ("capacity", "sched", "throughput", "quality"):
    s = suites.get(name) or {}
    en = 1 if s.get("enabled") else 0
    print(f"SUITE_{name.upper()}_ENABLED={en}")
cap = suites.get("capacity") or {}
kv = ",".join(cap.get("kv") or [])
c = ",".join(str(x) for x in (cap.get("c") or []))
print(f"CAP_KV={kv!r}")
print(f"CAP_C={c!r}")
dual = cap.get("dual") or {}
print(f"CAP_DUAL_ENABLED={1 if dual.get('enabled') else 0}")
dkv = ",".join(dual.get("kv") or [])
print(f"CAP_DUAL_KV={dkv!r}")
dc = dual.get("c", "auto")
if dc is None or dc == "auto":
    print("CAP_DUAL_C='auto'")
elif isinstance(dc, (list, tuple)):
    print(f"CAP_DUAL_C={','.join(str(x) for x in dc)!r}")
else:
    print(f"CAP_DUAL_C={str(dc)!r}")
sch = suites.get("sched") or {}
scen = ",".join(sch.get("scenarios") or [])
print(f"SCHED_SCENARIOS={scen!r}")
print(f"SCHED_NP_VAL={sch.get('np', 2)}")
print(f"SCHED_UB_VAL={sch.get('ub', 32)}")
print(f"SCHED_B_VAL={sch.get('b', 64)}")
print(f"SCHED_UB_LIST_VAL={sch.get('ub_list', '32,64,128,256')!r}")
print(f"SCHED_NP_LIST_VAL={sch.get('np_list', '1,2,4')!r}")
print(f"SCHED_B_LIST_VAL={sch.get('b_list', '32,64,128,256')!r}")
print(f"SCHED_MTP_LIST_VAL={sch.get('mtp_list', 'off,1,2,3,4')!r}")
thr = suites.get("throughput") or {}
backends = ",".join(thr.get("backends") or ["vulkan"])
print(f"THR_BACKENDS={backends!r}")
print(f"THR_SCOPE={thr.get('scope', 'lab')!r}")
qual = suites.get("quality") or {}
print(f"QUAL_SUITE={qual.get('suite', 'humaneval')!r}")
print(f"QUAL_N={qual.get('n', 1)}")
print(f"QUAL_LIMIT={qual.get('limit', 0)}")
PY
}

suite_wanted() {
  local name="$1"
  local i
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    for i in "${ONLY[@]}"; do
      [[ "$i" == "$name" ]] && return 0
    done
    return 1
  fi
  for i in "${SKIP_SUITE[@]}"; do
    [[ "$i" == "$name" ]] && return 1
  done
  return 0
}

models_from_bench_ini() {
  bench_python - "$ROOT/models-bench.ini" <<'PY'
import sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("[") and line.endswith("]") and not line.startswith(";"):
                print(line[1:-1].strip())
except FileNotFoundError:
    pass
PY
}

run_capacity() {
  [[ "${SUITE_CAPACITY_ENABLED:-0}" == "1" ]] || { log "capacity disabled in profile"; return 0; }
  suite_wanted capacity || { log "skip suite capacity (--only/--skip-suite)"; return 0; }
  write_progress "capacity" "kv-ctx"
  log "=== capacity kv-ctx ==="
  "$CAPACITY" kv-ctx \
    --from "$SYNC_FROM" \
    --kv "$CAP_KV" \
    --c "$CAP_C"
  if [[ "${CAP_DUAL_ENABLED:-0}" == "1" ]]; then
    write_progress "capacity" "dual"
    log "=== capacity dual (c=$CAP_DUAL_C) ==="
    CAPACITY_DUAL_KV_LIST="$CAP_DUAL_KV" CAPACITY_DUAL_C="$CAP_DUAL_C" \
      "$CAPACITY" dual --from "$SYNC_FROM" --kv "$CAP_DUAL_KV"
  fi
}

run_sched() {
  [[ "${SUITE_SCHED_ENABLED:-0}" == "1" ]] || { log "sched disabled in profile"; return 0; }
  suite_wanted sched || { log "skip suite sched"; return 0; }

  # Ensure bench ini synced so we know model list; sched uses lab
  "$CAPACITY" sync --from "$SYNC_FROM" >/dev/null || true

  export SCHED_NP="$SCHED_NP_VAL"
  export SCHED_UB="$SCHED_UB_VAL"
  export SCHED_B="$SCHED_B_VAL"
  export SCHED_UB_LIST="$SCHED_UB_LIST_VAL"
  export SCHED_NP_LIST="$SCHED_NP_LIST_VAL"
  export SCHED_B_LIST="$SCHED_B_LIST_VAL"
  export SCHED_MTP_LIST="$SCHED_MTP_LIST_VAL"
  export SCHED_RESTART_LAB=1

  local models=() m scen
  mapfile -t models < <(models_from_bench_ini)
  [[ ${#models[@]} -gt 0 ]] || die "no models after sync — check --from / GGUFs"

  IFS=',' read -ra SCEN_ARR <<< "$SCHED_SCENARIOS"
  for m in "${models[@]}"; do
    [[ -n "$m" ]] || continue
    export SCHED_MODEL="$m"
    for scen in "${SCEN_ARR[@]}"; do
      scen="${scen// /}"
      [[ -n "$scen" ]] || continue
      if [[ "$scen" == "mtp_sweep" && "$m" != *MTP* ]]; then
        log "skip mtp_sweep for non-MTP model $m"
        continue
      fi
      write_progress "sched" "$m / $scen"
      log "=== sched $m :: $scen ==="
      case "$scen" in
        auto) "$SCHED" --auto ;;
        *) "$SCHED" --scenario "$scen" ;;
      esac
    done
  done
}

run_throughput() {
  [[ "${SUITE_THROUGHPUT_ENABLED:-0}" == "1" ]] || { log "throughput disabled"; return 0; }
  suite_wanted throughput || { log "skip suite throughput"; return 0; }
  write_progress "throughput" "$THR_BACKENDS"
  log "=== throughput $THR_SCOPE $THR_BACKENDS ==="
  local args=()
  case "$THR_SCOPE" in
    lab) args+=(--lab) ;;
    daily) args+=(--daily) ;;
    all) args+=(--all) ;;
    *) args+=(--lab) ;;
  esac
  IFS=',' read -ra B <<< "$THR_BACKENDS"
  local b
  for b in "${B[@]}"; do
    b="${b// /}"
    [[ -n "$b" ]] && args+=("--$b")
  done
  "$THROUGHPUT" "${args[@]}"
}

run_quality() {
  [[ "${SUITE_QUALITY_ENABLED:-0}" == "1" ]] || { log "quality disabled"; return 0; }
  suite_wanted quality || { log "skip suite quality"; return 0; }

  # shellcheck source=../quality/lib/server.sh
  source "$ROOT/tools/bench/quality/lib/server.sh"
  export QUALITY_SYNC_SOURCES="$SYNC_FROM"
  export QUALITY_BENCH_OWNED=1
  export QUALITY_SKIP_BENCH=0
  quality_bench_prepare
  trap 'QUALITY_BENCH_OWNED=0; quality_bench_cleanup' RETURN

  local models=() m qargs=()
  mapfile -t models < <(models_from_bench_ini)
  qargs=(--n "$QUAL_N" --no-bench)
  [[ "${QUAL_LIMIT:-0}" -gt 0 ]] && qargs+=(--limit "$QUAL_LIMIT")
  export QUALITY_BASE_URL="http://127.0.0.1:11601"
  export QUALITY_SKIP_BENCH=1
  for m in "${models[@]}"; do
    [[ -n "$m" ]] || continue
    write_progress "quality" "$QUAL_SUITE / $m"
    log "=== quality $QUAL_SUITE $m (bench-a) ==="
    if ! quality_bench_load "$m"; then
      log "quality load failed for $m (continue)"
      continue
    fi
    # Plugin must not tear down bench between models (--no-bench + owned lifecycle)
    QUALITY_MODEL="$m" QUALITY_SKIP_BENCH=1 \
      "$QUALITY" "$QUAL_SUITE" --model "$m" --base-url "$QUALITY_BASE_URL" "${qargs[@]}" \
      || log "quality failed for $m (continue)"
  done
  QUALITY_BENCH_OWNED=0
  quality_bench_cleanup
  trap - RETURN
}

print_plan() {
  cat <<EOF
Profile: $PROFILE_PATH
  sync_from:     $SYNC_FROM
  capacity:      enabled=$SUITE_CAPACITY_ENABLED kv=$CAP_KV c=$CAP_C dual=$CAP_DUAL_ENABLED ($CAP_DUAL_KV @ $CAP_DUAL_C)
  sched:         enabled=$SUITE_SCHED_ENABLED scenarios=$SCHED_SCENARIOS
  throughput:    enabled=$SUITE_THROUGHPUT_ENABLED $THR_SCOPE $THR_BACKENDS
  quality:       enabled=$SUITE_QUALITY_ENABLED $QUAL_SUITE n=$QUAL_N limit=$QUAL_LIMIT
EOF
}

run_matrix() {
  eval "$(load_profile)"
  [[ -n "$FROM_OVERRIDE" ]] && SYNC_FROM="$FROM_OVERRIDE"
  print_plan
  if [[ "$DRY" == "1" ]]; then
    log "dry-run — exiting"
    return 0
  fi
  mkdir -p "$OUT"
  write_progress "start" "$PROFILE_NAME"
  # Capture hardware for Pages / compareability
  if [[ -x "$ROOT/tools/bench/probe-host.sh" ]]; then
    "$ROOT/tools/bench/probe-host.sh" || true
  fi
  run_capacity
  run_sched
  run_throughput
  run_quality
  write_progress "index" ""
  [[ -x "$BUILD_INDEX" ]] && "$BUILD_INDEX" || true
  "$CAPACITY" compare || true
  write_progress "done" "$PROFILE_NAME"
  log "matrix done — see $PROGRESS and ./bench index"
  log "Pages: ./bench publish && git add docs && git commit && git push"
}

show_status() {
  if [[ ! -f "$PROGRESS" ]]; then
    echo "No matrix progress yet. Start with: ./bench matrix --profile full"
    return 0
  fi
  local cap_prog="$ROOT/output/bench/capacity/progress.json"
  bench_python - "$PROGRESS" "$cap_prog" <<'PY'
import json, sys, os
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
print(f"profile:  {d.get('profile','—')}")
print(f"phase:    {d.get('phase','—')}")
print(f"detail:   {d.get('detail','—')}")
print(f"updated:  {d.get('updated','—')}")
cap = d.get("capacity") or {}
cap_path = sys.argv[2]
if os.path.isfile(cap_path):
    try:
        with open(cap_path, encoding="utf-8") as f:
            cap = json.load(f)
    except Exception:
        pass
if cap.get("total"):
    print("")
    print(f"capacity: {cap.get('index')}/{cap.get('total')} ({cap.get('pct')}%)  ETA ~{cap.get('eta','?')}")
    if cap.get("detail"):
        print(f"  cell:   {cap.get('detail')}")
    if cap.get("avg_cell_s"):
        print(f"  avg:    ~{cap.get('avg_cell_s')}s/cell (timed)")
print("")
print("recent log:")
for e in (d.get("log") or [])[-15:]:
    print(f"  {e.get('t')}  {e.get('phase')}: {e.get('detail')}")
PY
}

# --- argv ---
CMD="run"
while [[ $# -gt 0 ]]; do
  case "$1" in
    help|-h|--help) usage; exit 0 ;;
    status) CMD=status; shift; break ;;
    list) CMD=list; shift; break ;;
    run) CMD=run; shift ;;
    --profile) shift; PROFILE="${1:?}"; shift ;;
    --from) shift; FROM_OVERRIDE="${1:?}"; shift ;;
    --only) shift; ONLY+=("${1:?}"); shift ;;
    --skip-suite) shift; SKIP_SUITE+=("${1:?}"); shift ;;
    --dry-run) DRY=1; shift ;;
    *)
      # bare profile name as first arg
      if [[ -f "$PROFILES/${1}.json" || -f "$1" ]]; then
        PROFILE="$1"; shift
      else
        die "unknown arg: $1"
      fi
      ;;
  esac
done

case "$CMD" in
  list)
    echo "Profiles in $PROFILES:"
    for f in "$PROFILES"/*.json; do
      [[ -f "$f" ]] || continue
      bench_python - "$f" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
print(f"  {p.get('name')}: {p.get('description','')}")
PY
    done
    ;;
  status) show_status ;;
  run) run_matrix ;;
esac
