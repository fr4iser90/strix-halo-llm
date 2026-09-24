# Hardware & backends

**This repo targets AMD Strix Halo (UMA).** Default stack: Vulkan / RADV via `engines/llama-cpp/compose.yaml`.
Optional AMD alternate: ROCm (`compose.rocm.yaml`). There is **no NVIDIA/CUDA stack** here — Halo has no NVIDIA GPU.

Other AMD machines / forks: same tooling, publish your own `docs/` after local benches.

## Which file to use

| Host | Compose | Image | Notes |
|------|---------|-------|--------|
| **AMD Strix Halo / UMA** (default) | `engines/llama-cpp/compose.yaml` (`--profile bench` for :11601/:11602) | `llama-cpp-vulkan-nix` via `engines/llama-cpp/build-nix-image.sh` | GTT/UMA; see [`setup.md`](setup.md) |
| **AMD + ROCm** | `engines/llama-cpp/compose.rocm.yaml` | `llama-cpp-rocm` (`Dockerfile.rocm`) | gfx override in compose; Halo-oriented zip build |
| **CPU-only / smoke** | same stacks, tiny models | same | Skip 256k capacity; use `./bench throughput --cpu` where supported |

Other engines: [`engines/halogen-flash/`](engines/halogen-flash/), [`engines/gufo/`](engines/gufo/) — see [`engines/README.md`](engines/README.md).

Do **not** start Vulkan and ROCm compose projects on the same ports at once.

## Same everywhere (INI + bench + Pages)

| Piece | Role |
|-------|------|
| `engines/llama-cpp/models*.ini` | Sticky / coder / lab / bench presets (templates: `engines/llama-cpp/presets/ini/`) |
| `MODELS_DIR` | Host GGUF root (default `./models`, Jarvis often `~/data/models/gguf`) |
| `./bench …` | throughput · sched · capacity · quality · index |
| `output/bench/` | local results (gitignored) |
| `./bench publish` → `docs/` | GitHub Pages for **this** host |

Comparability: `host.json` (GPU, RAM, backend, llama.cpp pin). Numbers from a Halo box are not “your” results on a different machine.

## AMD ROCm quick start

```bash
cd engines/llama-cpp
docker compose --env-file ../../.env -f compose.rocm.yaml up -d --build
docker compose --env-file ../../.env -f compose.rocm.yaml --profile lab up -d
```

Adjust `HSA_OVERRIDE_GFX_VERSION` / zip `ARCH` in `Dockerfile.rocm` for non-gfx1151 cards.

## Capacity / context expectations

| Machine class | Sensible max context to try first |
|---------------|-----------------------------------|
| Strix Halo ~96–128 GiB UMA | up to 128k–256k (see setup.md) |
| Discrete AMD 24 GiB VRAM | often 16k–64k for 30B-class Q4/Q5 |
| 8–12 GiB VRAM | small models / heavy quant / lower `c` |

Capacity “GTT” wording on the dashboard is UMA-oriented; on discrete VRAM treat memory columns as **device memory pressure**, and prefer shorter context grids.

## Forks & Pages

1. Enable Pages once: **Settings → Pages → Deploy from a branch → `main` / `/docs`**
2. Run benches on **your** hardware
3. `./bench index && ./bench publish` → commit `docs/` → push

You keep the tooling; you replace the published numbers.

## Related

- Halo budgets & sticky vs lab: [`setup.md`](setup.md)
- Engines layout: [`engines/README.md`](engines/README.md)
- Bench CLI: [`tools/bench/README.md`](tools/bench/README.md)
- Throughput backends (Vulkan / ROCm / CPU): `./bench throughput --help`
