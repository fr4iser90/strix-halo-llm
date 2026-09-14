# llama-cpp

Docker setup for [llama.cpp](https://github.com/ggml-org/llama.cpp) in **router mode**: switch multiple GGUF models via API, separate services for chat, embeddings, and knowledge extraction.

## Overview

| Service | Port | Config | Purpose |
|---|---|---|---|
| `llama-router` | `11535` | `models.ini` (chat sticky) | Chat LLMs (`/v1/chat/completions`) |
| `llama-router-coder` | `11538` | `models-coder.ini` (coder sticky) | Coder LLM, always warm |
| `llama-router-lab` | `11537` | `models-lab.ini` | Lab / experiment pool (compose profile `lab`) |
| `llama-embeddings` | `11536` | `models-embeddings.ini` | Embeddings (`/v1/embeddings`) |
| `llama-extractor` | `11539` | `models-extractor.ini` | Schema extractor Agents-K1 (`/v1/chat/completions`) |

They share `./models` but run as **separate containers** — sticky chat stays loaded while embeddings and the extractor run in parallel for RAG / knowledge build.

Hardware / GTT / Sticky vs Lab budgets: see [`setup.md`](setup.md).  
**Other GPUs (NVIDIA CUDA, ROCm, forks):** see [`HARDWARE.md`](HARDWARE.md) — same bench/Pages pipeline, different compose file.

## Model folders

```
models/
├── chat/
│   ├── large/       # large GGUFs — MoE 30–35B, 27B dense, Flash-Next, …
│   ├── medium/      # mid-size (e.g. Qwen3-8B)
│   └── small/       # ≤4B nanos
├── embeddings/
├── extractor/       # Agents-K1 schema extraction GGUF
└── multimodal/      # VLM: base .gguf + mmproj in the same subfolder
```

**Folder = file size tier, not speed tier.** Gateway tags (`fast` / `medium` / `slow`) come from the bench — e.g. Coder-30B lives under `large/` but may tag `fast`; Qwen3-8B under `medium/` may tag `slow`. Do not rename folders: all paths in `models*.ini` point at `chat/large|medium|small`.

The API model name is the INI section name (filename without `.gguf`).

## Quick start

```bash
# 1. Dirs + models (optional)
./model-dl.sh init-dirs
cp examples/ini/models.ini examples/ini/models-coder.ini .   # sticky (gitignored live)
# edit paths to match your GGUFs, then:
./bench sync-models             # lab/emb/extractor from ./models/ (+ *-VL if mmproj)
./model-dl.sh download          # missing models referenced by models.ini

# Optional API-only (no Web UI): cp .env.example .env && set LLAMA_WEBUI=false

# 2. Start (Vulkan / AMD Mesa)
docker compose up -d --build

# 3. Check
curl http://localhost:11535/v1/models
curl http://localhost:11536/v1/models
curl http://localhost:11539/v1/models

# Lab router (no load-on-startup) — own port, same models/ tree:
docker compose --profile lab up -d
curl http://localhost:11537/v1/models
```

## Benchmarks (`./bench`)

Single entrypoint — code under `tools/bench/`, results under `output/bench/`, **GitHub Pages** from `docs/` via `./bench publish`.

| Subcommand | Measures | GPU |
|---|---|---|
| `./bench throughput` | PP/TG (`llama-bench`) | stops **all** routers |
| `./bench sched` | Decode latency under concurrent prefill | stops daily/embeddings/extractor, starts **lab**, restores after |
| `./bench quality` | Task correctness (pluggable; [HumanEval](https://github.com/openai/human-eval), …) | uses running router (default coder `:11538`) |
| `./bench publish` | Copy curated HTML/summaries → `docs/` | none |

```bash
# Throughput
./bench throughput --vulkan
./bench throughput lab Qwen3.6
./bench compare

# Scheduling / rolling prefill (lab :11537, np≥2 in models-lab.ini)
export SCHED_MODEL=Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL SCHED_NP=2 SCHED_UB=32
./bench sched --auto
./bench sched --matrix qwen36_vl.yaml
./bench compare-sched

# Quality — HumanEval (install harness once, then generate ± evaluate)
./bench quality list
./bench quality humaneval --setup          # clones openai/human-eval → .vendor/
pip install -e tools/bench/quality/.vendor/human-eval
./bench quality humaneval \
  --model Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL \
  --limit 10                               # smoke test
# Full + pass@k (executes model code — sandbox recommended; enable unsafe_execute per upstream README):
./bench quality humaneval --model … --n 1 --eval
./bench quality compare

# Pages dashboard
./bench index && ./bench publish
```

Add another quality suite: copy `tools/bench/quality/plugins/_template` → `plugins/<name>` (see [`tools/bench/quality/plugins/README.md`](tools/bench/quality/plugins/README.md)).

Details: [`tools/bench/README.md`](tools/bench/README.md)  
**Index of all runs:** [`output/bench/index.md`](output/bench/index.md) · `./bench index`  
**Interactive planner:** [`output/bench/planner.html`](output/bench/planner.html)  
**Public site:** `docs/` → GitHub Pages (`/docs` on `main`).  
Forks: enable Pages once (Settings → Pages → `main` / `/docs`), then after benches:

```bash
./bench publish && git add docs && git commit -m "docs: refresh" && git push
```

Dashboard includes **Hardware** (`host.json`: RAM, GTT, GPU, llama.cpp pin, image id) so results stay comparable. Related community numbers: [strix-benchmarks](https://slb350.github.io/strix-benchmarks/).

### Image build (Vulkan / Nix)

Canonical path (Strix Halo / gfx1151):

```bash
./scripts/fetch-llama.sh      # pins fork until upstream has needed MTP/model support
./build-nix-image.sh          # llama-cpp-vulkan-nix:latest
docker compose up -d
```

NVIDIA / CUDA hosts: see [`HARDWARE.md`](HARDWARE.md) (`Dockerfile.cuda`, `compose.cuda.yaml`).  
AMD ROCm alternate stack: `compose.rocm.yaml` + `Dockerfile.rocm`.

Pin file: [`docs/llama-pin.md`](docs/llama-pin.md) (rewritten by fetch). When [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) catches up:

```bash
LLAMA_REPO=https://github.com/ggml-org/llama.cpp.git LLAMA_REF=master ./scripts/fetch-llama.sh
./build-nix-image.sh
```

Legacy Ubuntu `Dockerfile` is **deprecated** (Mesa/glibc mismatch on this host). ROCm remains `compose.rocm.yaml` / `Dockerfile.rocm`.

Budgets: [`setup.md`](setup.md).

## Backend: Vulkan vs ROCm vs CUDA

Pick **one** stack at a time (same ports).

| | Vulkan (default / Halo) | ROCm | CUDA (NVIDIA) |
|---|---|---|---|
| Compose | `compose.yaml` | `compose.rocm.yaml` | `compose.cuda.yaml` |
| Image | `llama-cpp-vulkan-nix` | `Dockerfile.rocm` | `Dockerfile.cuda` |
| GPU | `/dev/dri` (RADV) | `/dev/kfd` + `/dev/dri` | NVIDIA runtime |
| Guide | [`setup.md`](setup.md) | below | [`HARDWARE.md`](HARDWARE.md) |

```bash
# Vulkan (default / Strix Halo)
./scripts/fetch-llama.sh && ./build-nix-image.sh
docker compose up -d

# ROCm (alternative AMD)
docker compose down
docker compose -f compose.rocm.yaml up -d --build

# NVIDIA CUDA — see HARDWARE.md
# docker compose down
# docker build -f Dockerfile.cuda -t llama-cpp-cuda:latest .
# docker compose -f compose.cuda.yaml up -d
```

`models.ini` / sticky INIs are the same across backends; only the compose/image changes.

## Download models

`model-dl.sh` fetches GGUFs from Hugging Face into the folder layout above. Weight / GTT sizes: [`setup.md`](setup.md).

```bash
./model-dl.sh list                  # status (present / missing)
./model-dl.sh download              # missing models from models.ini (daily)
./model-dl.sh download Qwen3-Coder  # Coder 30B-A3B
./model-dl.sh download Qwen3-8B
./model-dl.sh download Qwen3-4B
./model-dl.sh download soofi
./model-dl.sh download Qwen3.8      # heavy 27B (not in daily INI)
./model-dl.sh install-cli           # install huggingface-cli only
```

**Daily sticky** (presets in `models.ini`; current `load-on-startup` = Qwen3.6 MTP Q5 VL):

```bash
./model-dl.sh download Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL
./model-dl.sh download Qwen3.6-mmproj
./model-dl.sh download Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL
./model-dl.sh download Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL
./model-dl.sh download Qwen3-8B-UD-Q4_K_XL
./model-dl.sh download Qwen3-4B-Instruct-2507-UD-Q4_K_XL
# Soofi GGUF is gated (closed beta): request HF access first, then:
export HF_TOKEN=hf_...
./model-dl.sh download soofi-s-instruct-preview-Q5_K_M
```

Dense Qwen3.8 27B and other lab models live in **`models-lab.ini`** on the lab router (`:11537`):

```bash
docker compose --profile lab up -d
# Gateway: second chat source → Jarvis:11537
```

**Qwen3.8-27B Unsloth UD** ([unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF)):

```bash
./model-dl.sh download Qwen3.8-27B-UD-Q4_K_XL
./model-dl.sh download Qwen3.8-27B-UD-Q5_K_XL
./model-dl.sh download Qwen3.8-27B-UD-Q6_K_XL
./model-dl.sh download Qwen3.8-27B-UD-Q8_K_XL
./model-dl.sh download Qwen3.8-mmproj
./model-dl.sh download Qwen3.6-mmproj   # for Qwen3.6 *-VL
# or filter (all Qwen3.8 incl. 6/8-bit + ggml MTP):
./model-dl.sh download Qwen3.8
```

**Qwen3.8-27B + MTP** ([ggml-org/Qwen3.8-27B-GGUF](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)) — target + separate `mtp-*.gguf`, `spec-draft-n-max = 3` (see also [Strix Benchmarks](https://slb350.github.io/strix-benchmarks/)):

```bash
./model-dl.sh download Qwen3.8-27B-Q8_0
./model-dl.sh download mtp-Qwen3.8-27B-Q8_0
./model-dl.sh download Qwen3.8-27B-Q4_K_M
./model-dl.sh download mtp-Qwen3.8-27B-Q4_0
./model-dl.sh download mmproj-Qwen3.8-27B-Q8_0
# or batch:
./model-dl.sh download Qwen3.8-27B-Q
./model-dl.sh download mtp-Qwen3.8
```

Lab INI presets: `Qwen3.8-27B-Q8_0-MTP`, `Qwen3.8-27B-Q4_K_M-MTP`, plus `-VL` with `mmproj-Qwen3.8-27B-Q8_0.gguf`.

**mmproj names** (not a generic shared `mmproj-F16.gguf`):

| Local | Source |
|-------|--------|
| `Qwen3.8-mmproj-F16.gguf` | unsloth/Qwen3.8-27B-GGUF → `mmproj-F16.gguf` |
| `mmproj-Qwen3.8-27B-Q8_0.gguf` | ggml-org/Qwen3.8-27B-GGUF (MTP VL presets) |
| `Qwen3.6-mmproj-F16.gguf` | unsloth/Qwen3.6-35B-A3B-GGUF → `mmproj-F16.gguf` |
| `Qwen3.8-Flash-Next-mmproj-F16.gguf` | unsloth/Qwen3.8-Flash-Next-GGUF → `mmproj-F16.gguf` |
| `medgemma-…-mmproj-f16.gguf` | own multimodal directory |

If you still have `models/chat/large/mmproj-F16.gguf` (old generic name):

```bash
./model-dl.sh download Qwen3.6-mmproj
./model-dl.sh download Qwen3.8-mmproj
# then remove/rename the old generic file
```

Then: `docker compose up -d` (INI remount / reload). Run downloads on Jarvis, not on the gateway PC.

Sources live in `models.catalog.tsv` (tab-separated: local filename, subdir, HF repo, optional remote filename).

```bash
# Optional: faster downloads
pip install hf_transfer
export HF_HUB_ENABLE_HF_TRANSFER=1

# Gated models
export HF_TOKEN=hf_...

# NixOS: if hf is missing, the script uses
#   nix shell nixpkgs#python3Packages.huggingface-hub -c hf …
# Or enter a shell first:
#   nix shell nixpkgs#python3Packages.huggingface-hub
#   ./model-dl.sh download Qwen3.8
```

## API usage

### List models

```bash
curl http://localhost:11535/v1/models
curl http://localhost:11536/v1/models
curl http://localhost:11539/v1/models
```

### Chat

```bash
curl http://localhost:11535/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### Embeddings

```bash
curl http://localhost:11536/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "bge-m3-Q4_K_M", "input": "Hello world"}'
```

### Extractor (Agents-K1)

```bash
curl http://localhost:11539/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "agents-k1",
    "messages": [{"role": "user", "content": "Entity types to extract: [Person, Organization]\n\nText:\nAlice joined Acme Corp."}]
  }'
```

### Switch / unload model

With `--models-max 1` on the LLM router, the current model is unloaded automatically when another is requested.

```bash
curl -X POST http://localhost:11535/models/unload \
  -H "Content-Type: application/json" \
  -d '{"model": "Nemotron-3-Nano-30B-A3B-Q4_K_M"}'
```

## Add a new model

1. Place the GGUF in the matching folder (e.g. `models/chat/small/`)
2. Run `./bench sync-models` — adds lab (+ `*-VL` if a matching mmproj exists). Sticky: edit `models.ini` / `models-coder.ini` yourself (templates in `examples/ini/`).
3. Optional: catalog row in `models.catalog.tsv` for HF download
4. `docker compose up -d` (INI remounted)

Example sticky `models.ini` (also under `examples/ini/`):

```ini
[My-Model-Q4_K_M]
model = /models/chat/small/My-Model-Q4_K_M.gguf
np = 4
c = 16384
b = 512
load-on-startup = true
```

**Context:** One model name per GGUF. Large daily/lab presets often use high `c` (see live INI / [`setup.md`](setup.md)). Clients should read **`context_length`** from `GET /v1/models` (gateway).

| Role | Typical `c` | Typical `np` | Example |
|-------|-----|------|----------|
| Agent / chat / coding | high (64k–256k) | 1–4 | sticky Qwen3.6 Q5 VL |
| Small multi-user | `16384` | `4` | Nemotron-4B (short chat) |

Gateway aliases (if configured): **`auto`** / **`auto-quality`** / **`auto-long`** map to daily MTP presets.

For MTP models add `spec-type = draft-mtp` and `spec-draft-n-max = 2` (or `3` for Qwen3.8 ggml-org / Flash-Next).  
Separate drafter (ggml-org Qwen3.8 / Flash-Next): `model-draft = /models/chat/large/mtp-….gguf`.

Embeddings go in `models-embeddings.ini` — that service starts with `--embeddings`.  
Extractor (Agents-K1) goes in `models-extractor.ini` — chat completions for schema/JSON extraction (`:11539`).

## Configuration

GPU / embedding flags live **per model** in the INI files.

**Important:** No key-value lines before the first `[section]` (e.g. no top-level `version = 1`) — llama.cpp assigns those to section `default` and lists them in `/v1/models`.

- LLM: `ngl`, `fa`, `ctk`, `ctv` in each section of `models.ini` / `models-lab.ini` / `models-extractor.ini`
- Embeddings: `embeddings = true`, `ngl` in each section of `models-embeddings.ini`
- `--models-max 1` on LLM routers: one large model loaded at a time **per router**

Startup model: `load-on-startup = true` in the desired sticky INI section  
(currently `Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL`).

## Files

| File / folder | Description |
|---|---|
| `./bench` | **Only** bench CLI (throughput + sched + quality + publish) |
| `tools/bench/` | Bench implementation |
| `tools/bench/quality/plugins/` | Pluggable quality suites (HumanEval, …) |
| `output/bench/` | Local results (`throughput/`, `scheduling/`, `quality/`) |
| `docs/` | GitHub Pages publish set (`./bench publish`) |
| `scripts/fetch-llama.sh` | Pin / fetch llama.cpp fork or upstream |
| `setup.md` | Hardware, GTT, Sticky vs Lab budgets |
| `compose.yaml` | Vulkan stack (router + embeddings + extractor) |
| `compose.rocm.yaml` | ROCm stack |
| `build-nix-image.sh` | Canonical Vulkan image build |
| `Dockerfile*` | Legacy / ROCm — see comments in file |
| `examples/ini/` | Committed sticky templates (copy → root) |
| `models.ini` | Daily sticky chat — **local / gitignored** |
| `models-lab.ini` | Lab — **local**; `./bench sync-models` from disk |
| `models-coder.ini` | Sticky coder — **local / gitignored** |
| `models-embeddings.ini` | Embeddings — **local**; sync-models |
| `models-extractor.ini` | Extractor — **local**; sync-models |
| `models-bench.ini` (+ `-b`) | Capacity — **local**; `./bench capacity sync` |
| `models.catalog.tsv` | HF download sources |
| `model-dl.sh` | Download script |
| `vulkan-host-env.sh` | Legacy Mesa preload (unused by Nix image) |

## Notes

- **Multimodal:** Keep base `.gguf` and `mmproj-*.gguf` together; wire `mmproj = …` in the preset.
- **Shared access:** Daily chat `11535`, embeddings `11536`, lab `11537`, coder `11538`, extractor `11539`. Model names must match the INI section exactly.
- **Logs:** `docker compose logs -f llama` / `docker compose --profile lab logs -f llama-lab`
