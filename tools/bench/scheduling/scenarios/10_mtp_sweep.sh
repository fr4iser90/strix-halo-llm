#!/usr/bin/env bash
# 10: Interleave (03) for MTP off + draft-mtp n-max in SCHED_MTP_LIST (default off,1,2,3,4).
# Patches only [SCHED_MODEL] in models-bench.ini, restarts bench-a, restores keys afterwards.
set -euo pipefail
SCENARIO="10_mtp_sweep"
source "$SCHED_BENCH_ROOT/lib/common.sh"
source "$SCHED_BENCH_ROOT/lib/ini_patch.sh"

sdir="$(scenario_dir "$SCENARIO")"
mkdir -p "$sdir"

IFS=',' read -ra MTP_VALUES <<< "${SCHED_MTP_LIST:-off,1,2,3,4}"
fix_np="${SCHED_SWEEP_NP:-${SCHED_NP:-2}}"
fix_ub="${SCHED_SWEEP_UB:-${SCHED_UB:-128}}"
section="$SCHED_MODEL"
restart="${SCHED_RESTART_LAB:-1}"

orig_type="$(get_bench_ini_section_key "$section" "spec-type")"
orig_nmax="$(get_bench_ini_section_key "$section" "spec-draft-n-max")"
if [[ -z "$orig_type" && -z "$orig_nmax" ]]; then
  die "section [$section] has no spec-type / spec-draft-n-max — pick an *-MTP* preset"
fi

restore_mtp() {
  if [[ -n "$orig_type" ]]; then
    patch_bench_ini_section "$section" "spec-type" "$orig_type"
  fi
  if [[ -n "$orig_nmax" ]]; then
    patch_bench_ini_section "$section" "spec-draft-n-max" "$orig_nmax"
  fi
}
trap restore_mtp EXIT

if [[ "$restart" == "1" ]]; then
  patch_bench_ini np "$fix_np"
  patch_bench_ini ub "$fix_ub"
fi

for n in "${MTP_VALUES[@]}"; do
  n="${n// /}"
  [[ -n "$n" ]] || continue
  sub="$sdir/n_${n}"
  mkdir -p "$sub"

  if [[ "$restart" != "1" ]]; then
    log "n=$n (set SCHED_RESTART_LAB=1 to auto-patch ini / restart)"
  else
    if [[ "$n" == "off" ]]; then
      log "MTP off — patch [${section}] spec-type=none"
      patch_bench_ini_section "$section" "spec-type" "none"
    else
      [[ "$n" =~ ^[0-9]+$ ]] || die "invalid MTP depth: $n (want off|1|2|…)"
      log "MTP draft-mtp n-max=$n — patch [${section}]"
      patch_bench_ini_section "$section" "spec-type" "draft-mtp"
      patch_bench_ini_section "$section" "spec-draft-n-max" "$n"
    fi
    restart_bench_patched
  fi

  export SCHED_RUN_DIR="$sub"
  bash "$SCHED_BENCH_ROOT/scenarios/03_interleave_np2.sh"
  mv "$sub/03_interleave_np2" "$sub/run" 2>/dev/null || true
done

merge_mtp_summary "$sdir"
log "done $SCENARIO → $sdir/summary.json (recommended=$(bench_python -c "import json;print(json.load(open('$sdir/summary.json')).get('recommended','?'))" 2>/dev/null || echo '?'))"
