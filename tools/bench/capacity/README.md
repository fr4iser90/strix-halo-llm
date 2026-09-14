# Capacity suite

Layout (same pattern as quality / sched / throughput):

```
tools/bench/capacity/
  run.sh
  README.md
  lib/
    common.sh       # helpers, metrics, cells
    server.sh       # capacity_bench_prepare / cleanup
    sync_ini.sh ini.sh …
  scenarios/
    kv_ctx.sh dual.sh
```

Auto-syncs `models-bench.ini` (+ `-b`) from sticky sources, then runs KV×ctx / dual.

```bash
./bench capacity sync
./bench capacity fingerprint
./bench capacity stale
./bench capacity kv-ctx                 # solo: all models × KV × c
./bench capacity kv-ctx --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B
./bench capacity kv-ctx --no-vl
./bench capacity dual                   # 2× servers; c auto from GTT/RAM
CAPACITY_FORCE_DUAL=1 ./bench capacity dual
CAPACITY_DUAL_C=65536,131072 ./bench capacity dual --kv q5_0,q4_0
```

**Dual `c`:** default `auto` from host memory. **Host gate:** skip below ~64 GiB RAM / ~48 GiB GTT.

Skip ledger cells only if `ok` **and** fingerprint matches.

During run: stickys/lab stopped → bench-a/b → restored. Sticky INIs never patched.
