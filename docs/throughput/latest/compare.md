# Throughput compare (multi-engine)

Per-engine snapshots: `latest/by-engine/<engine>/`.

Definitions:

- **TTFT** — time to first token (ms, lower better). Cold = first request; warm = immediate repeat.
- **Prefill tok/s** — prompt processing ≈ fill_tokens / warm_TTFT. Higher better.
- **Decode tok/s** — generation after first token. Higher better.
- **ITL p50** — median inter-token latency during decode (ms, lower better).

## llama.cpp

engine: llama.cpp

| model | ttft_cold_ms | ttft_warm_ms | prefill_tok_s | decode_tok_s | itl_p50_ms |
| --- | ---: | ---: | ---: | ---: | ---: |

## gufo

engine: gufo

| model | ttft_cold_ms | ttft_warm_ms | prefill_tok_s | decode_tok_s | itl_p50_ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Qwen3.8-Flash-Next-UD-Q4_K_XL @512 | 524.62 | 15.04 | 836.57 | 25.93 | 37.29 |
| Qwen3.8-Flash-Next-UD-Q4_K_XL @4096 | 2009.66 | 17.69 | 1460.13 | 25.93 | 37.29 |
| Qwen3.8-Flash-Next-UD-Q4_K_XL @16384 | 7528.34 | 21.75 | 1553.83 | 25.93 | 37.29 |

## halogen-flash

engine: halogen-flash

| model | ttft_cold_ms | ttft_warm_ms | prefill_tok_s | decode_tok_s | itl_p50_ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| qwen38-flash-next-w4b @512 | 6084.82 | 68.17 | 70.89 | 25.45 | 30.34 |
| qwen38-flash-next-w4b @4096 | 3995.55 | 76.66 | 734.03 | 25.45 | 30.34 |
| qwen38-flash-next-w4b @16384 | 15780.14 | 81.31 | 741.43 | 25.45 | 30.34 |
