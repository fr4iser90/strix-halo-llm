# Bench — Dashboard

**Start here.** Hardware first (comparability), then recommendations, history below.

## Hardware

Compare results only across similar RAM/GTT/backends. [host.json](host.json)

| | |
|---|---|
| Host | Jarvis |
| OS | NixOS 26.05 (Yarara) |
| Kernel | 7.2.2 |
| CPU | AMD RYZEN AI MAX+ 395 w/ Radeon 8060S (32 threads) |
| RAM | 124.9 GiB (avail ~77.3 GiB) |
| Swap | 18.7 GiB |
| GTT (UMA) | 100.0 GiB (used ~28.8 GiB) |
| Visible VRAM | 512 MiB |
| GPU | c5:00.0 Display controller: Advanced Micro Devices, Inc. [AMD/ATI] Strix Halo [Radeon Graphics / Radeon 8050S Graphics / Radeon 8060S Graphics] (rev c1) |
| Backend | vulkan |
| Image | llama-cpp-vulkan-nix:latest (`366f8b040ab0`) |
| llama.cpp | qwen4exp/mtp @ `d1a92352cbd4` |
| Probed | 2026-09-14T19:40:55Z |

> AMD Strix Halo / unified memory: GTT is the GPU-usable UMA pool (not discrete VRAM). Compare benches only across similar GTT/RAM.

## Scheduling — which `ub`? (np=2, keep decode low)

Decode latency + prefill throughput **under load**. [Details →](scheduling/latest/compare.html)

| Model | np ★ | ub ★ | b ★ | c ★ | MTP ★ | cont-batch | Prefill tok/s | TTFT ms | Decode tok/s | Decode ms | TG tok/s | Interleave |
| --- | ---: | ---: | ---: | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | **1** | **128** | **64†** | **—** | **3** | off ★ | 54.4 | 31,898 | — | 17.9 | 56.9 | 297× |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | **1** | **256** | **64†** | **—** | **3** | on ★ | 63.7 | 31,868 | — | 37.6 | 56.9 | 344× |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | **2** | **32** | **64†** | **—** | **3** | off ★ | 69.8 | 44,867 | — | 15.5 | 57.1 | 61× |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | **1** | **64** | **64†** | **—** | **3** | on ★ | 57.8 | 31,980 | — | 36.2 | 56.9 | 320× |

† `b` default until the batch sweep finishes.

## Apply settings

```bash
./bench apply-ini --dry-run --lab
./bench apply-ini --lab
```

Plan: [`scheduling/latest/apply-plan.json`](scheduling/latest/apply-plan.json)


## Throughput — which model is fastest?

[Details →](throughput/latest/compare.html) · PP = Prompt tok/s · TG = Generation tok/s · **higher = better**

| Model | PP (512 tok) | TG (128 tok) |
| --- | ---: | ---: |
| Cyber-Tiel-Coder-35B-A3B-MTP-Q5_K_XL | 1030.6 | 57.3 |
| Qwen3.6-35B-A3B-MTP-Q5_K_XL | 1029.6 | 57.0 |
| Tiel-Coder-35B-A3B-MTP-Q5_K_XL | 1023.9 | 56.5 |

## Quality — task correctness

[Details →](quality/latest/compare.md)

| Suite | Model | pass@1 | pass@10 | Stamp |
| --- | --- | ---: | ---: | --- |
| humaneval | `Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL` | 0.585 | — | `20260914T165918Z` |
| humaneval | `Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL` | 0.598 | — | `20260914T174552Z` |
| humaneval | `Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL` | 0.623 | 0.799 | `20260914T183437Z` |

## Capacity — KV×ctx / dual

Ledger cells: **74** · [compare.md](capacity/latest/compare.md)

Cell = GTT MiB · prefill s · prefill tok/s

### Max safe context

| Model | kv | max c | GTT | Prefill tok/s |
| --- | --- | ---: | ---: | ---: |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q4_0 | **262144** | 27824 MiB | 233.87 |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q5_0 | **262144** | 28144 MiB | 224.26 |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q8_0 | **262144** | 29448 MiB | 240.42 |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | q4_0 | **262144** | 28852 MiB | 187.64 |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | q5_0 | **262144** | 29172 MiB | 182.08 |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | q8_0 | **262144** | 30132 MiB | 188.83 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | q4_0 | **262144** | 28270 MiB | 238.35 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | q5_0 | **262144** | 28590 MiB | 228.67 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | q8_0 | **262144** | 29894 MiB | 246.24 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | q4_0 | **262144** | 29376 MiB | 238.16 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | q5_0 | **262144** | 29696 MiB | 230.68 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | q8_0 | **262144** | 31000 MiB | 245.82 |
| Qwen3.8-27B-UD-Q4_K_M-MTP | q8_0 | **131072** | 21166 MiB | 2654.34 |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q4_0 | **262144** | 27824 MiB | 230.9 |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q5_0 | **262144** | 28144 MiB | 221.18 |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q8_0 | **262144** | 29448 MiB | 241.35 |

### Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL (solo)

Cell = **GTT MiB · prefill s · prefill tok/s**

| c \ kv | q4_0 | q5_0 | q8_0 |
| ---: | --- | --- | --- |
| 32768 | — | 26030 MiB · 75.41 s · 391.08 t/s PP | 26167 MiB · 73.488 s · 401.3 t/s PP |
| 65536 | — | 26354 MiB · 169.987 s · 346.98 t/s PP | 26679 MiB · 163.079 s · 361.68 t/s PP |
| 131072 | 26778 MiB · 390.618 s · 301.99 t/s PP | 26938 MiB · 400.049 s · 294.87 t/s PP | 27556 MiB · 383.7 s · 307.44 t/s PP |
| 196608 | 27426 MiB · 669.769 s · 264.19 t/s PP | 27514 MiB · 696.965 s · 253.88 t/s PP | 28500 MiB · 653.61 s · 270.72 t/s PP |
| 262144 | 27824 MiB · 1008.79 s · 233.87 t/s PP | 28144 MiB · 1052.016 s · 224.26 t/s PP | 29448 MiB · 981.31 s · 240.42 t/s PP |

### Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL (solo)

Cell = **GTT MiB · prefill s · prefill tok/s**

| c \ kv | q4_0 | q5_0 | q8_0 |
| ---: | --- | --- | --- |
| 32768 | — | 27123 MiB · 106.613 s · 276.62 t/s PP | 27203 MiB · 103.474 s · 285.01 t/s PP |
| 65536 | — | 27444 MiB · 234.927 s · 251.07 t/s PP | 27684 MiB · 230.504 s · 255.88 t/s PP |
| 131072 | 27860 MiB · 522.346 s · 225.83 t/s PP | 28020 MiB · 531.303 s · 222.03 t/s PP | 28444 MiB · 521.276 s · 226.3 t/s PP |
| 196608 | 28499 MiB · 863.298 s · 204.97 t/s PP | 28558 MiB · 887.096 s · 199.47 t/s PP | 29316 MiB · 859.831 s · 205.79 t/s PP |
| 262144 | 28852 MiB · 1257.32 s · 187.64 t/s PP | 29172 MiB · 1295.778 s · 182.08 t/s PP | 30132 MiB · 1249.411 s · 188.83 t/s PP |

### Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL (solo)

Cell = **GTT MiB · prefill s · prefill tok/s**

| c \ kv | q4_0 | q5_0 | q8_0 |
| ---: | --- | --- | --- |
| 32768 | — | 26450 MiB · 70.966 s · 415.57 t/s PP | 26585 MiB · 69.845 s · 422.23 t/s PP |
| 65536 | — | 26723 MiB · 161.609 s · 364.97 t/s PP | 27048 MiB · 154.514 s · 381.73 t/s PP |
| 131072 | 27262 MiB · 376.891 s · 312.99 t/s PP | 27422 MiB · 384.595 s · 306.72 t/s PP | 27974 MiB · 369.593 s · 319.17 t/s PP |
| 196608 | 27687 MiB · 653.609 s · 270.72 t/s PP | 27933 MiB · 679.307 s · 260.48 t/s PP | 28983 MiB · 634.008 s · 279.09 t/s PP |
| 262144 | 28270 MiB · 989.833 s · 238.35 t/s PP | 28590 MiB · 1031.726 s · 228.67 t/s PP | 29894 MiB · 958.133 s · 246.24 t/s PP |

### Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL (solo)

Cell = **GTT MiB · prefill s · prefill tok/s**

| c \ kv | q4_0 | q5_0 | q8_0 |
| ---: | --- | --- | --- |
| 32768 | — | 27556 MiB · 70.841 s · 416.3 t/s PP | 27691 MiB · 69.276 s · 425.7 t/s PP |
| 65536 | — | 27829 MiB · 161.756 s · 364.64 t/s PP | 28154 MiB · 156.418 s · 377.08 t/s PP |
| 131072 | 28368 MiB · 374.002 s · 315.41 t/s PP | 28528 MiB · 384.689 s · 306.65 t/s PP | 29080 MiB · 369.862 s · 318.94 t/s PP |
| 196608 | 28793 MiB · 653.956 s · 270.58 t/s PP | 29039 MiB · 678.917 s · 260.63 t/s PP | 30278 MiB · 634.599 s · 278.83 t/s PP |
| 262144 | 29376 MiB · 990.616 s · 238.16 t/s PP | 29696 MiB · 1022.736 s · 230.68 t/s PP | 31000 MiB · 959.764 s · 245.82 t/s PP |

### Qwen3.8-27B-UD-Q4_K_M-MTP (solo)

Cell = **GTT MiB · prefill s · prefill tok/s**

| c \ kv | q8_0 |
| ---: | --- |
| 32768 | 17313 MiB · 178.834 s · 164.91 t/s PP |
| 65536 | 18590 MiB · 23.871 s · 2470.86 t/s PP |
| 131072 | 21166 MiB · 44.442 s · 2654.34 t/s PP |

### Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL (solo)

Cell = **GTT MiB · prefill s · prefill tok/s**

| c \ kv | q4_0 | q5_0 | q8_0 |
| ---: | --- | --- | --- |
| 32768 | — | 26030 MiB · 74.569 s · 395.49 t/s PP | 26167 MiB · 72.938 s · 404.33 t/s PP |
| 65536 | — | 26354 MiB · 168.315 s · 350.43 t/s PP | 26679 MiB · 162.486 s · 363.0 t/s PP |
| 131072 | 26778 MiB · 393.41 s · 299.85 t/s PP | 26938 MiB · 402.198 s · 293.3 t/s PP | 27556 MiB · 384.376 s · 306.9 t/s PP |
| 196608 | 27426 MiB · 673.758 s · 262.63 t/s PP | 27514 MiB · 705.643 s · 250.76 t/s PP | 28641 MiB · 653.528 s · 270.76 t/s PP |
| 262144 | 27824 MiB · 1021.789 s · 230.9 t/s PP | 28144 MiB · 1066.699 s · 221.18 t/s PP | 29448 MiB · 977.549 s · 241.35 t/s PP |

### Dual (2× same model)

| model | kv | c | ok | GTT peak | Mem avail | phase |
| --- | --- | ---: | --- | ---: | ---: | --- |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q5_0 | 32768 | ✓ | 52335 MiB | 63051 MiB | ok |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q8_0 | 32768 | ✓ | 52709 MiB | 63070 MiB | ok |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q8_0 | 65536 | ✓ | 53606 MiB | 61872 MiB | ok |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q8_0 | 131072 | ✓ | 55434 MiB | 59549 MiB | ok |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q8_0 | 196608 | ✓ | 57305 MiB | 57184 MiB | ok |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | q8_0 | 262144 | ✓ | 59294 MiB | 55331 MiB | ok |


## Matrix — long-run status

Phase: **throughput** · vulkan · updated `2026-09-14T15:27:03Z`


## Matrix progress

| Model | Status | np ★ | ub ★ | b ★ | MTP ★ | TTFT ms | Decode tok/s | Decode ms |
| --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 1 | 128 | 64† | 3 | 31,898 | — | 17.9 |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 1 | 256 | 64† | 3 | 31,868 | — | 37.6 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 2 | 32 | 64† | 3 | 44,867 | — | 15.5 |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 1 | 64 | 64† | 3 | 31,980 | — | 36.2 |

---

<details>
<summary>Run history (raw)</summary>

### Throughput runs

| When | Stamp | Suite | Backends |
| --- | --- | --- | --- |
| 2026-09-13 21:15 UTC | `20260913T211553Z` | lab | vulkan |

### Scheduling runs

| When | Model | Scenarios | Folder |
| --- | --- | --- | --- |
| 2026-09-14 15:21 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 10_mtp_sweep | [20260914T152123Z](scheduling/20260914T152123Z/) |
| 2026-09-14 15:19 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260914T151916Z](scheduling/20260914T151916Z/) |
| 2026-09-14 15:15 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T151536Z](scheduling/20260914T151536Z/) |
| 2026-09-14 15:13 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260914T151300Z](scheduling/20260914T151300Z/) |
| 2026-09-14 15:09 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T150918Z](scheduling/20260914T150918Z/) |
| 2026-09-14 15:08 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260914T150812Z](scheduling/20260914T150812Z/) |
| 2026-09-14 15:02 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 10_mtp_sweep | [20260914T150209Z](scheduling/20260914T150209Z/) |
| 2026-09-14 15:00 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 07_cont_batch | [20260914T150000Z](scheduling/20260914T150000Z/) |
| 2026-09-14 14:56 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 04_ub_sweep | [20260914T145621Z](scheduling/20260914T145621Z/) |
| 2026-09-14 14:53 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 05_np_sweep | [20260914T145346Z](scheduling/20260914T145346Z/) |
| 2026-09-14 14:50 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 04_ub_sweep | [20260914T145006Z](scheduling/20260914T145006Z/) |
| 2026-09-14 14:49 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260914T144900Z](scheduling/20260914T144900Z/) |
| 2026-09-14 14:43 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 10_mtp_sweep | [20260914T144316Z](scheduling/20260914T144316Z/) |
| 2026-09-14 14:41 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260914T144108Z](scheduling/20260914T144108Z/) |
| 2026-09-14 14:37 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T143729Z](scheduling/20260914T143729Z/) |
| 2026-09-14 14:34 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260914T143453Z](scheduling/20260914T143453Z/) |
| 2026-09-14 14:31 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T143114Z](scheduling/20260914T143114Z/) |
| 2026-09-14 14:30 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260914T143007Z](scheduling/20260914T143007Z/) |
| 2026-09-14 14:24 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 10_mtp_sweep | [20260914T142409Z](scheduling/20260914T142409Z/) |
| 2026-09-14 14:22 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260914T142206Z](scheduling/20260914T142206Z/) |
| 2026-09-14 14:18 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T141837Z](scheduling/20260914T141837Z/) |
| 2026-09-14 14:16 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260914T141610Z](scheduling/20260914T141610Z/) |
| 2026-09-14 14:12 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T141241Z](scheduling/20260914T141241Z/) |
| 2026-09-14 14:11 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260914T141137Z](scheduling/20260914T141137Z/) |
| 2026-09-14 08:06 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 10_mtp_sweep | [20260914T080653Z](scheduling/20260914T080653Z/) |
| 2026-09-14 08:04 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260914T080444Z](scheduling/20260914T080444Z/) |
| 2026-09-14 08:01 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T080105Z](scheduling/20260914T080105Z/) |
| 2026-09-14 07:58 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260914T075830Z](scheduling/20260914T075830Z/) |
| 2026-09-14 07:54 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T075437Z](scheduling/20260914T075437Z/) |
| 2026-09-14 07:53 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260914T075331Z](scheduling/20260914T075331Z/) |
| 2026-09-14 07:47 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 10_mtp_sweep | [20260914T074730Z](scheduling/20260914T074730Z/) |
| 2026-09-14 07:45 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 07_cont_batch | [20260914T074523Z](scheduling/20260914T074523Z/) |
| 2026-09-14 07:41 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 04_ub_sweep | [20260914T074143Z](scheduling/20260914T074143Z/) |
| 2026-09-14 07:39 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 05_np_sweep | [20260914T073908Z](scheduling/20260914T073908Z/) |
| 2026-09-14 07:35 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 04_ub_sweep | [20260914T073529Z](scheduling/20260914T073529Z/) |
| 2026-09-14 07:34 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260914T073424Z](scheduling/20260914T073424Z/) |
| 2026-09-14 07:28 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 10_mtp_sweep | [20260914T072840Z](scheduling/20260914T072840Z/) |
| 2026-09-14 07:26 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260914T072632Z](scheduling/20260914T072632Z/) |
| 2026-09-14 07:22 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T072254Z](scheduling/20260914T072254Z/) |
| 2026-09-14 07:20 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260914T072018Z](scheduling/20260914T072018Z/) |
| 2026-09-14 07:16 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T071639Z](scheduling/20260914T071639Z/) |
| 2026-09-14 07:15 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260914T071533Z](scheduling/20260914T071533Z/) |
| 2026-09-14 07:10 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 10_mtp_sweep | [20260914T071003Z](scheduling/20260914T071003Z/) |
| 2026-09-14 07:08 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260914T070800Z](scheduling/20260914T070800Z/) |
| 2026-09-14 07:04 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T070431Z](scheduling/20260914T070431Z/) |
| 2026-09-14 07:02 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260914T070204Z](scheduling/20260914T070204Z/) |
| 2026-09-14 06:58 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260914T065835Z](scheduling/20260914T065835Z/) |
| 2026-09-14 06:57 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260914T065730Z](scheduling/20260914T065730Z/) |
| 2026-09-13 21:59 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | — | [20260913T215910Z](scheduling/20260913T215910Z/) |
| 2026-09-13 21:56 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260913T215648Z](scheduling/20260913T215648Z/) |
| 2026-09-13 21:52 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260913T215246Z](scheduling/20260913T215246Z/) |
| 2026-09-13 21:49 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260913T214947Z](scheduling/20260913T214947Z/) |
| 2026-09-13 21:45 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260913T214523Z](scheduling/20260913T214523Z/) |
| 2026-09-13 21:42 UTC | Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260913T214243Z](scheduling/20260913T214243Z/) |
| 2026-09-13 21:34 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 10_mtp_sweep | [20260913T213406Z](scheduling/20260913T213406Z/) |
| 2026-09-13 21:31 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260913T213136Z](scheduling/20260913T213136Z/) |
| 2026-09-13 21:26 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260913T212640Z](scheduling/20260913T212640Z/) |
| 2026-09-13 21:23 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260913T212340Z](scheduling/20260913T212340Z/) |
| 2026-09-13 21:19 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260913T211936Z](scheduling/20260913T211936Z/) |
| 2026-09-13 21:18 UTC | Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260913T211814Z](scheduling/20260913T211814Z/) |

</details>
