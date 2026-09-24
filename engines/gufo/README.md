# Gufo

Single-process OpenAI-compatible server (GHCR). Port **8080**.
**Supported models only** — see [`MODELS.md`](MODELS.md) (from [gufo docs/models](https://github.com/fr4iser90/gufo/tree/main/docs/models)).

```bash
# .env — daily default: Flash-Next Q4 @ 262k
# GUFO_MODELS=$MODELS_ROOT/gguf
# GUFO_MODEL=/models/chat/large/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf
# GUFO_EXTRA_ARGS=--context 262144
cd engines/gufo
docker compose --env-file ../../.env up -d
```

Under Docker use `GUFO_GROUP_ADD=video` (default). Podman may need `keep-groups` — see compose comments.

Bench: `./bench matrix --engine gufo`. Allowlist: [`MODELS.md`](MODELS.md).
