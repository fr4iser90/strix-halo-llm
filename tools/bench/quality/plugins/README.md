# Quality plugins

Each suite is a directory under `plugins/<name>/` with an executable `run.sh`.

## Policy

**Always `llama-bench-a` (`:11601`). Never sticky routers.** Stickys are stopped
for a clean GPU (same as capacity). Helpers: `tools/bench/quality/lib/server.sh`.

## Contract

`run.sh` receives CLI args from `./bench quality <name> …` and must:

1. Call `quality_bench_load "$MODEL"` (or rely on matrix owning the lifecycle with `--no-bench`).
2. Talk to `QUALITY_BASE_URL` (default `http://127.0.0.1:11601`).
3. Write results under:

```text
output/bench/quality/<name>/<stamp>/
├── summary.json     # required — machine-readable metrics
├── samples.jsonl    # optional — generations
└── …                # suite-specific artifacts
```

4. Exit non-zero on hard failure.

### `summary.json` schema (minimum)

```json
{
  "suite": "humaneval",
  "model": "Qwen3-Coder-…",
  "base_url": "http://127.0.0.1:11601/v1",
  "stamp": "20260913T120000Z",
  "n_tasks": 164,
  "n_samples_per_task": 1,
  "metrics": {
    "pass@1": 0.42
  },
  "notes": "optional"
}
```

After a run, refresh the merge table:

```bash
./bench quality compare
./bench publish
```

## Quants

Quality tests the **weight GGUF** named by the INI section (e.g. `…-UD-Q5_K_XL`).
It does **not** sweep KV cache types (`ctk`/`ctv`) — that is capacity’s job.
`models-bench.ini` usually keeps `ctk/ctv = q8_0` for quality loads.

## Add a new suite

```bash
cp -a tools/bench/quality/plugins/_template tools/bench/quality/plugins/mybench
# edit DESCRIPTION + run.sh — use quality_bench_load
./bench quality list
./bench quality mybench --help
```

Keep heavy datasets / vendor checkouts out of git (see `.gitignore` → `.vendor/`).

## Suites

| Name | What | Upstream |
|------|------|----------|
| `humaneval` | HumanEval pass@k | [openai/human-eval](https://github.com/openai/human-eval) |

`full` matrix already runs quality after capacity/sched/throughput.
Throughput / sched measure **speed**; quality measures **task correctness**.
