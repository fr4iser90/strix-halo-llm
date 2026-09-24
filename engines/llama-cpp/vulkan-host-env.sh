#!/bin/sh
# vulkan-host-env.sh — LEGACY-Wrapper für das alte Ubuntu-basierte Image.
# Wird vom Nix-nativen Image (llama-cpp-vulkan-nix) NICHT mehr verwendet.
# Das Nix-Image setzt VK_DRIVER_FILES und LD_LIBRARY_PATH direkt via Nix-ENV.
#
# Hintergrund: Ubuntu 24.04 Mesa kennt gfx1151 (AMD 8060S) nicht.
# Workaround war: NixOS Mesa via /run/opengl-driver einbinden + Wayland preloaden.
# Problem: Nix-Wayland und Nix-glibc-2.42-67 nutzen GLIBC_ABI_DT_X86_64_PLT,
# ein Symbol das Ubuntu 24.04 libc nicht exportiert → Crash.
# Lösung: Nix-natives OCI-Image via ./build-nix-image.sh
set -eu
exec "$@"
