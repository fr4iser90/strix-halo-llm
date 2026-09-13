#!/usr/bin/env bash
# Legacy alias → 10_mtp_sweep (off,1,2,3,4).
set -euo pipefail
exec bash "$SCHED_BENCH_ROOT/scenarios/10_mtp_sweep.sh"
