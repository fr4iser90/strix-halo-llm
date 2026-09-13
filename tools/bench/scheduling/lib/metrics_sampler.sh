#!/usr/bin/env bash
# Sample GTT / VRAM / system memory / GPU util while a scenario runs.
set -euo pipefail

out="${METRICS_OUT:?}"
interval_ms="${METRICS_INTERVAL_MS:-250}"
interval_s="$(awk -v ms="$interval_ms" 'BEGIN { printf "%.3f", ms / 1000.0 }')"

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

sample_once() {
  local ts vram_mb gtt_mb gtt_total_mb mem_avail_mb gpu src
  ts="$(date +%s%3N 2>/dev/null || date +%s000)"
  vram_mb=""
  gtt_mb=""
  gtt_total_mb=""
  mem_avail_mb=""
  gpu=""
  src="none"

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

  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "${vram_mb:-}" "${gtt_mb:-}" "${gtt_total_mb:-}" "${mem_avail_mb:-}" "${gpu:-}" "$src" >>"$out"
}

while true; do
  sample_once || true
  sleep "$interval_s"
done
