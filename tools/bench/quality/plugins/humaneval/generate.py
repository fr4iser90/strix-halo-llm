#!/usr/bin/env python3
"""Generate HumanEval completions via OpenAI-compatible llama-server."""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

try:
    from human_eval.data import read_problems, write_jsonl
except ImportError as e:
    print(
        "error: human_eval not installed. Run: ./bench quality humaneval --setup",
        file=sys.stderr,
    )
    raise SystemExit(1) from e


def env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None or v == "":
        raise SystemExit(f"missing env {name}")
    return v


def chat_completion(
    api: str,
    model: str,
    prompt: str,
    *,
    max_tokens: int,
    temperature: float,
    timeout: float,
) -> str:
    """Prefer /v1/completions (raw prompt); fall back to chat."""
    url_comp = api.rstrip("/") + "/completions"
    body = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stop": ["\nclass", "\ndef", "\n#", "\nif", "\nprint"],
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url_comp,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode())
        choice = payload["choices"][0]
        text = choice.get("text")
        if text is None and "message" in choice:
            text = choice["message"].get("content", "")
        return text or ""
    except urllib.error.HTTPError as e:
        if e.code not in (404, 400, 405):
            raise
        # Chat fallback
        url_chat = api.rstrip("/") + "/chat/completions"
        body_c = {
            "model": model,
            "messages": [
                {
                    "role": "user",
                    "content": (
                        "Complete the following Python code. "
                        "Output only the continuation (no markdown).\n\n"
                        + prompt
                    ),
                }
            ],
            "max_tokens": max_tokens,
            "temperature": temperature,
        }
        req2 = urllib.request.Request(
            url_chat,
            data=json.dumps(body_c).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req2, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode())
        return payload["choices"][0]["message"]["content"] or ""


def main() -> None:
    api = env("QUALITY_API")
    model = env("QUALITY_MODEL")
    n = int(env("QUALITY_N", "1"))
    limit = int(env("QUALITY_LIMIT", "0"))
    max_tokens = int(env("QUALITY_MAX_TOKENS", "512"))
    temperature = float(env("QUALITY_TEMPERATURE", "0.2"))
    timeout = float(env("QUALITY_TIMEOUT", "120"))
    run_dir = env("QUALITY_RUN_DIR")

    problems = read_problems()
    task_ids = sorted(problems.keys())
    if limit > 0:
        task_ids = task_ids[:limit]

    samples: list[dict] = []
    total = len(task_ids) * n
    done = 0
    t0 = time.time()
    print(f"→ Generating {total} completions ({len(task_ids)} tasks × {n})…")

    for task_id in task_ids:
        prompt = problems[task_id]["prompt"]
        for _ in range(n):
            try:
                completion = chat_completion(
                    api,
                    model,
                    prompt,
                    max_tokens=max_tokens,
                    temperature=temperature,
                    timeout=timeout,
                )
            except Exception as exc:  # noqa: BLE001 — record failure, continue
                completion = f"# GENERATION_ERROR: {exc}\n"
                print(f"  ! {task_id}: {exc}", file=sys.stderr)
            # HumanEval expects completion only (no prompt echo)
            samples.append({"task_id": task_id, "completion": completion})
            done += 1
            if done % 10 == 0 or done == total:
                elapsed = time.time() - t0
                print(f"  {done}/{total} ({elapsed:.0f}s)")

    out = os.path.join(run_dir, "samples.jsonl")
    write_jsonl(out, samples)
    meta = {
        "api": api,
        "model": model,
        "n_samples_per_task": n,
        "n_tasks": len(task_ids),
        "elapsed_s": round(time.time() - t0, 1),
    }
    with open(os.path.join(run_dir, "generate_meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print(f"✓ wrote {out}")


if __name__ == "__main__":
    main()
