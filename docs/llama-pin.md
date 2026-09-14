# llama.cpp build pin

| | |
|---|---|
| Repo | `https://github.com/danielhanchen/llama.cpp.git` |
| Ref | `qwen4exp/mtp` |
| Commit | `d1a9235` (`d1a92352cbd417fd840b4e765c0b82f5fe3d1d89`) |
| Fetched | 2026-09-13T10:57:02Z |

Update on the build host:

```bash
./scripts/fetch-llama.sh
./build-nix-image.sh
```

When upstream has the needed model/MTP support:

```bash
LLAMA_REPO=https://github.com/ggml-org/llama.cpp.git LLAMA_REF=master ./scripts/fetch-llama.sh
```
