# Bench toolkit

**One CLI:** `./bench`

| What | Path | Role |
|------|------|------|
| **`./bench`** | Root | `throughput`, `sched`, `capacity`, `matrix`, `quality`, `index`, `publish` |
| `./bench matrix` | `tools/bench/matrix/` | Multi-suite orchestrator (`default` / `full`) |
| `./bench capacity` | `tools/bench/capacity/` | KV×ctx + dual (`c` auto) |
| `./bench quality` | `tools/bench/quality/` | HumanEval plugins |
| `./bench publish` | `tools/bench/publish-docs.sh` | → `docs/` GitHub Pages |

## Full matrix (multi-day)

Align INIs with disk first, then run the matrix.

Live `models*.ini` files are **gitignored** (templates: `examples/ini/`). Copy/edit sticky presets once; lab is rebuilt from `./models/` (+ VL twins when mmproj exists).

```bash
cp examples/ini/models.ini examples/ini/models-coder.ini .   # only if missing
./bench sync-models --dry-run      # preview changes
./bench sync-models                # lab/emb/extractor (+ missing *-VL)
./bench sync-models --touch-sticky # optional: prune dead sticky sections
./bench capacity sync --from coder,chat,lab
./bench matrix --profile full --dry-run
tmux new -s bench './bench matrix --profile full'
```

Profiles: `tools/bench/matrix/profiles/{default,full}.json` — edit freely.

### Model filter

`--model` (comma list or repeatable) plus optional `--no-vl`. Match: exact section name **or** unique prefix/substring (non-VL preferred). Capacity ledger keeps skipping finished cells.

```bash
# 3-way text compare, full matrix:
./bench matrix --profile full \
  --model Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL,Cyber-Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL,Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL

# shorter when unambiguous:
./bench matrix --profile full --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B

# all text models, drop *-VL twins:
./bench matrix --profile full --no-vl

# capacity only:
./bench capacity kv-ctx --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B
./bench capacity dual   --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B
```

**Wipe outputs?** Usually **no**. Skip + fingerprint fill gaps on resume. Only reset if you truly want a clean slate:

```bash
rm -f output/bench/capacity/cells.jsonl
# optional large raw runs:
# rm -rf output/bench/scheduling/20* output/bench/capacity/20*
```

Old results for deleted models are harmless (index noise only).

**Progress:** Capacity logs `progress N/total runs_left R` and shows `ETA ~…` only after the first real run (`must-run × session wall-clock`). Skips do not count as work. Status:

```bash
./bench matrix status
# → capacity: 42/270 (15%)  runs_left 12  ETA ~1h20m
cat output/bench/capacity/progress.json
```

Nice-to-haves: [`ROADMAP.md`](ROADMAP.md).

After a matrix (or locally with existing `cells.jsonl` + sched summary):

```bash
./bench index                 # builds planner.html
# Browser: output/bench/planner.html  →  1 sticky / 2 stickys, download plan.json
./bench apply-ini --plan plan.json
./bench apply-ini --plan plan.json --dry-run
./bench publish               # Pages including planner
```

Pages = pick + snippet/plan; writing INIs is local-only via `apply-ini`.

## Capacity

Auto-sync from sticky/lab → `models-bench.ini`. Skip includes llama.cpp fingerprint.

```bash
./bench capacity kv-ctx
./bench capacity kv-ctx --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B
./bench capacity fingerprint
./bench capacity stale
```

## GPU / isolation

| Mode | Behavior |
|------|----------|
| `capacity` / `matrix` capacity | Stickys stopped, bench-a/b, then restore |
| `sched` | Lab on, daily off |
| `throughput` | All routers stopped |
| `quality` / `matrix` quality | Stickys stopped, **bench-a :11601**, then restore |

## Commands

```bash
./bench matrix --profile full
./bench matrix --profile full --model Tiel-Coder-35B,Cyber-Tiel,Qwen3.6-35B
./bench capacity kv-ctx --from coder --model Qwen3.6-35B
./bench sched --auto
./bench quality humaneval --model Tiel-Coder-35B-A3B-MTP-UD-Q5_K_XL
./bench quality humaneval --setup
./bench index && ./bench publish
```
