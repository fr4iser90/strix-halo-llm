# GitHub Pages (benchmark results only)

Static site — **measured benches** with a short overview plus detail pages:

- `index.html` — Overview (at a glance, speed, throughput, HumanEval)
- `context.html` — Max context, prompt-cost chart, full KV grid
- `quality.html` — Code correctness
- `host.html` — Hardware & build fingerprint

Recommendation planner / apply-ini stay on the bench host (`output/bench/`), not here.

Enable once per fork:

1. Repo **Settings → Pages → Build and deployment**
2. Source: **Deploy from a branch** (not “GitHub Actions”)
3. Branch: `main` → folder **`/docs`** → Save

Site: https://\<user\>.github.io/\<repo\>/

```bash
./bench publish
git add docs
git commit -m "docs: refresh bench dashboard"
git push
```
