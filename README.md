# strix-halo-llm

**Multi-engine hub for Strix Halo:** download weights → start any engine mix → smoke-check → benchmark → publish Pages.

| Piece | Role |
|-------|------|
| [`engines/`](engines/README.md) | llama.cpp · Halogen · Gufo · Piper · Whisper |
| [`./stack`](stack) | Start/stop/status **any** engine combo (`STACK_ENGINES`) |
| [`model-dl.sh`](model-dl.sh) | Fetch into `MODELS_ROOT/{gguf,hgn,stt,tts}` |
| [`./bench`](bench) | Smoke · matrix (`--engine`) · llama suites · Pages |
| [`docs/`](docs/) | GitHub Pages snapshot |

AMD Strix Halo hub ([`HARDWARE.md`](HARDWARE.md)): Vulkan default, optional ROCm — **no NVIDIA**.

## Engines & ports

| Engine | Port | Start |
|--------|------|--------|
| llama sticky / coder | 11535 / 11538 | `./stack up llama` |
| llama lab / rag | 11537 / 11536+11539 | `LLAMA_PROFILES=lab,rag ./stack up llama` |
| llama bench-a/b | 11601 / 11602 | `compose.yaml` profile `bench` |
| Gufo | 8080 | `./stack up gufo` (**daily default**: Flash-Next Q4 @ 262k) |
| Halogen Flash | 8731 | `./stack up halogen` (optional Lab) |
| Whisper STT | 9000 | `./stack up whisper` |
| Piper TTS | 9001 | `./stack up piper` |

Default `STACK_ENGINES=gufo,llama,piper,whisper` (`LLAMA_SERVICES=llama-embeddings` only — no sticky/coder).
**`dual_llm` / `coexist_capacity`:** only two **llama** LLM routers under KV/GTT load — **not** piper+whisper+halogen. Multi-engine health = `./bench smoke`.

## Weights layout

```
$MODELS_ROOT/              # default ./models · Jarvis ~/data/models
├── gguf/                  # MODELS_DIR — llama / gufo → /models
│   ├── chat/{large,medium,small}/
│   ├── embeddings/
│   ├── extractor/
│   └── multimodal/
├── hgn/<pack>/            # HALOGEN_MODELS (*.hgn + tokenizer/)
├── stt/                   # whisper
└── tts/                   # piper
```

## Quick start (clone → usable)

```bash
git clone <this-repo> && cd strix-halo-llm
./stack                  # menu → Setup wizard (.env, models download/skip, up, smoke)
# or non-interactive:
# cp .env.example .env && ./stack setup
```

Weights: `./model-dl.sh list|download`. Defaults: edit `.env` or `./stack` → Change preset.

More: [`engines/README.md`](engines/README.md) · [`tools/bench/README.md`](tools/bench/README.md) · GTT budgets [`setup.md`](setup.md).

## Benchmarks (`./bench`)

Single entrypoint — code under `tools/bench/`, results under `output/bench/`, **GitHub Pages** from `docs/` via `./bench publish`.

| Subcommand | Measures | Engines |
|---|---|---|
| `./bench smoke` | HTTP up? | **all** |
| `./bench audio` | TTS latency / STT RTF | piper · whisper |
| `./bench throughput` | PP/TG | llama native · halogen/gufo HTTP |
| `./bench sched` | latency under load | llama · `dual_llm` optional |
| `./bench quality` | HumanEval | llama · halogen/gufo HTTP |
| `./bench capacity` | KV×ctx fit | llama · halogen/gufo HTTP |
| `./bench matrix` | full path per engine | **all five** (`--engine`) |
| `./bench publish` | → `docs/` | — |

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
**Public site:** `docs/` → GitHub Pages. Enable once: **Settings → Pages → Deploy from a branch → `main` / `/docs`**.  
Forks: same setting on their repo, then after benches:

```bash
./bench publish && git add docs && git commit -m "docs: refresh" && git push
```

Dashboard includes **Hardware** (`host.json`: RAM, GTT, GPU, llama.cpp pin, image id) so results stay comparable. Related community numbers: [strix-benchmarks](https://slb350.github.io/strix-benchmarks/).

### Image build (Vulkan / Nix)

Canonical path (Strix Halo / gfx1151):

```bash
./scripts/fetch-llama.sh                    # pins fork until upstream has needed MTP/model support
engines/llama-cpp/build-nix-image.sh        # llama-cpp-vulkan-nix:latest
cd engines/llama-cpp && docker compose --env-file ../../.env up -d
```

AMD ROCm alternate stack: `engines/llama-cpp/compose.rocm.yaml` + `Dockerfile.rocm`.

Pin file: [`docs/llama-pin.md`](docs/llama-pin.md) (rewritten by fetch). When [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) catches up:

```bash
LLAMA_REPO=https://github.com/ggml-org/llama.cpp.git LLAMA_REF=master ./scripts/fetch-llama.sh
engines/llama-cpp/build-nix-image.sh
```

Legacy Ubuntu `Dockerfile` is **deprecated** (Mesa/glibc mismatch on this host). ROCm remains `compose.rocm.yaml` / `Dockerfile.rocm`.

Budgets: [`setup.md`](setup.md).

## Backend: Vulkan vs ROCm

Pick **one** stack at a time (same ports). **No CUDA** — this host is AMD Strix Halo.

| | Vulkan (default / Halo) | ROCm |
|---|---|---|
| Compose | `engines/llama-cpp/compose.yaml` | `compose.rocm.yaml` |
| Image | `llama-cpp-vulkan-nix` | `Dockerfile.rocm` |
| GPU | `/dev/dri` (RADV) | `/dev/kfd` + `/dev/dri` |
| Guide | [`setup.md`](setup.md) | [`HARDWARE.md`](HARDWARE.md) |

```bash
# Vulkan (default / Strix Halo)
./scripts/fetch-llama.sh && engines/llama-cpp/build-nix-image.sh
cd engines/llama-cpp && docker compose --env-file ../../.env up -d

# ROCm (alternative AMD)
docker compose --env-file ../../.env -f compose.rocm.yaml down
docker compose --env-file ../../.env -f compose.rocm.yaml up -d --build
```

`models.ini` / sticky INIs under `engines/llama-cpp/` are the same across backends; only the compose/image changes.

## Download models

`model-dl.sh` fetches weights (GGUF / Piper / whisper) into `MODELS_ROOT` (`gguf/` · `tts/` · `stt/`). Weight / GTT sizes: [`setup.md`](setup.md).

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
  -d '{"model": "Qwen3-Embedding-4B-Q4_K_M", "input": "Hello world"}'
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
2. Run `./bench sync-models` — adds lab (+ `*-VL` if a matching mmproj exists). Sticky: edit `models.ini` / `models-coder.ini` yourself (templates in `engines/llama-cpp/presets/ini/`).
3. Optional: catalog row in `models.catalog.tsv` for HF download
4. `docker compose up -d` (INI remounted)

Example sticky `models.ini` (also under `engines/llama-cpp/presets/ini/`):

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
| `engines/` | Compose glue per engine (llama-cpp, halogen-flash, gufo) |
| `engines/llama-cpp/` | Vulkan/ROCm compose, live `models*.ini`, image build |
| `tools/bench/quality/plugins/` | Pluggable quality suites (HumanEval, …) |
| `output/bench/` | Local results (`throughput/`, `scheduling/`, `quality/`) |
| `docs/` | GitHub Pages publish set (`./bench publish`) |
| `scripts/fetch-llama.sh` | Pin / fetch llama.cpp fork or upstream |
| `setup.md` | Hardware, GTT, Sticky vs Lab budgets |
| `engines/llama-cpp/presets/ini/` | Sticky INI templates (copy → `engines/llama-cpp/`) |
| `engines/llama-cpp/models.ini` | Daily sticky chat — **local / gitignored** |
| `engines/llama-cpp/models-lab.ini` | Lab — **local**; `./bench sync-models` from disk |
| `engines/llama-cpp/models-coder.ini` | Sticky coder — **local / gitignored** |
| `engines/llama-cpp/models-embeddings.ini` | Embeddings — **local**; sync-models |
| `models-extractor.ini` | Extractor — **local**; sync-models |
| `models-bench.ini` (+ `-b`) | Capacity — **local**; `./bench capacity sync` |
| `models.catalog.tsv` | HF download sources |
| `model-dl.sh` | Download script |
| `vulkan-host-env.sh` | Legacy Mesa preload (unused by Nix image) |

## Notes

- **Multimodal:** Keep base `.gguf` and `mmproj-*.gguf` together; wire `mmproj = …` in the preset.
- **Shared access:** Daily chat `11535`, embeddings `11536`, lab `11537`, coder `11538`, extractor `11539`. Model names must match the INI section exactly.
- **Logs:** `docker compose logs -f llama` / `docker compose --profile lab logs -f llama-lab`
