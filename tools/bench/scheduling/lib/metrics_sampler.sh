#!/usr/bin/env bash
# Sample GTT / VRAM / system memory / GPU util / sidecar power+temp while a scenario runs.
#
# Sidecar (Docker on host): off unless GPU_POWER_URL / GPU_THERMAL_URL are set.
#   cd sidecar && docker compose up -d --build
#   GPU_POWER_URL=http://127.0.0.1:9105/power GPU_THERMAL_URL=http://127.0.0.1:9105/thermal ./bench …
# Unreachable URL → empty watts/temp (no hard fail).
set -euo pipefail

out="${METRICS_OUT:?}"
interval_ms="${METRICS_INTERVAL_MS:-250}"
interval_s="$(awk -v ms="$interval_ms" 'BEGIN { printf "%.3f", ms / 1000.0 }')"

POWER_URL="${GPU_POWER_URL:-}"
THERMAL_URL="${GPU_THERMAL_URL:-}"
case "${POWER_URL}" in ""|off|OFF|0|false|FALSE) POWER_URL="" ;; esac
case "${THERMAL_URL}" in ""|off|OFF|0|false|FALSE) THERMAL_URL="" ;; esac

find_drm_device() {
  local d
  for d in /sys/class/drm/card*/device; do
    [[ -r "$d/mem_info_gtt_total" || -r "$d/mem_info_vram_used" ]] || continue
    printf '%s\n' "$d"
    return 0
  done
  return 1
}

DRM_DEV="$(find_drm_device || true)"

# Parse one JSON number/string field from sidecar curl body (stdin). Empty on miss.
json_field() {
  local key="$1"
  python3 -c '
import json, sys
key = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
v = d.get(key)
if v is None:
    raise SystemExit(0)
print(v, end="")
' "$key" 2>/dev/null || true
}

fetch_sidecar() {
  local url="$1"
  [[ -n "$url" ]] || return 0
  curl -sfS --connect-timeout 0.3 --max-time 0.8 "$url" 2>/dev/null || true
}

sample_once() {
  local ts vram_mb gtt_mb gtt_total_mb mem_avail_mb gpu src
  local power_w power_src temp_c body
  ts="$(date +%s%3N 2>/dev/null || date +%s000)"
  vram_mb=""
  gtt_mb=""
  gtt_total_mb=""
  mem_avail_mb=""
  gpu=""
  src="none"
  power_w=""
  power_src=""
  temp_c=""

  if [[ -n "$DRM_DEV" ]]; then
    src="sysfs"
    if [[ -r "$DRM_DEV/mem_info_vram_used" ]]; then
      vram_mb="$(awk '{print int($1/1048576)}' "$DRM_DEV/mem_info_vram_used" 2>/dev/null || true)"
    fi
    if [[ -r "$DRM_DEV/mem_info_gtt_used" ]]; then
      gtt_mb="$(awk '{print int($1/1048576)}' "$DRM_DEV/mem_info_gtt_used" 2>/dev/null || true)"
    fi
    if [[ -r "$DRM_DEV/mem_info_gtt_total" ]]; then
      gtt_total_mb="$(awk '{print int($1/1048576)}' "$DRM_DEV/mem_info_gtt_total" 2>/dev/null || true)"
    fi
  fi

  if [[ -r /proc/meminfo ]]; then
    mem_avail_mb="$(awk '/MemAvailable:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || true)"
  fi

  if command -v rocm-smi >/dev/null 2>&1; then
    [[ "$src" == "none" ]] && src="rocm-smi"
    gpu="$(rocm-smi --showuse 2>/dev/null | awk '/GPU use/ {gsub(/[^0-9.]/,"",$NF); print $NF; exit}')"
    if [[ -z "$vram_mb" ]]; then
      vram_mb="$(rocm-smi --showmeminfo vram 2>/dev/null | awk -F: '/VRAM Total Used Memory/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
    fi
  fi

  if [[ -n "$POWER_URL" ]]; then
    body="$(fetch_sidecar "$POWER_URL")"
    if [[ -n "$body" ]]; then
      # one parse → watts + source
      read -r power_w power_src < <(printf '%s' "$body" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(" "); raise SystemExit(0)
w=d.get("watts"); s=d.get("source") or ""
print(("" if w is None else w), s)
' 2>/dev/null || echo " ")
    fi
  fi
  if [[ -n "$THERMAL_URL" ]]; then
    body="$(fetch_sidecar "$THERMAL_URL")"
    if [[ -n "$body" ]]; then
      temp_c="$(printf '%s' "$body" | json_field temperature_c)"
    fi
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "${vram_mb:-}" "${gtt_mb:-}" "${gtt_total_mb:-}" "${mem_avail_mb:-}" \
    "${gpu:-}" "$src" "${power_w:-}" "${power_src:-}" "${temp_c:-}" >>"$out"
}

while true; do
  sample_once || true
  sleep "$interval_s"
done
