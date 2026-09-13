# Capacity suite

Auto-syncs `models-bench.ini` (+ `-b`) from sticky sources, then runs KV×ctx / dual.

```bash
./bench capacity sync
./bench capacity fingerprint
./bench capacity stale
./bench capacity kv-ctx                 # solo: all models × KV × c
./bench capacity dual                   # 2× servers; c auto from GTT/RAM
CAPACITY_DUAL_C=65536,131072 ./bench capacity dual --kv q5_k,q6_k
```

**Dual `c`:** default `auto` picks a ladder from host memory (small boxes → 8k–64k,
Strix-class → up to 256k). First fail on a model+kv ladder stops further `c` for that pair.

Skip only if ledger cell is `ok` **and** fingerprint matches. After image rebuild, cells re-run.

During run: stickys/lab stopped → bench-a/b → restored. Sticky INIs never patched.
