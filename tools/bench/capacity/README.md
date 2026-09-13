# Capacity suite

Auto-syncs `models-bench.ini` (+ `-b`) from sticky sources, then runs KV×ctx / dual-256k.

```bash
./bench capacity sync
./bench capacity fingerprint          # llama-server + image id
./bench capacity stale                # cells to re-run after upgrades
./bench capacity kv-ctx               # ALL models × matrix (skip fresh)
./bench capacity kv-ctx --from coder
./bench capacity dual-256k --kv q5_k,q6_k
```

Skip only if ledger cell is `ok` **and** `server_version` + `image_id` match current image.  
After rebuilding `llama-cpp-vulkan-nix`, old cells re-run automatically.

During run: stickys/lab stopped → bench-a/b → restored. Sticky INIs never patched.
