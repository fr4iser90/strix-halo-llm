# INI presets (templates)

Copy into `engines/llama-cpp/` (live files are gitignored):

```bash
cp engines/llama-cpp/presets/ini/models.ini \
   engines/llama-cpp/presets/ini/models-coder.ini \
   engines/llama-cpp/
# edit paths to match MODELS_DIR (default ./models/gguf → /models/chat/… in container)
./bench sync-models
```
