# GitHub Pages (bench dashboard)

Static site root. Enable once per fork:

1. Repo **Settings → Pages → Build and deployment**
2. Source: **Deploy from a branch**
3. Branch: `main` → folder **`/docs`** → Save

After benches on your machine:

```bash
./bench publish
git add docs
git commit -m "docs: refresh bench dashboard"
git push
```

`./bench publish` refreshes `host.json` (RAM, GTT, GPU, llama.cpp pin, image id)
and rebuilds `index.html` so results stay comparable across forks.

Workflow: `.github/workflows/pages.yml` deploys `docs/` on push (Actions must be allowed on the fork).
