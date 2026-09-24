# Gufo

Single-process OpenAI-compatible server (GHCR). Port **8080**.
**Supported models only** — see [`MODELS.md`](MODELS.md) (from [gufo docs/models](https://github.com/fr4iser90/gufo/tree/main/docs/models)).

```bash
# .env — must be an allowlisted GGUF (+ optional DFlash2)
# GUFO_MODELS=$MODELS_ROOT/gguf
# GUFO_MODEL=/models/chat/large/Qwen3.8-27B-UD-Q8_K_XL.gguf
# GUFO_SPECULATIVE=dflash2
# GUFO_DFLASH_MODEL=/models/chat/large/Qwen3.8-27B-DFlash2-Q4_K_M.gguf
cd engines/gufo
docker compose --env-file ../../.env up -d
```

Under Docker use `GUFO_GROUP_ADD=video` (default). Podman may need `keep-groups` — see compose comments.

Bench: `./bench matrix --engine gufo`.
