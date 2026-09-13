# Matrix orchestrator

Configurable multi-suite runs. Edit JSON profiles — no code changes needed for new dims.

| Profile | Path | Intent |
|---------|------|--------|
| `default` | `profiles/default.json` | Capacity + dual (auto-skip if RAM/GTT low) + sched auto/ub/np |
| `full` | `profiles/full.json` | Multi-day: solo capacity + all sched + throughput + HumanEval (**no dual**) |

```bash
./bench matrix --profile full --dry-run
./bench matrix --profile full --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B
./bench matrix --profile full --no-vl
tmux new -s bench './bench matrix --profile full'
./bench matrix status
./bench matrix --profile full --only capacity
./bench matrix --profile full --skip-suite quality
```

Dual is optional (2 stickys): run `./bench capacity dual …`, use `--profile default`, or set
`suites.capacity.dual.enabled: true` in a profile. Host gate:
`skip_below_ram_gib` / `skip_below_gtt_gib` (CLI `--skip-dual` / `--force-dual`).

Progress: `output/bench/matrix/progress.json` + live capacity cells in
`output/bench/capacity/progress.json` (`./bench matrix status`).

See also [`../ROADMAP.md`](../ROADMAP.md) and [`../README.md`](../README.md) (model filter).
