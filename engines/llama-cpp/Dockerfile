# DEPRECATED — replaced by Nix-native OCI image.
#
# This Ubuntu-based Dockerfile is NOT used by compose.yaml.
# Problem: Ubuntu 24.04 Mesa does not know AMD gfx1151 (8060S).
# Mounting Nix Mesa collides with glibc ABI differences.
#
# Use instead:
#   ./scripts/fetch-llama.sh
#   ./build-nix-image.sh          # → llama-cpp-vulkan-nix:latest
#   docker compose up -d
#
# Kept in-tree only as historical reference / emergency fallback.

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git cmake ninja-build build-essential \
    libvulkan-dev mesa-vulkan-drivers vulkan-tools \
    glslc spirv-headers spirv-tools \
    curl ca-certificates

WORKDIR /workspace
# Host-cloned tree (Docker build often cannot git-clone GitHub on this host).
# Prepare with: ./scripts/fetch-llama.sh
COPY .build/llama.cpp /workspace/llama.cpp
WORKDIR /workspace/llama.cpp
RUN cmake -S . -B build -G Ninja \
      -DGGML_VULKAN=ON \
      -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build -j$(nproc) --target llama-server llama-bench

CMD ["/workspace/llama.cpp/build/bin/llama-server"]
