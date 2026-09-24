# Throughput compare

engine: gufo

Gufo HTTP throughput (20260924T191458Z).

Definitions:

- **TTFT** — time to first token (ms, lower better). Cold = first request; warm = immediate repeat (cache may hit).
- **Prefill tok/s** — cold prompt processing ≈ fill_tokens / cold_TTFT (ladder: 512 4096 16384). Higher better.
- **Decode tok/s** — generation after first token (128 tok, once per model). Higher better.
- **ITL p50** — median inter-token latency during decode (ms, lower better).
- Rows are `model @fill` so each fill size is a separate compare line.

| model | ttft_cold_ms | ttft_warm_ms | prefill_tok_s | decode_tok_s | itl_p50_ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Qwen3.8-Flash-Next-UD-Q4_K_XL @512 | 524.62 | 15.04 | 836.57 | 25.93 | 37.29 |
| Qwen3.8-Flash-Next-UD-Q4_K_XL @4096 | 2009.66 | 17.69 | 1460.13 | 25.93 | 37.29 |
| Qwen3.8-Flash-Next-UD-Q4_K_XL @16384 | 7528.34 | 21.75 | 1553.83 | 25.93 | 37.29 |
