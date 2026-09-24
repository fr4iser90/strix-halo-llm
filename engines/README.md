# Engines — equal contract

Every engine has the **same** surface:

| Piece | Path |
|-------|------|
| Compose | `engines/<name>/compose.yaml` |
| Lifecycle adapter | `tools/bench/lib/engines/<id>.sh` (`prepare` / `cleanup` / `base_url` / optional `max_instances`, `stop_daily`, `start_bench`) |
| Start | `./stack up <name>` |
| Health | `./bench smoke <name>` |
| Measure | `./bench matrix --engine <id>` · LLMs also throughput/quality; audio → latency/RTF |

| Engine id | Port | Measure command |
|-----------|------|-----------------|
| `llama.cpp` | 11535+ | `./bench matrix --engine llama.cpp` (native suites) |
| `halogen-flash` | 8731 | `./bench matrix --engine halogen-flash` (HTTP LLM) |
| `gufo` | 8080 | `./bench matrix --engine gufo` (HTTP LLM) |
| `piper` | 9001 | `./bench audio --engine piper` · `./bench matrix --engine piper` |
| `whisper` | 9000 | `./bench audio --engine whisper` · `./bench matrix --engine whisper` |

**llama-only**: multi sticky/bench containers via adapter (`LLAMA_DAILY_SERVICES`, profile `bench`). **halogen/gufo**: `max_instances=1` (OOM / unknown). Overload: `ENGINE_MIN_FREE_RAM_GIB`, `ENGINE_FORCE_OVERLOAD=1`.

```bash
./stack up llama,halogen,piper,whisper
./bench smoke all
./bench matrix --engine halogen-flash
./bench matrix --engine piper
./bench audio --engine whisper
```
