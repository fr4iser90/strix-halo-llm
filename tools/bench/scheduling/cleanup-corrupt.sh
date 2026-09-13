#!/usr/bin/env bash
# Remove scheduling runs with 0 chunks (broken stream client era).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCH="$ROOT/output/bench/scheduling"
SCHED_BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_active() {
  local run="$1"
  # Skip runs touched in the last 10 minutes (likely in progress).
  if find "$run" -type f -mmin -10 2>/dev/null | grep -q .; then
    return 0
  fi
  # Skip if any bench process still references this directory.
  if pgrep -af "scheduling/$(basename "$run")" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

removed=0
kept=0

for run in "$SCH"/20*/; do
  [[ -d "$run" ]] || continue
  base="$(basename "$run")"

  # Drop empty run stubs (failed before manifest/scenarios).
  if [[ ! -f "$run/manifest.json" ]] && ! find "$run" -mindepth 1 -maxdepth 2 -type f 2>/dev/null | grep -q .; then
    echo "remove empty run: $base"
    rm -rf "$run"
    removed=$((removed + 1))
    continue
  fi

  if run_active "$run"; then
    echo "skip active run: $base"
    continue
  fi

  corrupt=0
  while IFS= read -r summary; do
    [[ -f "$summary" ]] || continue
    chunks="$(grep -oE '"chunks": [0-9]+' "$summary" | head -1 | grep -oE '[0-9]+' || echo 0)"
    scen="$(basename "$(dirname "$summary")")"
    if [[ "$scen" == "04_ub_sweep" || "$scen" == "05_np_sweep" || "$scen" == "06_b_sweep" ]]; then
      continue
    fi
    if [[ "$chunks" == "0" ]]; then
      corrupt=1
      break
    fi
  done < <(find "$run" -name summary.json 2>/dev/null)

  if [[ "$corrupt" == "1" ]]; then
    echo "remove corrupt run: $base"
    rm -rf "$run"
    removed=$((removed + 1))
  elif [[ -f "$run/manifest.json" ]]; then
    echo "keep valid run: $base"
    kept=$((kept + 1))
  fi
done

# Remove incomplete ub_sweep-only stubs (no baseline, no summary).
for run in "$SCH"/20*/; do
  [[ -d "$run" ]] || continue
  base="$(basename "$run")"
  run_active "$run" && { echo "skip active stub: $base"; continue; }
  for sweep in 04_ub_sweep 05_np_sweep 06_b_sweep 07_cont_batch 08_ctx_sweep; do
    if [[ -d "$run/$sweep" && ! -f "$run/$sweep/summary.json" && ! -f "$run/01_baseline_solo/summary.json" ]]; then
      echo "remove incomplete ${sweep} stub: $base"
      rm -rf "$run"
      removed=$((removed + 1))
      break
    fi
  done
done

echo "cleanup: removed=$removed kept=$kept"

# Rebuild index/compare without touching routers (compare-only has no trap).
[[ -x "$ROOT/bench" ]] && "$ROOT/bench" index || true
[[ -x "$ROOT/bench" ]] && "$ROOT/bench" compare-sched || true
