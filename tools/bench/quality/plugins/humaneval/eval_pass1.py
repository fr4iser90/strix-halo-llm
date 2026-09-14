#!/usr/bin/env python3
"""Pass@1 evaluator without numpy (NixOS / broken venv numpy libstdc++).

Reads samples.jsonl, runs human_eval.execution.check_correctness, writes
samples.jsonl_results.jsonl and prints {"pass@1": …}.
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

from human_eval.data import read_problems, stream_jsonl, write_jsonl
from human_eval.execution import check_correctness


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: eval_pass1.py SAMPLES.jsonl [timeout]", file=sys.stderr)
        return 2
    samples_path = Path(sys.argv[1])
    timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
    if not samples_path.is_file():
        print(f"error: missing {samples_path}", file=sys.stderr)
        return 1

    problems = read_problems()
    results = []
    per_task: dict[str, list[bool]] = defaultdict(list)
    n = 0
    for sample in stream_jsonl(str(samples_path)):
        task_id = sample["task_id"]
        completion = sample["completion"]
        problem = problems[task_id]
        out = check_correctness(problem, completion, timeout)
        results.append({**sample, **out})
        per_task[task_id].append(bool(out.get("passed")))
        n += 1
        if n % 20 == 0:
            print(f"  evaluated {n}…", flush=True)

    out_path = str(samples_path) + "_results.jsonl"
    write_jsonl(out_path, results)

    # pass@1: fraction of tasks with at least one passing sample (n=1 → mean)
    if not per_task:
        print("{}")
        return 1
    passed_tasks = sum(1 for xs in per_task.values() if any(xs))
    pass1 = passed_tasks / len(per_task)
    metrics = {"pass@1": pass1}
    print(json.dumps(metrics))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
