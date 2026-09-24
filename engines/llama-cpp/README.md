# llama.cpp (Vulkan default) — sticky chat + coder routers.
#
# Daily:
#   docker compose --env-file ../../.env up -d
# RAG (embeddings + extractor):
#   docker compose --env-file ../../.env --profile rag up -d
# Lab pool:
#   docker compose --env-file ../../.env --profile lab up -d
# Capacity bench (isolated :11601/:11602):
#   docker compose --env-file ../../.env --profile bench up -d llama-bench-a
#
# Presets: copy presets/ini/*.ini → . (gitignored live files)
# Image: ./build-nix-image.sh (needs ../../scripts/fetch-llama.sh first)
# ROCm alternate: compose.rocm.yaml — see HARDWARE.md (AMD only; no CUDA)
