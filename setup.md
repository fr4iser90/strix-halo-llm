# Setup — Jarvis (Strix Halo / Unified Memory)

Hardware notes and **RAM / context budgets** for Sticky vs Lab, so max values (`c`, `np`, quants) and strategies stay clear.

## Hardware (live from Jarvis)

| | Value | Source |
|---|---|---|
| Host | `Jarvis` | hostname |
| System RAM | **~124 GiB** (`MemTotal` 131 007 000 kB) | `/proc/meminfo` |
| Swap | ~27 GiB | `free -h` |
| Visible VRAM | **512 MiB** | `mem_info_vram_total` / dmesg |
| **GTT (GPU-usable UMA pool)** | **100 GiB** (`102400M`) | `mem_info_gtt_total` / `amdgpu: 102400M of GTT memory ready` |
| Backend | Vulkan (`compose.yaml`), router mode | |

With Sticky loaded (Qwen3.6 Q5 VL, `c=262144`, `np=4`): ~57 GiB used / ~67 GiB available — Sticky + OS + side containers use roughly half.

## Router roles

| Router | Port | INI | Behavior |
|---|---|---|---|
| **Sticky chat** (`llama-router`) | `:11535` | `models.ini` (local; template `examples/ini/`) | Chat VL, `load-on-startup`, always warm |
| **Sticky coder** (`llama-router-coder`) | `:11538` | `models-coder.ini` (local) | Coder/Tiel, always warm |
| **Lab** (`llama-router-lab`) | `:11537` | `models-lab.ini` ← `./bench sync-models` | Swap pool / experiments (+ VL twins) |
| **Bench A/B** (`llama-bench-a/b`) | `:11601` / `:11602` | `models-bench.ini` ← capacity sync | Capacity sweeps — stickys untouched |
| **Embeddings** | `:11536` | `models-embeddings.ini` | Small; can run in parallel |
| **Extractor** | `:11539` | `models-extractor.ini` | Agents-K1; parallel |

Capacity:
```bash
docker compose -f compose.yaml -f compose.bench.yaml --profile bench up -d llama-bench-a
./bench capacity kv-ctx
./bench capacity dual --kv q5_0,q4_0
```

## Weight sizes (disk ≈ runtime floor)

| Model | Quant | File | ≈ RAM floor (weights) |
|---|---|---|---|
| Sticky Qwen3.6-35B-A3B MTP | UD-Q5_K_XL | 26 GB | ~26 GB |
| + Vision | mmproj-F16 | 0.86 GB | ~1 GB |
| Qwen3.6 | UD-Q4_K_M/XL | 22 GB | ~22 GB |
| Qwen3-Coder-30B-A3B | UD-Q4_K_XL | 17 GB | ~17 GB |
| Qwen3-Coder-30B-A3B | UD-Q5_K_XL | ~22 GB | ~22 GB |
| Qwen3.8-27B + MTP draft | Q4/Q8 | 19–29 GB + 1.7–3 GB | + draft |
| Flash-Next | Q2 / Q4 | large / ~111 GB | Q4 practically solo-only |

**Also:** KV cache (`ctk/ctv = q8_0`) scales with `c × np` — at `c=262144` and `np=4` it often dominates next to weights.

Rough rule of thumb (q8 KV, MoE/A3B):

| `c` | Extra KV pressure |
|---|---|
| 16k–64k | low–medium |
| 128k | noticeable |
| 256k | high — only if weights are small enough + Sticky off or lots of free RAM |

## Budget ceilings (decision frame)

Always reserve **~12–20 GiB** for OS + Docker side jobs (piper, whisper, qdrant, extractor, …).

### A) Sticky solo (daily)

| Item | ≈ |
|---|---|
| Qwen3.6 Q5 + mmproj | ~27 GB |
| KV @ 256k, np=4 | large (current daily config) |
| Left for Lab **in parallel** | typically **~40–60 GiB** free — enough for Coder Q5 / Qwen3.6 Q4, **not** Flash-Next Q4 |

**Practical Sticky max:** Q5 VL + `c≤262144` + `np≤4` is the daily sweet spot. Going larger is usually quality (Q6) **or** context, not both.

### B) Lab solo (Sticky + embeddings/extractor stopped) — bench default

`./bench sched` stops Sticky/embeddings/extractor, starts Lab, restores afterward.

| Available for Lab | ≈ **100 GiB GTT** usable |
|---|---|
| Coder Q5 + 256k | comfortable |
| Qwen3.8-27B Q4/Q8 + MTP + VL | OK |
| Flash-Next Q4 | borderline — weights ~111 GB > **GTT 100 GiB** (may need partial / CPU offload) |

### C) Coexist (Sticky on + Lab loads)

| Sticky holds | Lab ceiling (weights + KV) |
|---|---|
| Q5 VL ~27 GB + KV | Target Lab weights **≤ ~40 GB**, `c` preferably **64k–128k**, `np` 1–2 |
| Safe Lab picks | Coder Q4/Q5, Nemotron-30B Q4, Qwen3.6 Q4 |
| Risky | Flash-Next, 27B Q8+MTP+VL+256k |

If Lab OOMs: briefly unload Sticky or lower Lab `c` / `np`.

## Strategies (what to pick?)

1. **Daily-first (current):** Sticky = chat + VL. Coding → Lab on-demand (Coder Q5). Bench and heavy MoE only with Sticky down.
2. **Coding day:** Point Sticky at Coder **only** if coding is almost all-day — otherwise keep Lab (swap cost ≈ load time).
3. **Quality spike:** Lab Flash-Next / 27B Q8 — Sticky **off**, full budget.
4. **Bench:** always strategy B (Sticky down). Otherwise KV/weights skew ub/np/ctx sweeps.
5. **Dual warm (chat + coder):** Sticky chat on `:11535` + coder always on lab `:11537` (or `--models-max 2` later). Target **`np 2/2`**, `c` 64k–128k. Find the real ceiling with:

```bash
COEXIST_CHAT_MODEL=Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL \
COEXIST_CODER_MODEL=Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL \
COEXIST_C_LIST=65536,131072 \
COEXIST_NP_PAIRS=2:2,3:1,2:1,1:2 \
./bench sched --scenario coexist_capacity
```

Fills ~85% of per-slot context, stresses all slots, watches **GTT + MemAvailable**, writes `recommended` into the scenario summary.

## What the deep bench covers

Per model (same as the others):

| Phase | Scenarios | Finds |
|---|---|---|
| auto | 01 solo, 02 blocked, 03 interleave | is `np≥2` worth it? |
| sweeps | 04 ub, 05 np (1/2/4), 06 b | best `ub` / `np` / `b` |
| phase3 | 07 cont-batch, 08 ctx, 09 fit | cont on/off, max `c` |
| optional | 10 mtp_sweep | **only** `*-MTP*` presets (`off…4`) |
| optional | 11 coexist_capacity | dual chat+coder max `c`/`np` under filled KV + GTT watch |

**Not** in MTP sweep: Coder (no `draft-mtp` / no draft GGUF).

Throughput (`./bench throughput`) is separate: raw PP/TG; stops all routers.

## Coder Q5 — typical full run

```bash
cd ~/Documents/llama-cpp
./model-dl.sh download Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL

export SCHED_MODEL=Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL
export SCHED_NP=2 SCHED_UB=32 SCHED_B=64
export SCHED_UB_LIST=32,64,128,256
export SCHED_NP_LIST=1,2,4
export SCHED_B_LIST=32,64,128,256
export SCHED_SWEEP_UB=128 SCHED_SWEEP_NP=2
export SCHED_C_LIST=16384,32768,65536,131072,262144
export SCHED_RESTART_LAB=1

./bench throughput --lab -m Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL --vulkan
./bench sched --auto
./bench sched --scenario ub_sweep
./bench sched --scenario np_sweep
./bench sched --scenario b_sweep
./bench sched --scenario cont_batch
./bench sched --scenario ctx_sweep
./bench sched --scenario fit_probe
./bench compare-sched && ./bench index
```

No need to stop Sticky manually — `./bench sched` / `throughput` do that and bring Daily back afterward (unless `SCHED_NO_RESTORE=1` / `BENCH_NO_RESTORE=1`).
