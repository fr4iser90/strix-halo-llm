# Scheduling — Vergleich & Empfehlungen

Decode-Latenz und Prefill-Durchsatz **unter Last** (2 Slots, rolling prefill). Lab-Router `:11537`, `np=2`.

## Metriken

| Metrik | Bedeutung | Ziel |
| --- | --- | --- |
| **Decode ms** | Zeit pro generiertem Token (Slot A, unter Last) | niedrig (~33 ms) |
| **Prefill tok/s** | Prompt-Durchsatz während Decode läuft (≈ PP unter Last) | hoch |
| **Prefill TTFT** | ms bis erster Prefill-Token (4k Prompt) | niedrig |
| **PP idle** | Prompt-tok/s ohne Last (aus Throughput-Bench) | Referenz |

## Empfehlung pro Modell

| Modell | np ★ | ub ★ | b ★ | c ★ | cont-batch | PP an | PP aus | Decode ms | Prefill tok/s |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL | 2 | 256 | — | — | on (default) | — | — | 12.5 | 63.8 |
| Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 2 | 128 | — | 262144 | on ★ | 428.3 | 409.5 | 31.1 | 76.2 |
| Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 4 | 64 | — | 262144 | on ★ | 425.4 | 397.5 | 32.1 | 83.1 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 2 | 256 | — | 262144 | off ★ | 127.4 | 385.2 | 35.4 | 71.8 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 4 | 256 | — | 262144 | on ★ | 345.9 | 350.6 | 35.5 | 71.7 |
| Qwen3.8-27B-Q4_K_M-MTP | 4 | 128 | — | 262144 | off ★ | 59.8 | 239.4 | 130.8 | 16.9 |
| Qwen3.8-27B-Q4_K_M-MTP-VL | 4 | 64 | — | 262144 | on ★ | 237.7 | 233.9 | 130.6 | 16.9 |

---

## Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL

**Throughput (idle, lab Vulkan):** PP 1,275 tok/s · TG 82.2 tok/s

### Interleaving — lohnt sich np=2?

| Szenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (Referenz) | 12.7 | 77.7 | — | — |
| 02 blocked (np=1, schlecht) | 12.8 | 78.1 | 62.8 | 26,629 ⚠ |
| 03 interleave (np=2) | 12.6 | 79.5 | 63.3 | 52.0 |

→ **Interleaving:** Prefill-TTFT **512× schneller** als blocked (26,629 ms → 52.0 ms). Decode bleibt ~12.6 ms.

### ub-Sweep — beste Batch-Größe unter Last

Getestet mit Szenario 03 (Decode + 4k-Prefill parallel). **Ziel:** niedrige Decode-Latenz + hoher Prefill-Durchsatz + niedrige TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 256 | 12.5 | 79.7 | 63.8 | 44.2 | **★ best** |
| 128 | 12.6 | 79.6 | 63.3 | 46.3 |  |
| 64 | 12.6 | 79.2 | 64.1 | 98.2 |  |

→ **Empfehlung:** `ub = 256`

### np-Sweep — parallele Slots (ub=128 fix)

Szenario 03 unter Last.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 2 | 12.6 | 79.5 | 63.7 | 96.2 | **★ best** |
| 4 | 12.7 | 78.8 | 64.4 | 45.5 |  |

→ **Empfehlung:** `np = 2`

## Qwen3.6-35B-A3B-MTP-UD-Q4_K_M

### Interleaving — lohnt sich np=2?

| Szenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (Referenz) | 66.3 | 28.2 | — | — |
| 02 blocked (np=1, schlecht) | 32.0 | 91.7 | 46.5 | 297.4 |
| 03 interleave (np=2) | 32.6 | 88.2 | 78.3 | 300.3 |

### ub-Sweep — beste Batch-Größe unter Last

Getestet mit Szenario 03 (Decode + 4k-Prefill parallel). **Ziel:** niedrige Decode-Latenz + hoher Prefill-Durchsatz + niedrige TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 128 | 31.1 | 88.6 | 76.2 | 317.8 | **★ best** |
| 256 | 32.2 | 88.9 | 81.2 | 328.0 |  |
| 64 | 32.3 | 84.4 | 73.2 | 401.4 |  |

→ **Empfehlung:** `ub = 128`

### np-Sweep — parallele Slots (ub=128 fix)

Szenario 03 unter Last.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 2 | 32.4 | 86.9 | 80.0 | 278.7 | **★ best** |

→ **Empfehlung:** `np = 2`

### ctx-Sweep — Kontext vs VRAM

Szenario 01 solo pro ctx.

| c | Decode ms | Decode tok/s | VRAM MB | |
| --- | ---: | ---: | ---: | --- |
| 16384 | 32.0 | 71.0 | — |  |
| 32768 | 32.4 | 84.0 | — |  |
| 65536 | 32.7 | 87.2 | — |  |
| 131072 | 33.0 | 85.5 | — |  |
| 262144 | 32.3 | 84.6 | — | **★ best** |

→ **Empfehlung:** `c = 262144`

### cont-batching — an vs. aus

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 428.3 | 74.6 | 32.1 | 77.9 | 388.1 |
| aus (--no-cont-batching) | 409.5 | 73.5 | 32.4 | 72.8 | 376.1 |

→ **Empfehlung:** cont-batching **on**

## Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL

### Interleaving — lohnt sich np=2?

| Szenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (Referenz) | 32.3 | 84.3 | — | — |
| 02 blocked (np=1, schlecht) | 32.6 | 87.3 | 81.1 | 42,650 ⚠ |
| 03 interleave (np=2) | 32.8 | 86.6 | 78.8 | 286.4 |

→ **Interleaving:** Prefill-TTFT **149× schneller** als blocked (42,650 ms → 286.4 ms). Decode bleibt ~32.8 ms.

### ub-Sweep — beste Batch-Größe unter Last

Getestet mit Szenario 03 (Decode + 4k-Prefill parallel). **Ziel:** niedrige Decode-Latenz + hoher Prefill-Durchsatz + niedrige TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 64 | 32.1 | 85.6 | 83.1 | 365.4 | **★ best** |
| 256 | 32.3 | 88.9 | 77.3 | 343.8 |  |
| 128 | 32.6 | 87.3 | 78.5 | 297.4 |  |

→ **Empfehlung:** `ub = 64`

### np-Sweep — parallele Slots (ub=128 fix)

Szenario 03 unter Last.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 4 | 32.1 | 86.6 | 74.9 | 274.0 | **★ best** |
| 2 | 32.6 | 87.3 | 82.5 | 333.6 |  |

→ **Empfehlung:** `np = 4`

### ctx-Sweep — Kontext vs VRAM

Szenario 01 solo pro ctx.

| c | Decode ms | Decode tok/s | VRAM MB | |
| --- | ---: | ---: | ---: | --- |
| 16384 | 31.6 | 74.3 | — |  |
| 32768 | 33.1 | 82.0 | — |  |
| 65536 | 32.2 | 85.4 | — |  |
| 131072 | 32.8 | 83.0 | — |  |
| 262144 | 32.7 | 86.8 | — | **★ best** |

→ **Empfehlung:** `c = 262144`

### cont-batching — an vs. aus

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 425.4 | 87.2 | 32.8 | 82.5 | 388.9 |
| aus (--no-cont-batching) | 397.5 | 68.7 | 32.5 | 77.9 | 363.1 |

→ **Empfehlung:** cont-batching **on**

## Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL

### Interleaving — lohnt sich np=2?

| Szenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (Referenz) | 35.8 | 76.2 | — | — |
| 02 blocked (np=1, schlecht) | 35.6 | 79.4 | 72.3 | 46,055 ⚠ |
| 03 interleave (np=2) | 36.1 | 76.2 | 76.8 | 273.1 |

→ **Interleaving:** Prefill-TTFT **169× schneller** als blocked (46,055 ms → 273.1 ms). Decode bleibt ~36.1 ms.

### ub-Sweep — beste Batch-Größe unter Last

Getestet mit Szenario 03 (Decode + 4k-Prefill parallel). **Ziel:** niedrige Decode-Latenz + hoher Prefill-Durchsatz + niedrige TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 256 | 35.4 | 80.0 | 71.8 | 343.9 | **★ best** |
| 64 | 35.7 | 80.2 | 69.0 | 397.1 |  |
| 128 | 35.9 | 79.5 | 69.3 | 349.8 |  |

→ **Empfehlung:** `ub = 256`

### np-Sweep — parallele Slots (ub=128 fix)

Szenario 03 unter Last.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 2 | 35.1 | 81.2 | 73.9 | 296.4 | **★ best** |
| 4 | 35.9 | 78.8 | 75.1 | 239.3 |  |

→ **Empfehlung:** `np = 2`

### ctx-Sweep — Kontext vs VRAM

Szenario 01 solo pro ctx.

| c | Decode ms | Decode tok/s | VRAM MB | |
| --- | ---: | ---: | ---: | --- |
| 16384 | 35.5 | 70.8 | — |  |
| 32768 | 36.0 | 78.1 | — |  |
| 65536 | 35.5 | 79.3 | — |  |
| 131072 | 36.0 | 78.7 | — |  |
| 262144 | 35.9 | 76.9 | — | **★ best** |

→ **Empfehlung:** `c = 262144`

### cont-batching — an vs. aus

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 127.4 | 79.1 | 35.8 | 72.2 | 397.3 |
| aus (--no-cont-batching) | 385.2 | 72.0 | 35.8 | 70.8 | 403.7 |

→ **Empfehlung:** cont-batching **off**

## Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL

### Interleaving — lohnt sich np=2?

| Szenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (Referenz) | 35.6 | 79.3 | — | — |
| 02 blocked (np=1, schlecht) | 35.3 | 79.1 | 73.0 | 46,517 ⚠ |
| 03 interleave (np=2) | 36.4 | 75.0 | 73.7 | 259.7 |

→ **Interleaving:** Prefill-TTFT **179× schneller** als blocked (46,517 ms → 259.7 ms). Decode bleibt ~36.4 ms.

### ub-Sweep — beste Batch-Größe unter Last

Getestet mit Szenario 03 (Decode + 4k-Prefill parallel). **Ziel:** niedrige Decode-Latenz + hoher Prefill-Durchsatz + niedrige TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 256 | 35.5 | 80.2 | 71.7 | 350.9 | **★ best** |
| 128 | 35.5 | 79.9 | 72.7 | 369.5 |  |
| 64 | 35.6 | 79.6 | 69.4 | 405.1 |  |

→ **Empfehlung:** `ub = 256`

### np-Sweep — parallele Slots (ub=128 fix)

Szenario 03 unter Last.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 4 | 35.7 | 78.7 | 72.7 | 293.3 | **★ best** |
| 2 | 35.8 | 79.0 | 75.0 | 322.4 |  |

→ **Empfehlung:** `np = 4`

### ctx-Sweep — Kontext vs VRAM

Szenario 01 solo pro ctx.

| c | Decode ms | Decode tok/s | VRAM MB | |
| --- | ---: | ---: | ---: | --- |
| 16384 | 36.1 | 73.8 | — |  |
| 32768 | 35.4 | 83.4 | — |  |
| 65536 | 35.4 | 72.5 | — |  |
| 131072 | 36.2 | 76.9 | — |  |
| 262144 | 36.0 | 76.3 | — | **★ best** |

→ **Empfehlung:** `c = 262144`

### cont-batching — an vs. aus

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 345.9 | 83.2 | 35.2 | 75.9 | 380.1 |
| aus (--no-cont-batching) | 350.6 | 78.6 | 35.8 | 71.1 | 380.6 |

→ **Empfehlung:** cont-batching **on**

## Qwen3.8-27B-Q4_K_M-MTP

### Interleaving — lohnt sich np=2?

| Szenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (Referenz) | 129.4 | 20.3 | — | — |
| 02 blocked (np=1, schlecht) | 134.7 | 20.6 | 15.4 | 72,644 ⚠ |
| 03 interleave (np=2) | 134.2 | 18.3 | 22.3 | 509.6 |

→ **Interleaving:** Prefill-TTFT **143× schneller** als blocked (72,644 ms → 509.6 ms). Decode bleibt ~134.2 ms.

### ub-Sweep — beste Batch-Größe unter Last

Getestet mit Szenario 03 (Decode + 4k-Prefill parallel). **Ziel:** niedrige Decode-Latenz + hoher Prefill-Durchsatz + niedrige TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 128 | 130.8 | 23.9 | 16.9 | 619.0 | **★ best** |
| 256 | 131.9 | 17.1 | 19.7 | 630.4 |  |
| 64 | 132.1 | 18.5 | 18.2 | 694.3 |  |

→ **Empfehlung:** `ub = 128`

### np-Sweep — parallele Slots (ub=128 fix)

Szenario 03 unter Last.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 4 | 131.6 | 23.7 | 19.1 | 527.2 | **★ best** |
| 2 | 132.4 | 22.2 | 15.1 | 581.0 |  |

→ **Empfehlung:** `np = 4`

### ctx-Sweep — Kontext vs VRAM

Szenario 01 solo pro ctx.

| c | Decode ms | Decode tok/s | VRAM MB | |
| --- | ---: | ---: | ---: | --- |
| 16384 | 129.6 | 24.0 | — |  |
| 32768 | 129.9 | 15.8 | — |  |
| 65536 | 129.0 | 23.0 | — |  |
| 131072 | 127.2 | 22.2 | — |  |
| 262144 | 129.5 | 24.0 | — | **★ best** |

→ **Empfehlung:** `c = 262144`

### cont-batching — an vs. aus

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 59.8 | 18.4 | 131.6 | 19.1 | 678.4 |
| aus (--no-cont-batching) | 239.4 | 23.6 | 131.6 | 16.1 | 667.5 |

→ **Empfehlung:** cont-batching **off**

## Qwen3.8-27B-Q4_K_M-MTP-VL

### Interleaving — lohnt sich np=2?

| Szenario | Decode ms/token | Decode tok/s | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: |
| 01 solo (Referenz) | 129.6 | 22.1 | — | — |
| 02 blocked (np=1, schlecht) | 131.9 | 20.7 | 18.1 | 71,838 ⚠ |
| 03 interleave (np=2) | 134.4 | 20.6 | 19.4 | 495.5 |

→ **Interleaving:** Prefill-TTFT **145× schneller** als blocked (71,838 ms → 495.5 ms). Decode bleibt ~134.4 ms.

### ub-Sweep — beste Batch-Größe unter Last

Getestet mit Szenario 03 (Decode + 4k-Prefill parallel). **Ziel:** niedrige Decode-Latenz + hoher Prefill-Durchsatz + niedrige TTFT.

| ub | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 64 | 130.6 | 21.1 | 16.9 | 698.8 | **★ best** |
| 128 | 130.7 | 20.1 | 22.7 | 641.5 |  |
| 256 | 131.8 | 17.8 | 16.2 | 612.5 |  |

→ **Empfehlung:** `ub = 64`

### np-Sweep — parallele Slots (ub=128 fix)

Szenario 03 unter Last.

| np | Decode ms | Decode tok/s | Prefill tok/s | Prefill TTFT | |
| --- | ---: | ---: | ---: | ---: | --- |
| 4 | 131.2 | 18.4 | 20.6 | 490.4 | **★ best** |
| 2 | 132.5 | 20.1 | 18.9 | 528.8 |  |

→ **Empfehlung:** `np = 4`

### ctx-Sweep — Kontext vs VRAM

Szenario 01 solo pro ctx.

| c | Decode ms | Decode tok/s | VRAM MB | |
| --- | ---: | ---: | ---: | --- |
| 16384 | 130.1 | 17.9 | — |  |
| 32768 | 129.6 | 22.9 | — |  |
| 65536 | 129.7 | 19.0 | — |  |
| 131072 | 129.5 | 22.2 | — |  |
| 262144 | 129.8 | 22.1 | — | **★ best** |

→ **Empfehlung:** `c = 262144`

### cont-batching — an vs. aus

| Modus | PP tok/s | TG tok/s | Decode ms | Prefill tok/s | Prefill TTFT |
| --- | ---: | ---: | ---: | ---: | ---: |
| an (cont-batching) | 237.7 | 20.9 | 130.2 | 18.0 | 700.6 |
| aus (--no-cont-batching) | 233.9 | 19.9 | 133.8 | 18.4 | 710.1 |

→ **Empfehlung:** cont-batching **on**
