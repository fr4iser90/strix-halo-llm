# whisper.cpp STT

HTTP transcription server on port **9000**.

```bash
./model-dl.sh init-dirs
# place ggml-*.bin under STT_MODELS (default ../../models/stt)

cd engines/whisper-cpp
docker compose --env-file ../../.env up -d --build
```

Env: `STT_MODELS`, `WHISPER_MODEL` (filename under that dir), `WHISPER_PUBLISH_PORT`.
