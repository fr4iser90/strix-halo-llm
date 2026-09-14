# GitHub Pages (benchmark results only)

Static site — **measured benches** with a short overview plus detail pages:

- `index.html` — Overview (at a glance, speed, throughput, HumanEval)
- `context.html` — Context & memory
- `quality.html` — Code correctness
- `host.html` — Hardware & build fingerprint

Recommendation planner / apply-ini stay on the bench host (`output/bench/`), not here.

## Enable once (this repo or a fork)

1. GitHub → **Settings → Pages**
2. **Build and deployment → Source:** **Deploy from a branch**
3. Branch: **`main`** → folder **`/docs`** → **Save**

Do **not** pick “GitHub Actions” unless you add your own Actions workflow. Publishing is: commit `docs/` on `main`; Pages serves that folder.

```bash
./bench publish
git add docs
git commit -m "docs: refresh bench dashboard"
git push
```

Site URL (typical): `https://<user>.github.io/<repo>/`  
(e.g. `https://fr4iser90.github.io/strix-halo-llm/`)
