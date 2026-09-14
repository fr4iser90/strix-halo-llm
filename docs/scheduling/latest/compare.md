# Scheduling — compare & recommendations

Decode latency and prefill throughput **under load** (2 slots, rolling prefill). Bench-a `:11601`, `np=2`.

## Metrics

| Metric | Meaning | Target |
| --- | --- | --- |
| **Decode ms** | time per generated token (slot A, under load) | low (~33 ms) |
| **Prefill tok/s** | prompt throughput while decode runs (≈ PP under load) | high |
| **Prefill TTFT** | ms until first prefill token (4k prompt) | low |
| **PP idle** | prompt tok/s idle (from throughput bench) | reference |

## Recommendation per model

| Model | np ★ | ub ★ | b ★ | c ★ | cont-batch | PP on | PP off | Decode ms | Prefill tok/s |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 1 | 128 | — | — | off ★ | 462.8 | 462.4 | 17.9 | 54.4 |
| Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL | 1 | 256 | — | — | on ★ | 462.5 | 462.9 | 37.6 | 63.7 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 2 | 32 | — | — | off ★ | 491.5 | 491.2 | 15.5 | 69.8 |
| Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL | 1 | 64 | — | — | on ★ | 462.8 | 462.9 | 36.2 | 57.8 |

---

## Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL

**Throughput (idle, lab Vulkan):** PP 1,012 tok/s · TG 56.9 tok/s

### Interleaving — lohnt sich np=2?

| Scenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (reference) | 38.0 | 55.9 | — | — |
| 02 blocked (np=1, schlecht) | 38.0 | 60.5 | 64.8 | 47,077 ⚠ |
| 03 interleave (np=2) | 37.1 | 59.2 | 68.4 | 158.6 |

→ **Interleaving:** Prefill-TTFT **297× faster** than blocked (47,077 ms → 158.6 ms). Decode bleibt ~37.1 ms.

### ub-sweep — best batch size under load

Tested with scenario 03 (decode + 4k prefill in parallel). **Goal:** low decode latency + high prefill throughput + low TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 128 | 17.9 | 75.8 | 54.4 | 31,898 | **★ best** |
| 256 | 35.9 | 63.9 | 60.0 | 31,911 | ⚠ invalid |
| 32 | 37.1 | 69.5 | 62.8 | 47,521 | ⚠ invalid |
| 64 | 37.4 | 55.2 | 49.5 | 31,885 | ⚠ invalid |

→ **Recommendation:** `ub = 128`

### np-sweep — parallel slots (ub=128 fixed)

Scenario 03 under load.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 37.5 | 59.8 | 60.0 | 32,707 | **★ best** |
| 2 | 37.5 | 65.0 | 59.3 | 31,923 | ⚠ invalid |
| 4 | 37.7 | 65.5 | 53.6 | 31,808 | ⚠ invalid |

→ **Recommendation:** `np = 1`

### cont-batching — on vs off

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 462.8 | 62.3 | 37.3 | 50.5 | 185.2 |
| aus (--no-cont-batching) | 462.4 | 64.3 | 37.8 | 54.1 | 176.2 |

→ **Recommendation:** cont-batching **off**

### MTP — off vs draft-mtp n-max

| n | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 25.8 | 59.4 | 58.0 | 47,868 |  |
| 2 | 31.6 | 68.0 | 52.3 | 47,091 |  |
| 3 | 37.5 | 69.1 | 57.2 | 47,510 | **★ best** |
| 4 | 43.6 | 56.9 | 47.1 | 47,889 |  |
| off | 17.3 | 56.8 | 51.1 | 46,010 |  |

→ **Recommendation:** `spec-draft-n-max = 3`

## Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL-VL

**Throughput (idle, lab Vulkan):** PP 1,012 tok/s · TG 56.9 tok/s

### Interleaving — lohnt sich np=2?

| Scenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (reference) | 37.4 | 64.5 | — | — |
| 02 blocked (np=1, schlecht) | 38.0 | 62.7 | 54.1 | 47,042 ⚠ |
| 03 interleave (np=2) | 17.2 | 74.5 | 66.4 | 136.8 |

→ **Interleaving:** Prefill-TTFT **344× faster** than blocked (47,042 ms → 136.8 ms). Decode bleibt ~17.2 ms.

### ub-sweep — best batch size under load

Tested with scenario 03 (decode + 4k prefill in parallel). **Goal:** low decode latency + high prefill throughput + low TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 256 | 37.6 | 64.1 | 63.7 | 31,868 | **★ best** |
| 32 | 37.7 | 67.2 | 57.8 | 47,541 | ⚠ invalid |
| 64 | 38.1 | 63.4 | 56.3 | 31,916 | ⚠ invalid |
| 128 | 38.2 | 71.6 | 52.6 | 31,915 | ⚠ invalid |

→ **Recommendation:** `ub = 256`

### np-sweep — parallel slots (ub=128 fixed)

Scenario 03 under load.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 37.5 | 64.2 | 52.1 | 32,734 | **★ best** |
| 2 | 38.2 | 54.0 | 57.3 | 31,877 | ⚠ invalid |
| 4 | 38.3 | 64.8 | 64.5 | 31,853 | ⚠ invalid |

→ **Recommendation:** `np = 1`

### cont-batching — on vs off

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 462.5 | 59.1 | 38.0 | 63.9 | 184.8 |
| aus (--no-cont-batching) | 462.9 | 63.8 | 37.6 | 63.1 | 182.8 |

→ **Recommendation:** cont-batching **on**

### MTP — off vs draft-mtp n-max

| n | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 25.6 | 66.6 | 59.3 | 47,901 |  |
| 2 | 32.0 | 65.7 | 57.6 | 47,114 |  |
| 3 | 36.2 | 68.9 | 59.6 | 47,509 | **★ best** |
| 4 | 44.5 | 59.6 | 51.4 | 47,901 |  |
| off | 17.5 | 54.7 | 50.8 | 46,086 |  |

→ **Recommendation:** `spec-draft-n-max = 3`

## Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL

**Throughput (idle, lab Vulkan):** PP 1,033 tok/s · TG 57.1 tok/s

### Interleaving — lohnt sich np=2?

| Scenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (reference) | 31.2 | 88.4 | — | — |
| 02 blocked (np=1, schlecht) | 31.5 | 88.5 | 79.5 | 45,232 ⚠ |
| 03 interleave (np=2) | 32.4 | 82.4 | 72.2 | 736.0 |

→ **Interleaving:** Prefill-TTFT **61× faster** than blocked (45,232 ms → 736.0 ms). Decode bleibt ~32.4 ms.

### ub-sweep — best batch size under load

Tested with scenario 03 (decode + 4k prefill in parallel). **Goal:** low decode latency + high prefill throughput + low TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 32 | 15.5 | 80.5 | 69.8 | 44,867 | **★ best** |
| 128 | 32.0 | 84.8 | 69.4 | 30,032 | ⚠ invalid |
| 64 | 32.1 | 79.8 | 67.6 | 30,006 | ⚠ invalid |
| 256 | 34.4 | 90.0 | 69.1 | 30,055 | ⚠ invalid |

→ **Recommendation:** `ub = 32`

### np-sweep — parallel slots (ub=128 fixed)

Scenario 03 under load.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 2 | 31.2 | 85.8 | 68.8 | 29,904 | **★ best** |
| 1 | 31.2 | 79.3 | 70.4 | 30,516 | ⚠ invalid |
| 4 | 35.6 | 88.3 | 68.3 | 29,994 | ⚠ invalid |

→ **Recommendation:** `np = 2`

### cont-batching — on vs off

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 491.5 | 79.3 | 30.9 | 77.9 | 147.0 |
| aus (--no-cont-batching) | 491.2 | 78.6 | 15.9 | 82.0 | 151.2 |

→ **Recommendation:** cont-batching **off**

### MTP — off vs draft-mtp n-max

| n | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 25.4 | 73.7 | 68.0 | 45,350 |  |
| 2 | 31.6 | 78.0 | 72.1 | 44,915 |  |
| 3 | 41.4 | 91.3 | 82.7 | 45,340 | **★ best** |
| 4 | 49.4 | 90.2 | 76.4 | 45,664 |  |
| off | 17.4 | 57.1 | 53.0 | 43,714 |  |

→ **Recommendation:** `spec-draft-n-max = 3`

## Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL

**Throughput (idle, lab Vulkan):** PP 1,020 tok/s · TG 56.9 tok/s

### Interleaving — lohnt sich np=2?

| Scenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (reference) | 18.7 | 69.0 | — | — |
| 02 blocked (np=1, schlecht) | 37.1 | 71.2 | 66.2 | 47,213 ⚠ |
| 03 interleave (np=2) | 38.5 | 58.5 | 60.5 | 147.4 |

→ **Interleaving:** Prefill-TTFT **320× faster** than blocked (47,213 ms → 147.4 ms). Decode bleibt ~38.5 ms.

### ub-sweep — best batch size under load

Tested with scenario 03 (decode + 4k prefill in parallel). **Goal:** low decode latency + high prefill throughput + low TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 64 | 36.2 | 61.9 | 57.8 | 31,980 | **★ best** |
| 32 | 36.7 | 67.2 | 50.8 | 47,634 | ⚠ invalid |
| 128 | 37.6 | 52.1 | 51.9 | 31,932 | ⚠ invalid |
| 256 | 38.0 | 69.7 | 52.4 | 31,990 | ⚠ invalid |

→ **Recommendation:** `ub = 64`

### np-sweep — parallel slots (ub=128 fixed)

Scenario 03 under load.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 36.9 | 62.7 | 60.2 | 32,702 | **★ best** |
| 4 | 37.2 | 65.2 | 56.1 | 31,842 | ⚠ invalid |
| 2 | 37.9 | 63.8 | 47.0 | 31,992 | ⚠ invalid |

→ **Recommendation:** `np = 1`

### cont-batching — on vs off

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 462.8 | 59.5 | 37.4 | 59.0 | 178.2 |
| aus (--no-cont-batching) | 462.9 | 59.1 | 37.0 | 57.9 | 188.7 |

→ **Recommendation:** cont-batching **on**

### MTP — off vs draft-mtp n-max

| n | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 25.7 | 63.4 | 62.1 | 47,984 |  |
| 2 | 31.6 | 68.2 | 55.2 | 47,236 |  |
| 3 | 36.9 | 78.9 | 52.5 | 47,629 | **★ best** |
| 4 | 37.8 | 60.0 | 50.0 | 48,035 |  |
| off | 17.4 | 56.8 | 50.9 | 46,200 |  |

→ **Recommendation:** `spec-draft-n-max = 3`
