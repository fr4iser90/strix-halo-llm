# Throughput suite

PP/TG ranking via `llama-bench` (one-shot docker). Stickys stopped, then restored.

```
tools/bench/throughput/
  run.sh              # CLI (./bench throughput)
  README.md
  lib/
    server.sh         # throughput_bench_prepare / cleanup
    llama_bench.sh    # backends, CSV, compare
```

```bash
./bench throughput --vulkan -m Qwen3.6
./bench throughput --list --bench
./bench throughput --compare
```

Default suite: `--bench` → sync `models-bench.ini`. Also: `--daily`, `--lab`, `--all`.
