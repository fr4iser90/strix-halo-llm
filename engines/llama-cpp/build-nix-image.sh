#!/usr/bin/env bash
# build-nix-image.sh — baut ein Nix-natives OCI-Image für llama-cpp + Vulkan
# und lädt es in Docker.
#
# Alles kommt aus dem gleichen Nix-Closure (glibc, Mesa, Vulkan-Loader, llama-cpp).
# Kein Ubuntu-Base, kein LD_PRELOAD, kein glibc-ABI-Mismatch.
#
# Usage:
#   ./build-nix-image.sh            # baut + lädt
#   ./build-nix-image.sh --dry-run  # zeigt was gebaut werden würde
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ENGINE_DIR/../.." && pwd)"
LLAMA_SRC="$ROOT/.build/llama.cpp"
IMAGE_NAME="llama-cpp-vulkan-nix"
RESULT_LINK="$ROOT/.build/nix-image-result"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ ! -d "$LLAMA_SRC/.git" && ! -f "$LLAMA_SRC/flake.nix" ]]; then
  echo "error: llama.cpp source missing at $LLAMA_SRC" >&2
  echo "  Run: $ROOT/scripts/fetch-llama.sh" >&2
  exit 1
fi

# ── 1. Nix-Expression inline (kein upstream-Flake-Edit nötig) ─────────────────
NIX_EXPR="
let
  flake = builtins.getFlake \"git+file://${LLAMA_SRC}?shallow=1\";
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;

  # llama-cpp mit Vulkan aus dem Flake-Packages-Output
  llama-vulkan = flake.packages.x86_64-linux.vulkan;

in pkgs.dockerTools.buildLayeredImage {
  name = \"${IMAGE_NAME}\";
  tag = \"latest\";

  contents = pkgs.buildEnv {
    name = \"${IMAGE_NAME}-env\";
    # Alle Libs kommen aus demselben Nix-Closure wie llama-cpp:
    # gleiche glibc, gleiche Mesa, kein ABI-Mismatch.
    paths = [
      llama-vulkan
      pkgs.coreutils
      pkgs.bash
      pkgs.dockerTools.binSh
      pkgs.dockerTools.caCertificates
      pkgs.mesa                # RADV Vulkan-Treiber
      pkgs.vulkan-loader       # libvulkan.so.1
      pkgs.libdrm
    ];
  };

  config = {
    # Entrypoint: llama-server direkt, kein Shell-Wrapper nötig
    Entrypoint = [ \"/bin/llama-server\" ];
    Env = [
      # Mesa RADV ICD — zeigt auf die Nix-interne Mesa-Installation
      \"VK_DRIVER_FILES=/share/vulkan/icd.d/radeon_icd.x86_64.json\"
      \"VK_ICD_FILENAMES=/share/vulkan/icd.d/radeon_icd.x86_64.json\"
      \"LD_LIBRARY_PATH=/lib\"
      \"LIBGL_DRIVERS_PATH=/lib/dri\"
    ];
  };
}
"

echo "=== Nix-Image Build: ${IMAGE_NAME} ==="
echo "Source: ${LLAMA_SRC}"
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] würde bauen:"
  nix eval --impure --expr "$NIX_EXPR" --apply builtins.typeOf 2>&1 || true
  exit 0
fi

echo "→ Baue Nix-Image (kann beim ersten Mal lange dauern)..."
nix build --impure --expr "$NIX_EXPR" \
  --out-link "$RESULT_LINK" \
  --no-write-lock-file \
  2>&1

if [[ ! -e "$RESULT_LINK" ]]; then
  echo "✗ Build fehlgeschlagen — kein result-Link erzeugt." >&2
  exit 1
fi

echo "→ Lade Image in Docker..."
docker load < "$RESULT_LINK"

echo ""
echo "✓ Fertig! Image: ${IMAGE_NAME}:latest"
echo "  Jetzt: cd $ENGINE_DIR && docker compose --env-file $ROOT/.env up -d"
