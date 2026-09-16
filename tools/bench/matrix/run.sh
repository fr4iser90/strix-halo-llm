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
THROUGHPUT="$ROOT/tools/bench/throughput/run.sh"
QUALITY="$ROOT/tools/bench/quality/run.sh"
BUILD_INDEX="$ROOT/tools/bench/build-index.sh"
HALOGEN="$ROOT/tools/bench/halogen/run.sh"

# shellcheck source=../lib/python.sh
source "$ROOT/tools/bench/lib/python.sh"
# shellcheck source=../lib/engine.sh
source "$ROOT/tools/bench/lib/engine.sh"
# shellcheck source=../lib/host_mem.sh
source "$ROOT/tools/bench/lib/host_mem.sh"
# shellcheck source=../capacity/lib/sync_ini.sh
CAPACITY_INI_A="${CAPACITY_INI_A:-$ROOT/models-bench.ini}"
source "$ROOT/tools/bench/capacity/lib/sync_ini.sh"

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
  --engine NAME            llama.cpp (default) | halogen-flash
  --from LIST              override sync_from (coder,chat,lab)
  --model NAME[,NAME…]     only these models (exact or unique substring; repeatable)
  --no-vl                  drop *-VL twins (capacity/sched/quality)
  --only SUITE             capacity|sched|throughput|quality (repeatable)
  --skip-suite SUITE       disable a suite for this run
  --skip-dual              never run capacity dual (even if profile enables it)
  --force-dual             run dual even if host is below skip_below_*_gib
  --dry-run                print plan only

Profiles live in tools/bench/matrix/profiles/*.json — edit freely.
Same profile + different --engine: llama.cpp uses bench-a; halogen-flash uses HTTP :8731.
Alias: --profile full-halogen ≡ --profile full --engine halogen-flash

Examples:
  ./bench matrix --profile full --engine llama.cpp
  ./bench matrix --profile full --engine halogen-flash --model YOUR_API_MODEL
  ./bench matrix --profile full --only capacity
  ./bench matrix --profile full --no-vl
  ./bench matrix --profile default
  ./bench matrix --profile full --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B
  tmux new -s bench './bench matrix --profile full --engine halogen-flash --model …'
EOF
}

PROFILE="default"
DRY=0
FROM_OVERRIDE=""
ONLY=()
SKIP_SUITE=()
MATRIX_MODELS="${MATRIX_MODELS:-}"
MATRIX_NO_VL="${MATRIX_NO_VL:-0}"
MATRIX_SKIP_DUAL="${MATRIX_SKIP_DUAL:-0}"
MATRIX_FORCE_DUAL="${MATRIX_FORCE_DUAL:-0}"
MATRIX_ENGINE_CLI=""

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
  die "profile not found: $p (try: default, full — use --engine for Halogen)"
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
            bits = [f"{cap.get('index')}/{cap.get('total')} ({cap.get('pct')}%)"]
            if cap.get("remaining_run") is not None:
                bits.append(f"runs_left {cap.get('remaining_run')}")
            if cap.get("eta"):
                bits.append(f"ETA ~{cap.get('eta')}")
            data["detail"] = f"{detail} | {' '.join(bits)} | {cap.get('detail')}"
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
print(f"PROFILE_ENGINE={p.get('engine', '')!r}")
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
# Auto-skip dual on small hosts (GiB). 0 = never auto-skip.
print(f"CAP_DUAL_SKIP_BELOW_RAM={float(dual.get('skip_below_ram_gib') or 0)}")
print(f"CAP_DUAL_SKIP_BELOW_GTT={float(dual.get('skip_below_gtt_gib') or 0)}")
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
print(f"THR_SCOPE={thr.get('scope', 'bench')!r}")
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
  # Apply matrix --model / --no-vl via capacity resolver
  CAPACITY_MODELS="${MATRIX_MODELS:-}" CAPACITY_NO_VL="${MATRIX_NO_VL:-0}" \
    resolve_bench_models
}

# Returns 0 if dual should run.
matrix_dual_should_run() {
  [[ "${CAP_DUAL_ENABLED:-0}" == "1" ]] || return 1
  if [[ "${MATRIX_SKIP_DUAL:-0}" == "1" ]]; then
    log "skip dual (--skip-dual)"
    return 1
  fi
  if [[ "${MATRIX_FORCE_DUAL:-0}" == "1" ]]; then
    export CAPACITY_FORCE_DUAL=1
    return 0
  fi
  export CAPACITY_DUAL_SKIP_BELOW_RAM_GIB="${CAP_DUAL_SKIP_BELOW_RAM:-0}"
  export CAPACITY_DUAL_SKIP_BELOW_GTT_GIB="${CAP_DUAL_SKIP_BELOW_GTT:-0}"
  local reason
  if reason="$(dual_host_too_small)"; then
    log "skip dual: $reason (profile dual.skip_below_*; --force-dual to override)"
    return 1
  fi
  return 0
}

run_capacity() {
  [[ "${SUITE_CAPACITY_ENABLED:-0}" == "1" ]] || { log "capacity disabled in profile"; return 0; }
  suite_wanted capacity || { log "skip suite capacity (--only/--skip-suite)"; return 0; }
  write_progress "capacity" "kv-ctx"
  log "=== capacity kv-ctx ==="
  local cap_extra=()
  if [[ -n "${MATRIX_MODELS:-}" ]]; then
    cap_extra+=(--model "$MATRIX_MODELS")
  fi
  if [[ "${MATRIX_NO_VL:-0}" == "1" ]]; then
    cap_extra+=(--no-vl)
  fi
  "$CAPACITY" kv-ctx \
    --from "$SYNC_FROM" \
    --kv "$CAP_KV" \
    --c "$CAP_C" \
    "${cap_extra[@]}"
  if matrix_dual_should_run; then
    write_progress "capacity" "dual"
    log "=== capacity dual (c=$CAP_DUAL_C) ==="
    CAPACITY_DUAL_KV_LIST="$CAP_DUAL_KV" CAPACITY_DUAL_C="$CAP_DUAL_C" \
      CAPACITY_DUAL_SKIP_BELOW_RAM_GIB="${CAP_DUAL_SKIP_BELOW_RAM:-0}" \
      CAPACITY_DUAL_SKIP_BELOW_GTT_GIB="${CAP_DUAL_SKIP_BELOW_GTT:-0}" \
      CAPACITY_FORCE_DUAL="${CAPACITY_FORCE_DUAL:-${MATRIX_FORCE_DUAL:-0}}" \
      "$CAPACITY" dual --from "$SYNC_FROM" --kv "$CAP_DUAL_KV" "${cap_extra[@]}"
  fi
}

run_sched() {
  [[ "${SUITE_SCHED_ENABLED:-0}" == "1" ]] || { log "sched disabled in profile"; return 0; }
  suite_wanted sched || { log "skip suite sched"; return 0; }

  # shellcheck source=../scheduling/lib/server.sh
  SCHED_BENCH_ROOT="$ROOT/tools/bench/scheduling"
  export SCHED_BENCH_ROOT PROJECT_ROOT="$ROOT"
  source "$ROOT/tools/bench/scheduling/lib/server.sh"

  export SCHED_SYNC_SOURCES="$SYNC_FROM"
  export SCHED_NP="$SCHED_NP_VAL"
  export SCHED_UB="$SCHED_UB_VAL"
  export SCHED_B="$SCHED_B_VAL"
  export SCHED_UB_LIST="$SCHED_UB_LIST_VAL"
  export SCHED_NP_LIST="$SCHED_NP_LIST_VAL"
  export SCHED_B_LIST="$SCHED_B_LIST_VAL"
  export SCHED_MTP_LIST="$SCHED_MTP_LIST_VAL"
  export SCHED_RESTART_BENCH=1
  export SCHED_BENCH_OWNED=1
  sched_bench_prepare
  trap 'SCHED_BENCH_OWNED=0; sched_bench_cleanup' RETURN

  local models=() m scen
  mapfile -t models < <(models_from_bench_ini)
  [[ ${#models[@]} -gt 0 ]] || die "no models after sync — check --from / GGUFs"

  IFS=',' read -ra SCEN_ARR <<< "$SCHED_SCENARIOS"
  for m in "${models[@]}"; do
    [[ -n "$m" ]] || continue
    export SCHED_MODEL="$m"
    if ! sched_bench_load "$m"; then
      log "sched load failed for $m (continue)"
      continue
    fi
    for scen in "${SCEN_ARR[@]}"; do
      scen="${scen// /}"
      [[ -n "$scen" ]] || continue
      if [[ "$scen" == "mtp_sweep" && "$m" != *MTP* ]]; then
        log "skip mtp_sweep for non-MTP model $m"
        continue
      fi
      write_progress "sched" "$m / $scen"
      log "=== sched $m :: $scen ==="
      export SCHED_SKIP_BENCH=1 SCHED_NO_RESTORE=1
      case "$scen" in
        auto) "$SCHED" --auto --no-restore ;;
        *) "$SCHED" --scenario "$scen" --no-restore ;;
      esac
    done
  done
  SCHED_BENCH_OWNED=0
  sched_bench_cleanup
  trap - RETURN
  # Rebuild ★ recommendations for dashboard (np/ub/b)
  log "sched compare → scheduling/latest + index"
  "$SCHED" --compare || true
}

run_throughput() {
  [[ "${SUITE_THROUGHPUT_ENABLED:-0}" == "1" ]] || { log "throughput disabled"; return 0; }
  suite_wanted throughput || { log "skip suite throughput"; return 0; }
  write_progress "throughput" "$THR_BACKENDS"
  log "=== throughput $THR_SCOPE $THR_BACKENDS ==="
  local args=()
  case "$THR_SCOPE" in
    bench) args+=(--bench) ;;
    lab) args+=(--lab) ;;
    daily) args+=(--daily) ;;
    all) args+=(--all) ;;
    *) args+=(--bench) ;;
  esac
  IFS=',' read -ra B <<< "$THR_BACKENDS"
  local b
  for b in "${B[@]}"; do
    b="${b// /}"
    [[ -n "$b" ]] && args+=("--$b")
  done
  # Honor matrix --model filter (same list as capacity/sched/quality)
  if [[ -n "${MATRIX_MODELS:-}" ]]; then
    local pat
    IFS=',' read -ra _mp <<< "$MATRIX_MODELS"
    for pat in "${_mp[@]}"; do
      pat="${pat// /}"
      [[ -n "$pat" ]] && args+=(--models "$pat")
    done
  fi
  "$THROUGHPUT" "${args[@]}"
}

ensure_quality_humaneval() {
  [[ "$QUAL_SUITE" == "humaneval" ]] || return 0
  log "HumanEval preflight (venv + harness)…"
  # Call plugin directly — quality/run.sh uses exec and would replace this matrix process
  local he_run="$ROOT/tools/bench/quality/plugins/humaneval/run.sh"
  [[ -f "$he_run" ]] || die "missing $he_run"
  export PROJECT_ROOT="$ROOT"
  if ! bash "$he_run" --setup; then
    die "HumanEval setup failed — fix harness then re-run matrix (same command)"
  fi
  local vpy="$ROOT/output/bench/.venv-quality/bin/python3"
  if [[ -x "$vpy" ]]; then
    export BENCH_PYTHON="$vpy"
    export BENCH_PYTHON_MODE="$vpy"
  fi
  export HUMAN_EVAL_EXECUTE=1
  export PYTHONPATH="${ROOT}/tools/bench/quality/.vendor/human-eval${PYTHONPATH:+:$PYTHONPATH}"
  if ! bench_python -c "import human_eval.data" 2>/dev/null; then
    die "human_eval not importable after setup — check output/bench/.venv-quality"
  fi
  log "HumanEval ready (eval/pass@1 enabled)"
}

run_quality() {
  [[ "${SUITE_QUALITY_ENABLED:-0}" == "1" ]] || { log "quality disabled"; return 0; }
  suite_wanted quality || { log "skip suite quality"; return 0; }

  ensure_quality_humaneval

  # shellcheck source=../quality/lib/server.sh
  source "$ROOT/tools/bench/quality/lib/server.sh"
  export QUALITY_SYNC_SOURCES="$SYNC_FROM"
  export QUALITY_BENCH_OWNED=1
  export QUALITY_SKIP_BENCH=0
  quality_bench_prepare
  trap 'QUALITY_BENCH_OWNED=0; quality_bench_cleanup' RETURN

  local models=() m qargs=() failed=0
  mapfile -t models < <(models_from_bench_ini)
  qargs=(--n "$QUAL_N" --no-bench --eval)
  [[ "${QUAL_LIMIT:-0}" -gt 0 ]] && qargs+=(--limit "$QUAL_LIMIT")
  export QUALITY_BASE_URL="http://127.0.0.1:11601"
  export QUALITY_SKIP_BENCH=1
  export HUMAN_EVAL_EXECUTE=1
  for m in "${models[@]}"; do
    [[ -n "$m" ]] || continue
    write_progress "quality" "$QUAL_SUITE / $m"
    log "=== quality $QUAL_SUITE $m (bench-a) ==="
    if ! quality_bench_load "$m"; then
      log "quality load failed for $m"
      failed=1
      continue
    fi
    # Plugin must not tear down bench between models (--no-bench + owned lifecycle)
    if ! QUALITY_MODEL="$m" QUALITY_SKIP_BENCH=1 HUMAN_EVAL_EXECUTE=1 \
      "$QUALITY" "$QUAL_SUITE" --model "$m" --base-url "$QUALITY_BASE_URL" "${qargs[@]}"; then
      log "quality FAILED for $m"
      failed=1
    fi
  done
  QUALITY_BENCH_OWNED=0
  quality_bench_cleanup
  trap - RETURN
  "$QUALITY" compare || true
  [[ "$failed" -eq 0 ]] || die "HumanEval/quality failed for one or more models — see log (not silent continue)"
}

print_plan() {
  local models_line="${MATRIX_MODELS:-all}"
  local dual_line
  [[ "${MATRIX_NO_VL:-0}" == "1" ]] && models_line+=" (--no-vl)"
  if [[ "${CAP_DUAL_ENABLED:-0}" != "1" ]]; then
    dual_line="off (profile)"
  elif [[ "${MATRIX_SKIP_DUAL:-0}" == "1" ]]; then
    dual_line="skip (--skip-dual)"
  else
    dual_line="on ($CAP_DUAL_KV @ $CAP_DUAL_C)"
    if [[ "${MATRIX_FORCE_DUAL:-0}" == "1" ]]; then
      dual_line+="; force"
    else
      dual_line+="; auto-skip if RAM<${CAP_DUAL_SKIP_BELOW_RAM} or GTT<${CAP_DUAL_SKIP_BELOW_GTT} GiB"
    fi
  fi
  cat <<EOF
Profile: $PROFILE_PATH
  engine:        ${BENCH_ENGINE:-llama.cpp}
  sync_from:     $SYNC_FROM
  models:        $models_line
  capacity:      enabled=$SUITE_CAPACITY_ENABLED kv=$CAP_KV c=$CAP_C dual=$dual_line
  sched:         enabled=$SUITE_SCHED_ENABLED scenarios=$SCHED_SCENARIOS
  throughput:    enabled=$SUITE_THROUGHPUT_ENABLED $THR_SCOPE $THR_BACKENDS
  quality:       enabled=$SUITE_QUALITY_ENABLED $QUAL_SUITE n=$QUAL_N limit=$QUAL_LIMIT (HumanEval auto-setup+eval)
EOF
}

run_matrix() {
  # Alias kept for muscle memory: full-halogen ≡ full + --engine halogen-flash
  if [[ "$PROFILE" == "full-halogen" ]]; then
    PROFILE="full"
    [[ -z "${MATRIX_ENGINE_CLI:-}" ]] && MATRIX_ENGINE_CLI="halogen-flash"
  fi

  eval "$(load_profile)"
  [[ -n "$FROM_OVERRIDE" ]] && SYNC_FROM="$FROM_OVERRIDE"

  # Unified engine: --engine > BENCH_ENGINE env > profile.engine > llama.cpp
  BENCH_ENGINE="$(bench_engine_resolve "${MATRIX_ENGINE_CLI:-}" "${PROFILE_ENGINE:-}")" \
    || die "set --engine to a known engine: $(bench_engine_known)"
  export BENCH_ENGINE
  export MATRIX_MODELS MATRIX_NO_VL MATRIX_SKIP_DUAL MATRIX_FORCE_DUAL

  case "$BENCH_ENGINE" in
    halogen-flash)
      log "engine=halogen-flash → HTTP matrix @ ${HALOGEN_BASE_URL:-http://127.0.0.1:8731}"
      print_plan
      if [[ "$DRY" == "1" ]]; then
        log "dry-run — would run halogen HTTP suites"
        return 0
      fi
      mkdir -p "$OUT"
      write_progress "start" "$PROFILE_NAME"
      local hargs=(matrix)
      [[ -n "${MATRIX_MODELS:-}" ]] && hargs+=(--model "$MATRIX_MODELS")
      if [[ -n "${CAP_C:-}" ]]; then
        export CAPACITY_C_LIST="$CAP_C" HALOGEN_C_LIST="$CAP_C"
      fi
      chmod +x "$HALOGEN" "$ROOT"/tools/bench/halogen/*.sh 2>/dev/null || true
      "$HALOGEN" "${hargs[@]}"
      write_progress "done" "$PROFILE_NAME"
      log "matrix done (halogen-flash) — ./bench publish to update Pages"
      return 0
      ;;
    llama.cpp)
      ;;
    *)
      die "no matrix adapter for engine=$BENCH_ENGINE (known: $(bench_engine_known))"
      ;;
  esac

  print_plan
  if [[ "$DRY" == "1" ]]; then
    if [[ "${CAP_DUAL_ENABLED:-0}" == "1" && "${MATRIX_SKIP_DUAL:-0}" != "1" ]]; then
      export CAPACITY_DUAL_SKIP_BELOW_RAM_GIB="${CAP_DUAL_SKIP_BELOW_RAM:-0}"
      export CAPACITY_DUAL_SKIP_BELOW_GTT_GIB="${CAP_DUAL_SKIP_BELOW_GTT:-0}"
      [[ "${MATRIX_FORCE_DUAL:-0}" == "1" ]] && export CAPACITY_FORCE_DUAL=1
      local reason
      if reason="$(dual_host_too_small)"; then
        log "dry-run note: dual would skip ($reason)"
      else
        log "dry-run note: dual would run"
      fi
    fi
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
    line = f"capacity: {cap.get('index')}/{cap.get('total')} ({cap.get('pct')}%)"
    if cap.get("remaining_run") is not None:
        line += f"  runs_left {cap.get('remaining_run')}"
    if cap.get("eta"):
        line += f"  ETA ~{cap.get('eta')}"
    print(line)
    if cap.get("detail"):
        print(f"  cell:   {cap.get('detail')}")
    if cap.get("avg_cell_s"):
        print(f"  avg:    ~{cap.get('avg_cell_s')}s/run (session wall)")
    elif cap.get("remaining_run"):
        print("  ETA:    pending first real run")
    if cap.get("skipped") is not None or cap.get("ran") is not None:
        print(f"  done:   ran={cap.get('ran', 0)} skipped={cap.get('skipped', 0)}")
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
    --engine)
      shift
      MATRIX_ENGINE_CLI="${1:?}"
      shift
      ;;
    --from) shift; FROM_OVERRIDE="${1:?}"; shift ;;
    --model|--models)
      shift
      if [[ -n "${MATRIX_MODELS:-}" ]]; then
        MATRIX_MODELS="${MATRIX_MODELS},${1:?}"
      else
        MATRIX_MODELS="${1:?}"
      fi
      shift
      ;;
    --no-vl) MATRIX_NO_VL=1; shift ;;
    --skip-dual) MATRIX_SKIP_DUAL=1; shift ;;
    --force-dual) MATRIX_FORCE_DUAL=1; shift ;;
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
