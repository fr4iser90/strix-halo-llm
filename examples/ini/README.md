# Example INIs (committed)

Live presets at the repo root are **gitignored** so your machine config is never overwritten by `git pull`:

| Live (local) | Role |
|---|---|
| `models.ini` | Sticky chat `:11535` |
| `models-coder.ini` | Sticky coder `:11538` |
| `models-lab.ini` | Lab pool — **from disk** via sync |
| `models-embeddings.ini` / `models-extractor.ini` | Side routers |
| `models-bench.ini` (+ `-b`) | Capacity — **from sync_from** |

## First setup (fork / new machine)

```bash
cp examples/ini/models.ini examples/ini/models-coder.ini .
# edit sticky section names/paths to match YOUR GGUFs under ./models/
./bench sync-models          # lab + emb + extractor from ./models/ (+ VL twins)
./bench capacity sync --from coder,chat,lab
```

Or only:

```bash
./bench sync-models   # copies missing sticky files from examples/ini/ then scans disk
```

## VL

`./bench sync-models` adds a `…-VL` twin (with `mmproj=…`) whenever a matching mmproj GGUF exists for that weight — including models that were already in `models-lab.ini` without VL.

Sticky chat/coder are **not** auto-filled with every VL; pick one sticky section yourself (copy a `-VL` block from lab if you want vision on `:11535`).
