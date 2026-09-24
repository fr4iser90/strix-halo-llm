# Piper TTS

OpenAI-compatible speech endpoint (`POST /audio/speech`) on port **9001**.

```bash
# voices → TTS_MODELS (default ../../models/tts)
./model-dl.sh init-dirs
./model-dl.sh download de_DE-thorsten-high.onnx   # if listed in catalog

cd engines/piper
docker compose --env-file ../../.env up -d --build
```

Env: `TTS_MODELS`, `PIPER_DEFAULT_VOICE`, `PIPER_PUBLISH_PORT`.
