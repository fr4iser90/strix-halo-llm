#!/usr/bin/env bash
# Capacity suite — auto-syncs models-bench.ini from coder/chat(/lab), then runs.
#
#   ./bench capacity sync
#   ./bench capacity kv-ctx
#   ./bench capacity dual              # c auto from RAM/GTT (or CAPACITY_DUAL_C=…)
#   ./bench capacity compare
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./bench capacity <command> [options]

Commands:
  sync                     refresh models-bench.ini from coder/chat(/lab)
  list                     show models currently in models-bench.ini
  fingerprint              show current llama-server / image fingerprint
  stale                    list ledger cells stale vs current fingerprint
  kv-ctx | kv              solo KV×ctx (default: ALL synced models)
  dual                     two bench instances concurrent (c auto from host;
                           auto-skips if RAM/GTT below ~64/48 GiB —
                           CAPACITY_FORCE_DUAL=1 to override)
  compare                  rebuild latest compare from cells.jsonl
  help

Dual context sizes:
  Default CAPACITY_DUAL_C=auto → ladder from GTT/RAM (small hosts → 8k–64k,
  mid → up to 128k/196k, Strix-class → up to 256k). Override:
    CAPACITY_DUAL_C=131072
    CAPACITY_DUAL_C=32768,65536,131072
  Ascending fail stops that model+kv ladder (CAPACITY_DUAL_STOP_ON_FAIL=1).

Auto (default):
  • sync models-bench.ini + models-bench-b.ini from CAPACITY_SYNC_SOURCES
  • stop sticky/lab for clean GTT, start llama-bench-a[/b], restore after
  • skip cells already ok in cells.jsonl **with same server_version + image_id**

Options:
  --model NAME[,NAME…]     only these models (exact or unique substring; repeatable)
  --no-vl                  drop *-VL twin sections
  --from LIST              sync sources: coder,chat,lab  (default coder,chat)
  --kv LIST                KV cache types (default q8_0,q5_0,q4_0; probed vs llama-server -h)
  --c LIST                 solo kv-ctx contexts (default 32k…256k)
  --force                  re-run even if ledger has ok cell
  --no-skip                disable skip-existing
  --retry-failed           re-run previously failed cells
  --no-sync                do not refresh bench INIs before run
  --keep-sticky            leave sticky routers running
  --no-restore             do not restart stickys after run
  --backend NAME           recorded in ledger (default vulkan)

Examples:
  ./bench capacity sync
  ./bench capacity kv-ctx
  ./bench capacity dual
  ./bench capacity kv-ctx --model Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL,Cyber-Tiel,Qwen3.6-35B
  ./bench capacity kv-ctx --no-vl
  CAPACITY_DUAL_C=65536 ./bench capacity dual --kv q5_0,q4_0
EOF
}

parse_opts() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model|--models)
        shift
        local add="${1:?}"
        if [[ -n "${CAPACITY_MODELS:-}" ]]; then
          CAPACITY_MODELS="${CAPACITY_MODELS},${add}"
        else
          CAPACITY_MODELS="$add"
        fi
        export CAPACITY_MODELS
        CAPACITY_MODEL="$CAPACITY_MODELS"
        export CAPACITY_MODEL
        ;;
      --no-vl)
        CAPACITY_NO_VL=1; export CAPACITY_NO_VL ;;
      --from)
        shift; CAPACITY_SYNC_SOURCES="${1:?}"; export CAPACITY_SYNC_SOURCES ;;
      --kv)
        shift; CAPACITY_KV_LIST="${1:?}"; export CAPACITY_KV_LIST ;;
      --c)
        shift; CAPACITY_C_LIST="${1:?}"; export CAPACITY_C_LIST ;;
      --force)
        CAPACITY_FORCE=1; export CAPACITY_FORCE ;;
      --no-skip)
        CAPACITY_SKIP_EXISTING=0; export CAPACITY_SKIP_EXISTING ;;
      --retry-failed)
        CAPACITY_RETRY_FAILED=1; export CAPACITY_RETRY_FAILED ;;
      --no-sync)
        CAPACITY_AUTO_SYNC=0; export CAPACITY_AUTO_SYNC ;;
      --keep-sticky)
        CAPACITY_KEEP_STICKY=1; export CAPACITY_KEEP_STICKY ;;
      --no-restore)
        CAPACITY_NO_RESTORE=1; export CAPACITY_NO_RESTORE ;;
      --backend)
        shift; CAPACITY_BACKEND="${1:?}"; export CAPACITY_BACKEND ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "unknown option: $1" ;;
    esac
    shift
  done
}

compare_from_ledger() {
  mkdir -p "$CAPACITY_OUT/latest"
  bench_python - "$CELLS_LEDGER" "$CAPACITY_OUT/latest/compare.md" <<'PY'
import json, os, sys
ledger, out = sys.argv[1], sys.argv[2]
latest = {}
if os.path.isfile(ledger):
    with open(ledger, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            key = row.get("key")
            if key:
                latest[key] = row
rows = list(latest.values())
lines = ["# Capacity ledger (latest per cell)", "", f"Cells: {len(rows)}", ""]
solo = [r for r in rows if r.get("mode") == "solo" and not r.get("skipped")]
if solo:
    for model in sorted({r["model"] for r in solo}):
        sub = [r for r in solo if r["model"] == model]
        kvs = sorted({r["kv"] for r in sub})
        cs = sorted({r["c"] for r in sub})
        by = {(r["kv"], r["c"]): r for r in sub}
        lines += [f"## {model} (solo)", "", "| c \\ kv | " + " | ".join(kvs) + " |", "| --- | " + " | ".join(["---:"] * len(kvs)) + " |"]
        for c in cs:
            cells = []
            for kv in kvs:
                r = by.get((kv, c))
                if not r:
                    cells.append("—")
                elif not r.get("ok"):
                    cells.append("FAIL")
                else:
                    gtt = (r.get("metrics_peak") or {}).get("gtt_used_mb") or (r.get("mem_after") or {}).get("gtt_used_mb")
                    cells.append(str(gtt) if gtt is not None else "?")
            lines.append(f"| {c} | " + " | ".join(cells) + " |")
        lines.append("")
dual = [r for r in rows if r.get("mode") == "dual"]
if dual:
    lines += ["## Dual", "", "| model | kv | c | ok | GTT peak |", "| --- | --- | ---: | --- | ---: |"]
    for r in dual:
        gtt = (r.get("metrics_peak") or {}).get("gtt_used_mb")
        lines.append(f"| {r.get('model')} | {r.get('kv')} | {r.get('c')} | {r.get('ok')} | {gtt or '—'} |")
with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(out)
PY
  log "compare → $CAPACITY_OUT/latest/compare.md"
}

run_scenario() {
  local script="$1"
  # shellcheck source=/dev/null
  source "$script"
}

list_stale_cells() {
  detect_server_fingerprint
  [[ -f "$CELLS_LEDGER" ]] || { log "no ledger yet: $CELLS_LEDGER"; return 0; }
  bench_python - "$CELLS_LEDGER" "$CAPACITY_SERVER_VERSION" "$CAPACITY_IMAGE_ID" <<'PY'
import json, sys
path, cur_ver, cur_img = sys.argv[1:4]
latest = {}
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        key = row.get("key")
        if key:
            latest[key] = row
stale = []
fresh = []
for key, row in sorted(latest.items()):
    old_ver = (row.get("server_version") or "").strip()
    old_img = (row.get("image_id") or "").strip()
    ok = bool(row.get("ok"))
    fp_stale = False
    if cur_ver and cur_ver != "unknown" and (not old_ver or old_ver != cur_ver):
        fp_stale = True
    if cur_img and cur_img != "unknown" and (not old_img or old_img != cur_img):
        fp_stale = True
    if fp_stale and not ok:
        tag = "stale+fail"
    elif fp_stale:
        tag = "stale"
    elif not ok:
        tag = "fail"
    else:
        fresh.append(key)
        continue
    img_s = old_img
    if img_s and len(img_s) > 20:
        img_s = img_s[:19] + "…"
    stale.append((tag, key, old_ver or "—", img_s or "—"))
print(f"current server: {cur_ver}")
print(f"current image:  {cur_img}")
print(f"ledger cells:   {len(latest)}  fresh={len(fresh)}  stale/fail={len(stale)}")
print("")
if stale:
    print("Will re-run on next ./bench capacity kv-ctx / dual:")
    for tag, key, ov, oi in stale:
        print(f"  [{tag}] {key}")
        print(f"         was server={ov}")
else:
    print("No stale cells — fingerprint matches ledger (or fingerprint unknown).")
PY
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 1; }
shift || true

case "$cmd" in
  help|-h|--help)
    usage
    ;;
  sync)
    parse_opts "$@"
    sync_bench_inis "$CAPACITY_SYNC_SOURCES"
    ;;
  list)
    parse_opts "$@"
    if [[ "${CAPACITY_AUTO_SYNC:-1}" == "1" ]]; then
      sync_bench_inis "$CAPACITY_SYNC_SOURCES" >/dev/null || true
    fi
    echo "models in $(basename "$CAPACITY_INI_A"):"
    list_bench_models | sed 's/^/  /'
    ;;
  fingerprint|fp)
    parse_opts "$@"
    detect_server_fingerprint
    echo "server_version=$CAPACITY_SERVER_VERSION"
    echo "image_id=$CAPACITY_IMAGE_ID"
    echo "image_name=$CAPACITY_IMAGE_NAME"
    ;;
  stale)
    parse_opts "$@"
    list_stale_cells
    ;;
  kv-ctx|kv|kv_ctx)
    parse_opts "$@"
    run_scenario "$SCRIPT_DIR/scenarios/kv_ctx.sh"
    ;;
  dual|dual-256k|dual_256k)
    # dual-256k kept as alias for older docs/scripts
    parse_opts "$@"
    run_scenario "$SCRIPT_DIR/scenarios/dual.sh"
    ;;
  compare)
    compare_from_ledger
    ;;
  *)
    die "unknown command: $cmd (try: sync | list | fingerprint | stale | kv-ctx | dual | compare)"
    ;;
esac
