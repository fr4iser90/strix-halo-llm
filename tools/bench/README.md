# Bench toolkit

**Ein CLI:** `./bench`

| Was | Pfad | Aufgabe |
|-----|------|---------|
| **`./bench`** | Root | `throughput`, `sched`, `capacity`, `matrix`, `quality`, `index`, `publish` |
| `./bench matrix` | `tools/bench/matrix/` | Multi-Suite Orchestrator (`default` / `full`) |
| `./bench capacity` | `tools/bench/capacity/` | KV×ctx + dual (c auto) |
| `./bench quality` | `tools/bench/quality/` | HumanEval Plugins |
| `./bench publish` | `tools/bench/publish-docs.sh` | → `docs/` GitHub Pages |

## Full matrix (Mehrtage)

Zuerst INIs an Disk anpassen, dann Matrix:

```bash
./bench sync-models --dry-run      # was würde sich ändern?
./bench sync-models                # lab/emb/extractor aus ./models/
./bench sync-models --touch-sticky # optional: tote sticky sections weg
./bench capacity sync --from coder,chat,lab
./bench matrix --profile full --dry-run
tmux new -s bench './bench matrix --profile full'
```

Profiles: `tools/bench/matrix/profiles/{default,full}.json` — alles editierbar.

**Output cleanen?** Meist **nein**. Skip/Fingerprint lassen Lücken nach. Nur wenn du wirklich bei Null starten willst:

```bash
rm -f output/bench/capacity/cells.jsonl
# optional große Rohläufe:
# rm -rf output/bench/scheduling/20* output/bench/capacity/20*
```

Alte Results zu gelöschten Modellen stören nicht (nur Index-Noise).
## Capacity

Auto-sync aus `models-coder.ini` + `models.ini` (+ optional lab). Skip inkl. llama.cpp Fingerprint.

```bash
./bench capacity kv-ctx
./bench capacity fingerprint
./bench capacity stale
```

## GPU / Isolation

| Modus | Verhalten |
|-------|-----------|
| `capacity` / `matrix` capacity | Stickys gestoppt, bench-a/b, Restore |
| `sched` | Lab, Daily aus |
| `throughput` | alle Router aus |
| `quality` | laufender Server |

## Befehle

```bash
./bench matrix --profile full
./bench capacity kv-ctx --from coder
./bench sched --auto
./bench quality humaneval --setup
./bench index && ./bench publish
```
