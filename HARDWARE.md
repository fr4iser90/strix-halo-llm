# Hardware & backends

One repo, **one bench/Pages pipeline** — pick the compose stack that matches the GPU.
Jarvis / Strix Halo is the default happy path (`compose.yaml` + Vulkan Nix image).
Other machines fork, measure locally, and publish their own `docs/`.

## Which file to use

| Host | Compose | Image | Notes |
|------|---------|-------|--------|
| **AMD Strix Halo / UMA** (default) | `compose.yaml` (+ `compose.bench.yaml`) | `llama-cpp-vulkan-nix` via `./build-nix-image.sh` | GTT/UMA; see [`setup.md`](setup.md) |
| **AMD + ROCm** | `compose.rocm.yaml` | `llama-cpp-rocm` (`Dockerfile.rocm`) | gfx override in compose; Halo-oriented zip build |
| **NVIDIA** | `compose.cuda.yaml` (+ `compose.cuda.bench.yaml`) | `llama-cpp-cuda` (`Dockerfile.cuda`) | Needs [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) |
| **CPU-only / smoke** | any stack with tiny models | same | Skip 256k capacity; use `./bench throughput --cpu` where supported |

Do **not** start Vulkan and CUDA compose projects on the same ports at once.

## Same everywhere (INI + bench + Pages)

| Piece | Role |
|-------|------|
| `models*.ini` | Sticky / coder / lab / bench presets |
| `./bench …` | throughput · sched · capacity · quality · index |
| `output/bench/` | local results (gitignored) |
| `./bench publish` → `docs/` | GitHub Pages for **this** host |

Comparability: `host.json` (GPU, RAM, backend, llama.cpp pin). Numbers from a Halo box are not “your” results on a 16 GB laptop.

## NVIDIA quick start

```bash
# Driver + nvidia-container-toolkit already working:
nvidia-smi

./scripts/fetch-llama.sh
docker build -f Dockerfile.cuda -t llama-cpp-cuda:latest .

cp examples/ini/models.ini examples/ini/models-coder.ini .   # if missing
# edit paths, then:
./bench sync-models

docker compose -f compose.cuda.yaml up -d
docker compose -f compose.cuda.yaml --profile lab up -d

curl http://127.0.0.1:11535/v1/models

# Capacity / quality on bench-a (optional):
docker compose -f compose.cuda.yaml -f compose.cuda.bench.yaml --profile bench up -d llama-bench-a
CAPACITY_BACKEND=cuda VK_COMPOSE=compose.cuda.yaml BENCH_COMPOSE=compose.cuda.bench.yaml \
  CAPACITY_IMAGE_NAME=llama-cpp-cuda \
  ./bench capacity kv-ctx --model …   # start with modest -c; no UMA 256k assumption

./bench throughput --vulkan   # or whatever backends your throughput script supports on this host
./bench index && ./bench publish
```

Override image tag: `LLAMA_CUDA_IMAGE=my-cuda:tag docker compose -f compose.cuda.yaml up -d`.

## AMD ROCm quick start

```bash
docker compose -f compose.rocm.yaml up -d --build
docker compose -f compose.rocm.yaml --profile lab up -d
```

Adjust `HSA_OVERRIDE_GFX_VERSION` / zip `ARCH` in `Dockerfile.rocm` for non-gfx1151 cards.

## Capacity / context expectations

| Machine class | Sensible max context to try first |
|---------------|-----------------------------------|
| Strix Halo ~96–128 GiB UMA | up to 128k–256k (see setup.md) |
| Discrete 24 GiB VRAM | often 16k–64k for 30B-class Q4/Q5 |
| 8–12 GiB VRAM | small models / heavy quant / lower `c` |

Capacity “GTT” wording on the dashboard is UMA-oriented; on discrete NVIDIA, treat memory columns as **device memory pressure**, and prefer shorter context grids.

## Forks & Pages

1. Enable Pages once: **Settings → Pages → Deploy from a branch → `main` / `/docs`**
2. Run benches on **your** hardware
3. `./bench index && ./bench publish` → commit `docs/` → push

You keep the tooling; you replace the published numbers.

## Related

- Halo budgets & sticky vs lab: [`setup.md`](setup.md)
- Bench CLI: [`tools/bench/README.md`](tools/bench/README.md)
- Throughput backends (Vulkan / ROCm / CPU): `./bench throughput --help`
