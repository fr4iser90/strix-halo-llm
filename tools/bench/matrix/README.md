# Matrix orchestrator

Configurable multi-suite runs. Edit JSON profiles — no code changes needed for new dims.

| Profile | Path | Intent |
|---------|------|--------|
| `default` | `profiles/default.json` | Capacity + dual sweet-spot + sched auto/ub/np |
| `full` | `profiles/full.json` | Everything, multi-day |

```bash
./bench matrix --profile full --dry-run
tmux new -s bench './bench matrix --profile full'
./bench matrix status
./bench matrix --profile full --only capacity
./bench matrix --profile full --skip-suite quality
```

Progress: `output/bench/matrix/progress.json` (also on Pages via `./bench publish`).
