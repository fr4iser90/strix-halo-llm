# Host RAM / GTT helpers (dual auto-skip, planner-style thresholds).
# Expects: bench_python available (source tools/bench/lib/python.sh first).
# Optional: BENCH_ROOT or PROJECT_ROOT for host.json fallback.

host_ram_gtt_gib() {
  local root="${BENCH_ROOT:-${PROJECT_ROOT:-${ROOT:-}}}"
  local hj="${HOST_JSON:-}"
  if [[ -z "$hj" && -n "$root" ]]; then
    hj="$root/output/bench/host.json"
  fi
  bench_python - "${hj:-}" <<'PY'
import glob, json, os, sys

hj_path = sys.argv[1] if len(sys.argv) > 1 else ""
ram = gtt = None
try:
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                ram = int(line.split()[1]) / (1024.0 * 1024.0)  # KiB → GiB
                break
except OSError:
    pass
for path in sorted(glob.glob("/sys/class/drm/card*/device")):
    p = os.path.join(path, "mem_info_gtt_total")
    if not os.path.isfile(p):
        continue
    try:
        with open(p, encoding="utf-8") as f:
            gtt = int(f.read().strip()) / (1024.0 ** 3)
    except (OSError, ValueError):
        pass
    break
if (ram is None or gtt is None) and hj_path and os.path.isfile(hj_path):
    try:
        with open(hj_path, encoding="utf-8") as f:
            h = json.load(f)
        if ram is None:
            ram = h.get("ram_gib")
            if ram is None and h.get("ram_mib") is not None:
                ram = float(h["ram_mib"]) / 1024.0
        if gtt is None:
            gtt = h.get("gtt_total_gib") or h.get("gtt_gib")
            if gtt is None and h.get("gtt_total_mib") is not None:
                gtt = float(h["gtt_total_mib"]) / 1024.0
    except (OSError, ValueError, json.JSONDecodeError, TypeError):
        pass
print(
    f"{'' if ram is None else round(float(ram), 2)} "
    f"{'' if gtt is None else round(float(gtt), 2)}"
)
PY
}

# Exit 0 if dual should be skipped for this host class; 1 if dual may run.
# Thresholds (GiB): CAPACITY_DUAL_SKIP_BELOW_RAM_GIB / _GTT_GIB (0 = ignore that axis).
# CAPACITY_FORCE_DUAL=1 always allows. Unknown metrics → allow (do not block).
# On skip, prints a short reason on stdout.
dual_host_too_small() {
  [[ "${CAPACITY_FORCE_DUAL:-0}" == "1" ]] && return 1
  local min_ram="${CAPACITY_DUAL_SKIP_BELOW_RAM_GIB:-64}"
  local min_gtt="${CAPACITY_DUAL_SKIP_BELOW_GTT_GIB:-48}"
  local ram gtt why
  read -r ram gtt < <(host_ram_gtt_gib)
  why="$(bench_python - "${ram:-}" "${gtt:-}" "$min_ram" "$min_gtt" <<'PY'
import sys
ram_s, gtt_s, min_ram_s, min_gtt_s = sys.argv[1:5]

def f(x):
    try:
        return float(x) if x not in ("", None) else None
    except ValueError:
        return None

ram, gtt = f(ram_s), f(gtt_s)
min_ram, min_gtt = f(min_ram_s) or 0.0, f(min_gtt_s) or 0.0
if min_ram <= 0 and min_gtt <= 0:
    raise SystemExit(0)
if ram is not None and min_ram > 0 and ram < min_ram:
    print(f"RAM {ram:.1f}GiB < {min_ram:g}GiB")
elif gtt is not None and min_gtt > 0 and gtt < min_gtt:
    print(f"GTT {gtt:.1f}GiB < {min_gtt:g}GiB")
PY
)"
  if [[ -n "${why:-}" ]]; then
    printf '%s\n' "$why"
    return 0
  fi
  return 1
}
