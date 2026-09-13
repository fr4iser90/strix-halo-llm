# Bench roadmap — nice-to-haves

Core suites (capacity / dual / sched / throughput / quality) cover “best sticky/lab
setup” decisions. Items below are polish — track here so they are not forgotten.

## Progress / UX

- [x] Capacity cell progress `N/total` + honest ETA (`runs_left × session wall`; omit ETA until first real run)
- [x] `./bench matrix status` shows capacity progress + ETA when available
- [x] `--model A,B,C` / `--no-vl` filter for capacity + matrix (sched/quality)
- [ ] Suite-level ETA for sched / throughput / quality (after first samples)
- [ ] Live line on Pages dashboard (poll `matrix/progress.json`)

## Quality

- [ ] Subset filter (coder/Tiel only — skip pure VL/chat for HumanEval)
- [ ] Resume / skip completed `(suite, model)` like capacity ledger
- [ ] Second suite (e.g. MBPP) via `plugins/`
- [ ] Vision smoke (1 image prompt for `*-VL`)

## Capacity / dual

- [ ] True chat+coder dual (two different models), not only 2× same model
- [ ] Optional descending `c` ladder (fail-fast from high context)

## Planner / apply

- [ ] Auto-pick sticky_count=1|2 from capacity+sched into `plan.json`
- [ ] Quality pass@1 as tie-breaker in planner catalogue

## Docs / forks

- [x] Live INIs gitignored; templates in `examples/ini/`
- [ ] One-page “first matrix” checklist on GitHub Pages index
