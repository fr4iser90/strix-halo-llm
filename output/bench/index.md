# Bench — Dashboard

**Start hier.** Hardware zuerst (Vergleichbarkeit), dann Empfehlungen, unten Historie.

## Hardware

Compare results only across similar RAM/GTT/backends. [host.json](host.json)

| | |
|---|---|
| Host | Gaming |
| OS | NixOS 26.05 (Yarara) |
| Kernel | 7.1.5 |
| CPU | Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz (16 threads) |
| RAM | 31.2 GiB (avail ~13.2 GiB) |
| Swap | 7.8 GiB |
| GTT (UMA) | 15.6 GiB (used ~0.7 GiB) |
| Visible VRAM | 8176 MiB |
| GPU | 03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 23 [Radeon RX 6600/6600 XT/6600M] (rev c7) |
| Backend | vulkan |
| Image | llama-cpp-vulkan-nix:latest (`—`) |
| llama.cpp | — @ `—` |
| Probed | 2026-09-13T11:11:41Z |

> AMD Strix Halo / unified memory: GTT is the GPU-usable UMA pool (not discrete VRAM). Compare benches only across similar GTT/RAM.

## Scheduling — welches `ub`? (np=2, Decode niedrig halten)

Decode-Latenz + Prefill-Durchsatz **unter Last**. [Details →](scheduling/latest/compare.html)

*Noch keine Scheduling-Empfehlungen — `./bench sched --auto`*

## Throughput — welches Modell ist am schnellsten?

[Details →](throughput/latest/compare.html) · PP = Prompt tok/s · TG = Generation tok/s · **höher = besser**

*Noch kein Throughput-Bench — `./bench throughput --lab --vulkan`*

## Quality — task correctness

*Noch keine Quality-Runs — `./bench quality humaneval --setup` dann `./bench quality humaneval --model … --limit 10`*

## Capacity — KV×ctx / dual-256k

*Noch keine Capacity-Runs — `./bench capacity kv-ctx` oder `./bench matrix --profile full`*

## Matrix — long-run status

*Kein Matrix-Lauf — Profiles: `default` (empfohlen) / `full` (Mehrtage). `./bench matrix --profile full --dry-run`*

---

<details>
<summary>Run-Historie (Rohdaten)</summary>

### Throughput-Läufe

| Zeit | Stamp | Suite | Backends |
| --- | --- | --- | --- |
| — | — | — | — |

### Scheduling-Läufe

| Zeit | Modell | Szenarien | Ordner |
| --- | --- | --- | --- |
| — | — | — | — |

</details>

Neu bauen: `./bench index`
