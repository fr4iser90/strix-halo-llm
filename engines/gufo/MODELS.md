# Gufo — supported models (engine allowlist)

Gufo is **not** “any GGUF”. Upstream only ships/optimizes a fixed set.
Source of truth: [fr4iser90/gufo → docs/models](https://github.com/fr4iser90/gufo/tree/main/docs/models)
(fork of gufo-org/gufo).

Weights download: root [`models.catalog.tsv`](../../models.catalog.tsv) section
`# --- Gufo (engine allowlist) ---` + this file. Active pick: `.env` → `GUFO_MODEL`
(+ optional `GUFO_DFLASH_MODEL` / `GUFO_SPECULATIVE`).

| Family | Modes | Primary weights (HF) | Hub path under `MODELS_ROOT` |
|--------|-------|----------------------|------------------------------|
| **Qwen3.8 27B** | AR, DFlash2, images | Unsloth `Qwen3.8-27B-UD-Q4_K_XL` / `UD-Q8_K_XL` · DFlash2 `Qwen3.8-27B-DFlash2-Q4_K_M` · `mmproj-F16` / `mmproj-BF16` | `gguf/chat/large/` (+ dflash beside or same tree) |
| **Qwen3.8 Flash-Next** | AR, MTP, images | Unsloth split `UD-Q4_K_XL` · MTP `mtp-Qwen3.8-Flash-Next-shared-Q8_0` · mmproj | `gguf/chat/large/` |
| **DeepSeek V4 Flash** | AR, DSpark | antirez Flash IQ2XXS + DSpark support GGUF | `gguf/chat/large/` |
| **Qwen3-ASR 1.7B** | STT | Qwen BF16 tree | `stt/qwen3-asr/` (manual layout) |
| **Qwen3-TTS 1.7B** | TTS / clone | CustomVoice / VoiceDesign / Base BF16 | `tts/qwen3-tts/` (manual) |
| **Qwen-Image-2.1** | image gen/edit | Qwen pipeline BF16 | `hgn/…` N/A — separate tree (in progress upstream) |
| **MiniMax H3** | video/audio | FL2VA pipeline | separate tree (in progress upstream) |

Default hub smoke (compose / `.env.example`):

```bash
GUFO_MODELS=$MODELS_ROOT/gguf
GUFO_MODEL=/models/chat/large/Qwen3.8-27B-UD-Q8_K_XL.gguf
GUFO_SPECULATIVE=dflash2
GUFO_DFLASH_MODEL=/models/chat/large/Qwen3.8-27B-DFlash2-Q4_K_M.gguf
```

Do **not** point Gufo at random llama sticky GGUFs (Qwen3.6 MTP sticky, Nemotron, …) — unsupported here even if the file is GGUF.
