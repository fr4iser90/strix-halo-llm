# Bench toolkit

**One CLI:** `./bench` — start with `./bench` (menu) or `./bench recipes`.

| Goal | Time | Command |
|------|------|---------|
| **A. Fastest model (PP/TG)** | ~5–30 min | `./bench throughput --vulkan -m …` (default: models-bench.ini) |
| **B. Sticky feel (np/ub)** | ~1–4 h / model | `SCHED_MODEL=… ./bench sched --auto` |
| **C. Max context solo** | ~1–8 h | `./bench capacity kv-ctx --model …` |
| **D. Dual 2× servers** | ~2–12 h | optional — only if 2 stickys / ≥~64 GiB RAM |
| **E. HumanEval** | ~0.5–3 h / model | `./bench quality humaneval --model …` |
| **F. Full matrix** | multi-day | `./bench matrix --profile full` — solo capacity + sched + throughput + HumanEval (**no dual**) |

Most users only need **A** (and maybe **B**). Dual (**D**) is optional — not part of `full`; use `./bench capacity dual` or profile `default`.

| What | Path | Role |
|------|------|------|
| **`./bench`** | Root | menu / recipes / all suites |
| `./bench matrix` | `tools/bench/matrix/` | Multi-suite orchestrator (`--engine`) |
| `./bench capacity` | `tools/bench/capacity/` | KV×ctx + dual (`bench-a/b`) · `backends/http.sh` |
| `./bench sched` | `tools/bench/scheduling/` | np/ub under load · `backends/http.sh` |
| `./bench quality` | `tools/bench/quality/` | HumanEval (`--no-bench` for HTTP engines) |
| `./bench throughput` | `tools/bench/throughput/` | PP/TG llama-bench · `backends/http.sh` |
| `./bench publish` | `tools/bench/publish-docs.sh` | → `docs/` GitHub Pages |

**Layout (suite primary + engine adapter):**

```
tools/bench/
  capacity|scheduling|throughput|quality|matrix/   # suites (what you measure)
    backends/http.sh                                 # OpenAI HTTP path (halogen-flash, …)
  lib/engines/*.sh                                   # lifecycle adapters (prepare/cleanup)
  lib/{lifecycle,http_openai,engine}.sh              # shared
  halogen/                                           # compat shim → matrix/suites + --engine
```

**Routers:** sticky `:11535`/`:11538` · lab `:11537` (coexist) · bench `:11601`/`:11602` (capacity/quality/sched) · llama-bench one-shot (throughput) · Halogen Flash API `:8731` (`BENCH_ENGINE=halogen-flash`).

## Engines (unified `--engine` + lifecycle)

Same matrix profile for every runtime — pick the engine; lifecycle is per-adapter; HTTP suites use `*/backends/http.sh`:

```bash
# llama.cpp (bench-a) — default if --engine omitted
./bench matrix --profile full --engine llama.cpp --model Tiel-Coder-35B,Qwen3.6-35B

# Halogen Flash — auto compose up/down + stop/restore stickys
export HALOGEN_MODELS=~/Documents/halogen-flash-server/models   # weights dir (*.hgn + tokenizer/)
./bench matrix --profile full --engine halogen-flash              # model ids from /v1/models
./bench capacity http --engine halogen-flash
./bench throughput --engine halogen-flash
./bench sched --engine halogen-flash
```

| Env | Meaning |
|-----|---------|
| `HALOGEN_MODELS` | **Weights directory** for compose (not API model ids) |
| `--model` / `MATRIX_MODELS` | API model id(s) from `/v1/models` |
| `BENCH_ENGINE_SKIP_LIFECYCLE=1` | BYO server — no compose up/down |
| `BENCH_ENGINE_KEEP=1` | Leave engine containers up after bench |

**Add a new engine:**
1. `lib/engines/<id>.sh` → `engine_<prefix>_{prepare,cleanup,base_url}`
2. Register in `bench_engine_known` / `normalize` / `protocol` (`http` vs `native`)
3. If HTTP: reuse `*/backends/http.sh`; if native: extend suite `lib/server.sh`
4. Matrix: dispatch in `matrix/run.sh` (HTTP → `matrix/lib/http_matrix.sh`)

Priority: `--engine` > `BENCH_ENGINE=` > profile `"engine"` > `llama.cpp`.

After runs: `./bench index && ./bench publish` (engine tabs when ≥2 engines have data).

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
- **`full`**: solo capacity + sched + throughput + HumanEval — **dual off**
- **`default`**: capacity + dual (auto-skip below ~64 GiB RAM / ~48 GiB GTT) + sched
- Dual alone: `./bench capacity dual` (`CAPACITY_FORCE_DUAL=1` to override host gate)
### Model filter

`--model` (comma list or repeatable) plus optional `--no-vl`. Match: exact section name **or** unique prefix/substring (non-VL preferred). Capacity ledger keeps skipping finished cells. Throughput honors the same `--model` list.

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

**HumanEval:** `full` matrix auto-runs `./bench quality humaneval --setup` (venv under `output/bench/.venv-quality`), enables pass@1 eval, and **fails the matrix** if HumanEval fails (no silent skip).

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
./bench index                 # overview (= GitHub) + detail pages + ops.html
# Browser: output/bench/index.html       → Overview (same as Pages)
#          output/bench/context.html     → Context & memory
#          output/bench/quality.html     → Code correctness
#          output/bench/host.html        → Host & build
#          output/bench/ops.html         → operator (matrix / apply) — local only
#          output/bench/planner.html     → recommendations — local only
./bench apply-ini --plan plan.json
./bench apply-ini --plan plan.json --dry-run
./bench publish               # docs/ = Overview + detail pages (no ops / planner)
```

Pages = Overview + Context + Quality + Host (plus linked throughput/scheduling compares). Operator tools stay local (`ops.html`).

## Capacity

Auto-sync from sticky + `models-lab.ini` (disk catalog) → `models-bench.ini`. Skip includes llama.cpp fingerprint.

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
| `sched` / `matrix` sched | Stickys stopped, **bench-a :11601**, then restore (lab untouched; coexist suite uses lab explicitly) |
| `throughput` / `matrix` throughput | Stickys stopped, models-bench.ini → llama-bench, then restore |
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
