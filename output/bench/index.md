# Bench — Dashboard

**Start here.** Hardware first (comparability), then recommendations, history below.

## Hardware

Compare results only across similar RAM/GTT/backends. [host.json](host.json)

| | |
|---|---|
| Host | Gaming |
| OS | NixOS 26.05 (Yarara) |
| Kernel | 7.1.5 |
| CPU | Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz (16 threads) |
| RAM | 31.2 GiB (avail ~16.4 GiB) |
| Swap | 7.8 GiB |
| GTT (UMA) | 15.6 GiB (used ~0.3 GiB) |
| Visible VRAM | 8176 MiB |
| GPU | 03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 23 [Radeon RX 6600/6600 XT/6600M] (rev c7) |
| Backend | vulkan |
| Image | llama-cpp-vulkan-nix:latest (`—`) |
| llama.cpp | — @ `—` |
| Probed | 2026-09-14T15:45:15Z |

> AMD Strix Halo / unified memory: GTT is the GPU-usable UMA pool (not discrete VRAM). Compare benches only across similar GTT/RAM.

## Scheduling — which `ub`? (np=2, keep decode low)

Decode latency + prefill throughput **under load**. [Details →](scheduling/latest/compare.html)

*No scheduling recommendations yet — `./bench sched --auto`*

## Throughput — which model is fastest?

[Details →](throughput/latest/compare.html) · PP = Prompt tok/s · TG = Generation tok/s · **higher = better**

*No throughput bench yet — `./bench throughput --lab --vulkan`*

## Quality — task correctness

*No quality runs yet — `./bench quality humaneval --setup` then `./bench quality humaneval --model … --limit 10`*

## Capacity — KV×ctx / dual

*No capacity runs yet — `./bench capacity kv-ctx` / `dual` or `./bench matrix --profile full`*

## Matrix — long-run status

*No matrix run yet — profiles: `default` (recommended) / `full` (multi-day). `./bench matrix --profile full --dry-run`*

---

<details>
<summary>Run history (raw)</summary>

### Throughput runs

| When | Stamp | Suite | Backends |
| --- | --- | --- | --- |
| — | — | — | — |

### Scheduling runs

| When | Model | Scenarios | Folder |
| --- | --- | --- | --- |
| — | — | — | — |

</details>

Neu bauen: `./bench index`
