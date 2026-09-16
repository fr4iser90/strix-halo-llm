# Bench roadmap — nice-to-haves

Core suites (capacity / dual / sched / throughput / quality) cover “best sticky/lab
setup” decisions. Items below are polish — track here so they are not forgotten.

## Progress / UX

- [x] Capacity cell progress `N/total` + honest ETA (`runs_left × session wall`; omit ETA until first real run)
- [x] `./bench matrix status` shows capacity progress + ETA when available
- [x] `--model A,B,C` / `--no-vl` filter for capacity + matrix (sched/quality)
- [x] Goal-based `./bench` menu + `./bench recipes` (time estimates; dual marked optional)
- [x] Move `./bench sched` from lab `:11537` onto bench-a (same isolation as capacity/quality)
- [x] Throughput default suite = models-bench.ini (same model pool); stickys stopped like other benches
- [x] Naming: bench / lab / sticky only — no “real”/adjective wrappers that blur routers
- [x] Suite layout: `run.sh` + `lib/server.sh` + scenarios/plugins (throughput + capacity aligned)
- [ ] Suite-level ETA for sched / throughput / quality (after first samples)
- [ ] Live line on Pages dashboard (poll `matrix/progress.json`)

## Quality

- [ ] Subset filter (coder/Tiel only — skip pure VL/chat for HumanEval)
- [ ] Resume / skip completed `(suite, model)` like capacity ledger
- [ ] Second suite (e.g. MBPP) via `plugins/`
- [ ] Vision smoke (3 images prompt for `*-VL`)

## Capacity / dual

- [ ] True chat+coder dual (two different models), not only 2× same model
- [ ] Optional descending `c` ladder (fail-fast from high context)
- [x] Auto-skip dual when host RAM/GTT below thresholds (~64 / ~48 GiB); `--skip-dual` / `--force-dual`
- [x] `full` matrix omits dual (optional suite — `capacity dual` / profile `default`)

## Planner / apply

- [x] Auto-pick sticky_count=1|2 from host RAM/GTT + capacity dual into planner (high-mem → prefer 2; tight without dual → 1 only)
- [ ] Quality pass@1 as tie-breaker in planner catalogue

## Docs / forks

- [x] Live INIs gitignored; templates in `examples/ini/`
- [x] Engine dimension (`BENCH_ENGINE` / Halogen Flash) — tagged results + Pages engine tabs / Compare
- [x] Halogen full matrix (`full-halogen` / `./bench halogen matrix`) — HTTP capacity+sched+throughput+quality
- [x] Generic engine lifecycle (`lib/lifecycle.sh` + `lib/engines/*.sh`) — prepare/cleanup per engine; Halogen compose+stickys
- [x] Suite-primary layout — `*/backends/http.sh` + `lib/engines/*`; `halogen/` compat shim only
- [ ] One-page “first matrix” checklist on GitHub Pages index
