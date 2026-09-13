#!/usr/bin/env bash
# Probe host hardware into output/bench/host.json (for dashboard / GitHub Pages).
#
#   ./tools/bench/probe-host.sh
#   ./bench publish   # runs this automatically
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${HOST_JSON:-$ROOT/output/bench/host.json}"
# shellcheck source=lib/python.sh
source "$ROOT/tools/bench/lib/python.sh"

mkdir -p "$(dirname "$OUT")"

PIN_FILE="$ROOT/.build/llama.pin"
PIN_MD="$ROOT/docs/llama-pin.md"
IMAGE="${LLAMA_IMAGE:-llama-cpp-vulkan-nix:latest}"

bench_python - "$OUT" "$ROOT" "$PIN_FILE" "$PIN_MD" "$IMAGE" <<'PY'
import json, os, platform, re, subprocess, sys
from datetime import datetime, timezone

out_path, root, pin_file, pin_md, image = sys.argv[1:6]

def sh(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return (r.stdout or "").strip()
    except Exception:
        return ""

def meminfo():
    total = avail = swap = None
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1]) // 1024  # MiB
                elif line.startswith("MemAvailable:"):
                    avail = int(line.split()[1]) // 1024
                elif line.startswith("SwapTotal:"):
                    swap = int(line.split()[1]) // 1024
    except OSError:
        pass
    return total, avail, swap

def drm_mem():
    import glob
    gtt_t = gtt_u = vram_t = vram_u = None
    for path in sorted(glob.glob("/sys/class/drm/card*/device")):
        def mb(name):
            p = os.path.join(path, name)
            if not os.path.isfile(p):
                return None
            try:
                with open(p, encoding="utf-8") as f:
                    return int(int(f.read().strip()) / 1048576)
            except Exception:
                return None
        if mb("mem_info_gtt_total") is None and mb("mem_info_vram_total") is None:
            continue
        gtt_t, gtt_u = mb("mem_info_gtt_total"), mb("mem_info_gtt_used")
        vram_t, vram_u = mb("mem_info_vram_total"), mb("mem_info_vram_used")
        break
    return gtt_t, gtt_u, vram_t, vram_u

def read_pin(path):
    if not os.path.isfile(path):
        return {}
    d = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d

def cpu_model():
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "—"

mem_t, mem_a, swap_t = meminfo()
gtt_t, gtt_u, vram_t, vram_u = drm_mem()

gpu = sh("lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | grep -viE 'SATA|USB|Audio|SMBus' | head -1")
if not gpu:
    gpu = sh("lspci -nn 2>/dev/null | grep -iE 'AMD.*(Navi|Radeon|Strix|gfx)|NVIDIA|Intel.*(Arc|Graphics)' | head -1")
if not gpu:
    for cand in (
        "/sys/class/drm/card0/device/product_name",
        "/sys/class/drm/card1/device/product_name",
    ):
        if os.path.isfile(cand):
            try:
                with open(cand, encoding="utf-8") as f:
                    gpu = f.read().strip()
                    if gpu:
                        break
            except OSError:
                pass
# Fallback: amdgpu marketing name from dmesg/journal is heavy — keep PCI id if present
if not gpu:
    gpu = sh("ls -1 /sys/class/drm/ 2>/dev/null | tr '\\n' ' '")

image_id = sh(f"docker image inspect -f '{{{{.Id}}}}' {image} 2>/dev/null")
if image_id.startswith("sha256:"):
    image_id_short = image_id[7:19]
else:
    image_id_short = image_id[:12] if image_id else None

pin = read_pin(pin_file)
if not pin and os.path.isfile(pin_md):
    # best-effort from docs/llama-pin.md table
    text = open(pin_md, encoding="utf-8").read()
    m = re.search(r"Commit \| `([0-9a-f]+)`", text)
    if m:
        pin["commit"] = m.group(1)
    m = re.search(r"Repo \| `([^`]+)`", text)
    if m:
        pin["repo"] = m.group(1)
    m = re.search(r"Ref \| `([^`]+)`", text)
    if m:
        pin["ref"] = m.group(1)

nproc = os.cpu_count()
kernel = platform.release()
os_pretty = ""
try:
    with open("/etc/os-release", encoding="utf-8") as f:
        for line in f:
            if line.startswith("PRETTY_NAME="):
                os_pretty = line.split("=", 1)[1].strip().strip('"')
except OSError:
    pass

backend = os.environ.get("BENCH_BACKEND") or os.environ.get("CAPACITY_BACKEND") or "vulkan"

def gib(mib):
    if mib is None:
        return None
    return round(mib / 1024.0, 1)

host = {
    "collected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "hostname": platform.node(),
    "os": os_pretty or platform.platform(),
    "kernel": kernel,
    "cpu": cpu_model(),
    "nproc": nproc,
    "ram_mib": mem_t,
    "ram_gib": gib(mem_t),
    "ram_available_mib": mem_a,
    "swap_mib": swap_t,
    "swap_gib": gib(swap_t),
    "gtt_total_mib": gtt_t,
    "gtt_total_gib": gib(gtt_t),
    "gtt_used_mib": gtt_u,
    "vram_total_mib": vram_t,
    "vram_used_mib": vram_u,
    "gpu": gpu or None,
    "backend_default": backend,
    "docker_image": image,
    "docker_image_id": image_id or None,
    "docker_image_id_short": image_id_short,
    "llama_pin": {
        "repo": pin.get("repo"),
        "ref": pin.get("ref"),
        "commit": pin.get("commit"),
        "fetched_at": pin.get("fetched_at"),
    },
    "notes": (
        "AMD Strix Halo / unified memory: GTT is the GPU-usable UMA pool "
        "(not discrete VRAM). Compare benches only across similar GTT/RAM."
    ),
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(host, f, indent=2)
    f.write("\n")

print(f"Wrote {out_path}")
print(
    f"  host={host['hostname']} ram={host['ram_gib']}GiB "
    f"gtt={host['gtt_total_gib']}GiB gpu={host.get('gpu') or '—'}"
)
PY
