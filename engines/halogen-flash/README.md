# Halogen Flash

Two-container GHCR stack (engine + API). Port **8731**.

```bash
# HALOGEN_MODELS = pack dir with *.hgn + tokenizer/
export HALOGEN_MODELS=${MODELS_ROOT:-./models}/hgn/qwen38flash
cd engines/halogen-flash
docker compose --env-file ../../.env up -d
```

Bench: `./bench matrix --engine halogen-flash` (lifecycle uses this compose).
