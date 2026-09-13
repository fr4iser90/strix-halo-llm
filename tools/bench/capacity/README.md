# Capacity suite

Auto-syncs `models-bench.ini` (+ `-b`) from sticky sources, then runs KV×ctx / dual.

```bash
./bench capacity sync
./bench capacity fingerprint
./bench capacity stale
./bench capacity kv-ctx                 # solo: all models × KV × c
./bench capacity kv-ctx --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B
./bench capacity kv-ctx --no-vl
./bench capacity dual                   # 2× servers; c auto from GTT/RAM
# Skips if RAM < ~64 GiB or GTT < ~48 GiB unless:
CAPACITY_FORCE_DUAL=1 ./bench capacity dual
CAPACITY_DUAL_C=65536,131072 ./bench capacity dual --kv q5_0,q4_0
```

**Dual `c`:** default `auto` picks a ladder from host memory (small boxes → 8k–64k,
Strix-class → up to 256k). First fail on a model+kv ladder stops further `c` for that pair.
**Dual host gate:** default auto-skip below ~64 GiB RAM or ~48 GiB GTT (`CAPACITY_FORCE_DUAL=1` to run anyway).

Skip only if ledger cell is `ok` **and** fingerprint matches. After image rebuild, cells re-run.

During run: stickys/lab stopped → bench-a/b → restored. Sticky INIs never patched.
