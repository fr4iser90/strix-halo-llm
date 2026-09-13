# Bench — Dashboard

**Start hier.** Oben die Empfehlungen, unten die Run-Historie.

## Scheduling — welches `ub`? (np=2, Decode niedrig halten)

Decode-Latenz + Prefill-Durchsatz **unter Last**. [Details →](scheduling/latest/compare.html)

| Modell | np ★ | ub ★ | b ★ | c ★ | cont-batch | Prefill tok/s | TG tok/s | PP an | PP aus | Decode ms | Interleave |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL | **2** | **256** | **64†** | **—** | on | 63.8 | 82.2 | — | — | 12.5 | 512× |
| Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | **2** | **128** | **64†** | **262144** | on ★ | 76.2 | — | 428.3 | 409.5 | 31.1 | — |
| Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | **4** | **64** | **64†** | **262144** | on ★ | 83.1 | — | 425.4 | 397.5 | 32.1 | 149× |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | **2** | **256** | **64†** | **262144** | off ★ | 71.8 | — | 127.4 | 385.2 | 35.4 | 169× |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | **4** | **256** | **64†** | **262144** | on ★ | 71.7 | — | 345.9 | 350.6 | 35.5 | 179× |
| Qwen3.8-27B-Q4_K_M-MTP | **4** | **128** | **64†** | **262144** | off ★ | 16.9 | — | 59.8 | 239.4 | 130.8 | 143× |
| Qwen3.8-27B-Q4_K_M-MTP-VL | **4** | **64** | **64†** | **262144** | on ★ | 16.9 | — | 237.7 | 233.9 | 130.6 | 145× |

† `b` (n_batch): Sweep **06_b_sweep** noch offen — aktuell Bench-Default **64**.

## Settings anwenden

```bash
./bench apply-ini --dry-run --lab   # Plan
./bench apply-ini --lab             # models-lab.ini (INI keys only)
docker compose --profile lab up -d llama-lab
```

Plan: [`scheduling/latest/apply-plan.json`](scheduling/latest/apply-plan.json)


## Throughput — welches Modell ist am schnellsten?

[Details →](throughput/latest/compare.html) · PP = Prompt tok/s · TG = Generation tok/s · **höher = besser**

| Modell | PP (512 tok) | TG (128 tok) |
| --- | ---: | ---: |
| Qwen3-Coder-30B-A3B-Q5_K_XL | 1275.1 | 82.2 |

## Quality — task correctness

*Noch keine Quality-Runs — `./bench quality humaneval --setup` dann `./bench quality humaneval --model … --limit 10`*

## Capacity — KV×ctx / dual-256k

*Noch keine Capacity-Runs — `docker compose -f compose.yaml -f compose.bench.yaml --profile bench up -d llama-bench-a` oder direkt `./bench capacity kv-ctx`*

## Matrix-Fortschritt

| Modell | Status | np ★ | ub ★ | b ★ | Decode ms |
| --- | --- | ---: | ---: | ---: | ---: |
| Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 2 | 256 | 64† | 12.5 |
| Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | auto ✓ · ub ✓ · np ✓ · b ⏳ | 2 | 128 | 64† | 31.1 |
| Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 4 | 64 | 64† | 32.1 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 2 | 256 | 64† | 35.4 |
| Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 4 | 256 | 64† | 35.5 |
| Qwen3.8-27B-Q4_K_M-MTP | auto ✓ · ub ✓ · np ✓ · b ⏳ | 4 | 128 | 64† | 130.8 |
| Qwen3.8-27B-Q4_K_M-MTP-VL | auto ✓ · ub ✓ · np ✓ · b ⏳ | 4 | 64 | 64† | 130.6 |

---

<details>
<summary>Run-Historie (Rohdaten)</summary>

### Throughput-Läufe

| Zeit | Stamp | Suite | Backends |
| --- | --- | --- | --- |
| 2026-09-06 14:28 UTC | `20260906T142802Z` | lab | vulkan |
| 2026-09-03 16:30 UTC | `20260903T163030Z` | lab | vulkan |
| 2026-09-03 16:22 UTC | `20260903T162233Z` | lab | vulkan |
| 2026-09-03 08:27 UTC | `20260903T082713Z` | lab | vulkan |
| 2026-09-03 00:57 UTC | `20260903T005706Z` | mix | vulkan |
| 2026-08-28 10:44 UTC | `20260828T104420Z` | lab | vulkan |
| 2026-08-19 12:10 UTC | `20260819T121046Z` | daily | vulkan |
| 2026-08-19 11:17 UTC | `20260819T111730Z` | daily | vulkan |
| 2026-08-19 10:51 UTC | `20260819T105144Z` | mix | vulkan |
| 2026-08-19 10:48 UTC | `20260819T104808Z` | daily | vulkan |
| 2026-08-19 10:46 UTC | `20260819T104653Z` | daily | vulkan |
| 2026-08-17 13:00 UTC | `20260817T130036Z` | heavy | rocm, vulkan |

### Scheduling-Läufe

| Zeit | Modell | Szenarien | Ordner |
| --- | --- | --- | --- |
| 2026-09-06 19:10 UTC |  | 11_coexist_capacity | [20260906T191051Z](scheduling/20260906T191051Z/) |
| 2026-09-06 14:53 UTC |  | — | [20260906T145352Z](scheduling/20260906T145352Z/) |
| 2026-09-06 14:46 UTC |  | 11_coexist_capacity | [20260906T144603Z](scheduling/20260906T144603Z/) |
| 2026-09-06 14:34 UTC | Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL | — | [20260906T143407Z](scheduling/20260906T143407Z/) |
| 2026-09-06 14:32 UTC | Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL | 04_ub_sweep | [20260906T143231Z](scheduling/20260906T143231Z/) |
| 2026-09-06 14:31 UTC | Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL | 05_np_sweep | [20260906T143105Z](scheduling/20260906T143105Z/) |
| 2026-09-06 14:29 UTC | Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL | 04_ub_sweep | [20260906T142938Z](scheduling/20260906T142938Z/) |
| 2026-09-06 14:28 UTC | Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260906T142834Z](scheduling/20260906T142834Z/) |
| 2026-08-28 13:54 UTC | Qwen3.8-27B-Q4_K_M-MTP-VL | 04_ub_sweep | [20260828T135446Z](scheduling/20260828T135446Z/) |
| 2026-08-28 13:52 UTC | Qwen3.8-27B-Q4_K_M-MTP | 04_ub_sweep | [20260828T135203Z](scheduling/20260828T135203Z/) |
| 2026-08-28 13:50 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 04_ub_sweep | [20260828T135014Z](scheduling/20260828T135014Z/) |
| 2026-08-28 13:46 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260828T134649Z](scheduling/20260828T134649Z/) |
| 2026-08-28 13:45 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 04_ub_sweep | [20260828T134520Z](scheduling/20260828T134520Z/) |
| 2026-08-28 13:43 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 04_ub_sweep | [20260828T134303Z](scheduling/20260828T134303Z/) |
| 2026-08-28 13:27 UTC | Qwen3.8-27B-Q4_K_M-MTP-VL | 09_fit_probe | [20260828T132718Z](scheduling/20260828T132718Z/) |
| 2026-08-28 13:26 UTC | Qwen3.8-27B-Q4_K_M-MTP-VL | 08_ctx_sweep | [20260828T132617Z](scheduling/20260828T132617Z/) |
| 2026-08-28 13:23 UTC | Qwen3.8-27B-Q4_K_M-MTP-VL | 07_cont_batch | [20260828T132307Z](scheduling/20260828T132307Z/) |
| 2026-08-28 13:22 UTC | Qwen3.8-27B-Q4_K_M-MTP | 09_fit_probe | [20260828T132241Z](scheduling/20260828T132241Z/) |
| 2026-08-28 13:21 UTC | Qwen3.8-27B-Q4_K_M-MTP | 08_ctx_sweep | [20260828T132134Z](scheduling/20260828T132134Z/) |
| 2026-08-28 13:15 UTC | Qwen3.8-27B-Q4_K_M-MTP | 07_cont_batch | [20260828T131520Z](scheduling/20260828T131520Z/) |
| 2026-08-28 13:14 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 09_fit_probe | [20260828T131455Z](scheduling/20260828T131455Z/) |
| 2026-08-28 13:14 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 08_ctx_sweep | [20260828T131403Z](scheduling/20260828T131403Z/) |
| 2026-08-28 13:11 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 07_cont_batch | [20260828T131154Z](scheduling/20260828T131154Z/) |
| 2026-08-28 13:11 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 09_fit_probe | [20260828T131134Z](scheduling/20260828T131134Z/) |
| 2026-08-28 13:10 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 08_ctx_sweep | [20260828T131040Z](scheduling/20260828T131040Z/) |
| 2026-08-28 13:07 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 07_cont_batch | [20260828T130716Z](scheduling/20260828T130716Z/) |
| 2026-08-28 13:06 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 09_fit_probe | [20260828T130658Z](scheduling/20260828T130658Z/) |
| 2026-08-28 13:06 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 08_ctx_sweep | [20260828T130611Z](scheduling/20260828T130611Z/) |
| 2026-08-28 13:04 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 07_cont_batch | [20260828T130419Z](scheduling/20260828T130419Z/) |
| 2026-08-28 13:04 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 09_fit_probe | [20260828T130401Z](scheduling/20260828T130401Z/) |
| 2026-08-28 13:03 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 08_ctx_sweep | [20260828T130314Z](scheduling/20260828T130314Z/) |
| 2026-08-28 13:01 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 07_cont_batch | [20260828T130123Z](scheduling/20260828T130123Z/) |
| 2026-08-28 12:51 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 07_cont_batch | [20260828T125107Z](scheduling/20260828T125107Z/) |
| 2026-08-28 12:44 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | — | [20260828T124417Z](scheduling/20260828T124417Z/) |
| 2026-08-28 12:39 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | — | [20260828T123950Z](scheduling/20260828T123950Z/) |
| 2026-08-28 12:20 UTC | Qwen3.8-27B-Q4_K_M-MTP-VL | 04_ub_sweep | [20260828T122042Z](scheduling/20260828T122042Z/) |
| 2026-08-28 12:18 UTC | Qwen3.8-27B-Q4_K_M-MTP-VL | 05_np_sweep | [20260828T121826Z](scheduling/20260828T121826Z/) |
| 2026-08-28 12:15 UTC | Qwen3.8-27B-Q4_K_M-MTP | 04_ub_sweep | [20260828T121557Z](scheduling/20260828T121557Z/) |
| 2026-08-28 12:12 UTC | Qwen3.8-27B-Q4_K_M-MTP | 05_np_sweep | [20260828T121256Z](scheduling/20260828T121256Z/) |
| 2026-08-28 12:11 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 04_ub_sweep | [20260828T121112Z](scheduling/20260828T121112Z/) |
| 2026-08-28 12:09 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 05_np_sweep | [20260828T120938Z](scheduling/20260828T120938Z/) |
| 2026-08-28 12:07 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260828T120755Z](scheduling/20260828T120755Z/) |
| 2026-08-28 12:04 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 05_np_sweep | [20260828T120411Z](scheduling/20260828T120411Z/) |
| 2026-08-28 12:02 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 04_ub_sweep | [20260828T120230Z](scheduling/20260828T120230Z/) |
| 2026-08-28 12:00 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 05_np_sweep | [20260828T120057Z](scheduling/20260828T120057Z/) |
| 2026-08-28 11:59 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 04_ub_sweep | [20260828T115919Z](scheduling/20260828T115919Z/) |
| 2026-08-28 11:56 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 05_np_sweep | [20260828T115654Z](scheduling/20260828T115654Z/) |
| 2026-08-28 11:55 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260828T115557Z](scheduling/20260828T115557Z/) |
| 2026-08-28 11:50 UTC | Qwen3.8-27B-Q4_K_M-MTP-VL | 04_ub_sweep | [20260828T115055Z](scheduling/20260828T115055Z/) |
| 2026-08-28 11:49 UTC | Qwen3.8-27B-Q4_K_M-MTP-VL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260828T114902Z](scheduling/20260828T114902Z/) |
| 2026-08-28 11:46 UTC | Qwen3.8-27B-Q4_K_M-MTP | 04_ub_sweep | [20260828T114632Z](scheduling/20260828T114632Z/) |
| 2026-08-28 11:44 UTC | Qwen3.8-27B-Q4_K_M-MTP | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260828T114403Z](scheduling/20260828T114403Z/) |
| 2026-08-28 11:42 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 04_ub_sweep | [20260828T114221Z](scheduling/20260828T114221Z/) |
| 2026-08-28 11:40 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL-VL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260828T114048Z](scheduling/20260828T114048Z/) |
| 2026-08-28 11:39 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 04_ub_sweep | [20260828T113905Z](scheduling/20260828T113905Z/) |
| 2026-08-28 11:36 UTC | Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260828T113619Z](scheduling/20260828T113619Z/) |
| 2026-08-28 11:34 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 04_ub_sweep | [20260828T113449Z](scheduling/20260828T113449Z/) |
| 2026-08-28 11:33 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M-VL | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260828T113346Z](scheduling/20260828T113346Z/) |
| 2026-08-28 11:32 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 04_ub_sweep | [20260828T113209Z](scheduling/20260828T113209Z/) |
| 2026-08-28 11:26 UTC | Qwen3.6-35B-A3B-MTP-UD-Q4_K_M | 01_baseline_solo, 02_blocked_np1, 03_interleave_np2 | [20260828T112647Z](scheduling/20260828T112647Z/) |

</details>

Neu bauen: `./bench index`
