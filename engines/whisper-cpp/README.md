# whisper.cpp STT

HTTP transcription server on port **9000**.

```bash
# weights: MODELS_ROOT/stt/ggml-large-v3.bin  (./model-dl.sh)
./stack up whisper
```

`STT_MODELS` must be the **host** dir that contains `WHISPER_MODEL` (default `ggml-large-v3.bin`).
`./stack` resolves it absolute and `--force-recreate`s so bind mounts stick.
