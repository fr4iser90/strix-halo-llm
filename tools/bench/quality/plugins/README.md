# Quality plugins

Each suite is a directory under `plugins/<name>/` with an executable `run.sh`.

## Contract

`run.sh` receives CLI args from `./bench quality <name> …` and must:

1. Talk to a local OpenAI-compatible server (`QUALITY_BASE_URL`, default coder `:11538`).
2. Write results under:

```text
output/bench/quality/<name>/<stamp>/
├── summary.json     # required — machine-readable metrics
├── samples.jsonl    # optional — generations
└── …                # suite-specific artifacts
```

3. Exit non-zero on hard failure.

### `summary.json` schema (minimum)

```json
{
  "suite": "humaneval",
  "model": "Qwen3-Coder-…",
  "base_url": "http://127.0.0.1:11538/v1",
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

## Add a new suite

```bash
cp -a tools/bench/quality/plugins/_template tools/bench/quality/plugins/mybench
# edit DESCRIPTION + run.sh
./bench quality list
./bench quality mybench --help
```

Keep heavy datasets / vendor checkouts out of git (see `.gitignore` → `.vendor/`).

## Suites

| Name | What | Upstream |
|------|------|----------|
| `humaneval` | HumanEval pass@k | [openai/human-eval](https://github.com/openai/human-eval) |

Throughput (`./bench throughput`) and scheduling (`./bench sched`) stay separate — they measure **speed / latency**, quality plugins measure **task correctness**.
