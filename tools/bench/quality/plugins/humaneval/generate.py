#!/usr/bin/env python3
"""Generate HumanEval completions via OpenAI-compatible servers (llama / gufo / halogen).

HumanEval expects *only* the function-body continuation concatenated onto the
prompt. Gufo/chat models often:
  - omit the leading 4-space indent on the first body line → IndentationError
  - wrap code in markdown fences or <think> blocks
  - put the answer in reasoning_content while content is empty
  - ignore server-side stop sequences

This module normalizes those cases before writing samples.jsonl.
"""
from __future__ import annotations

import json
import os
import re
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

# Codex / HumanEval stop strings (also applied client-side).
STOP_STRINGS = ["\nclass", "\ndef", "\n#", "\nif", "\nprint", "\n@", "\n```"]


def env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None or v == "":
        raise SystemExit(f"missing env {name}")
    return v


def body_indent(prompt: str) -> str:
    """Indentation expected for the first line of the function body."""
    for line in reversed(prompt.splitlines()):
        if not line.strip():
            continue
        leading = len(line) - len(line.lstrip(" "))
        stripped = line.lstrip()
        if stripped.startswith("def ") or stripped.startswith("async def "):
            return " " * (leading + 4)
        if '"""' in line or "'''" in line:
            return " " * leading if leading else "    "
        if leading > 0:
            return " " * leading
        break
    return "    "


def strip_think(text: str) -> str:
    text = re.sub(
        r"<think>.*?</think>",
        "",
        text,
        flags=re.DOTALL | re.IGNORECASE,
    )
    text = re.sub(
        r"<\|?think\|?>.*?<\|/?think\|?>",
        "",
        text,
        flags=re.DOTALL | re.IGNORECASE,
    )
    return text


def strip_markdown_fence(text: str) -> str:
    text = text.strip()
    m = re.search(
        r"```(?:python|py)?\s*\n(.*?)```",
        text,
        flags=re.DOTALL | re.IGNORECASE,
    )
    if m:
        return m.group(1)
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        return "\n".join(lines)
    return text


def apply_stops(text: str) -> str:
    cut = len(text)
    for stop in STOP_STRINGS:
        idx = text.find(stop)
        if idx != -1 and idx < cut:
            cut = idx
    return text[:cut]


def fix_leading_indent(completion: str, prompt: str) -> str:
    """Prepend function-body indent when the first code line starts at column 0."""
    if not completion:
        return completion
    indent = body_indent(prompt)
    text = completion.replace("\r\n", "\n").replace("\r", "\n")
    lead_nl = text.startswith("\n")
    body = text[1:] if lead_nl else text
    if not body.strip():
        return completion
    nl = body.find("\n")
    first = body if nl < 0 else body[:nl]
    rest = "" if nl < 0 else body[nl:]
    if first.strip() and not first[:1].isspace():
        first = indent + first
        body = first + rest
    return ("\n" if lead_nl else "") + body


def sanitize_completion(raw: str, prompt: str) -> str:
    """Turn a raw model string into a HumanEval body continuation."""
    if not raw:
        return ""
    text = strip_think(raw)
    text = strip_markdown_fence(text)
    if text.startswith(prompt):
        text = text[len(prompt) :]
    for line in prompt.splitlines():
        if line.lstrip().startswith("def "):
            sig = line.strip()
            stripped = text.lstrip()
            if stripped.startswith(sig):
                idx = text.find(sig)
                text = text[idx + len(sig) :]
                if text.startswith("\n"):
                    text = text[1:]
            break
    text = apply_stops(text)
    if text.endswith("\n"):
        text = text.rstrip() + "\n"
    else:
        text = text.rstrip()
    return fix_leading_indent(text, prompt)


def message_text(choice: dict) -> str:
    """Prefer message.content; fall back to reasoning fields (Gufo)."""
    if choice.get("text"):
        return str(choice["text"])
    msg = choice.get("message") or {}
    content = msg.get("content") or ""
    if str(content).strip():
        return str(content)
    for key in ("reasoning_content", "reasoning", "thinking"):
        val = msg.get(key)
        if isinstance(val, str) and val.strip():
            return val
        if isinstance(val, dict):
            t = val.get("content") or val.get("text") or ""
            if str(t).strip():
                return str(t)
    return str(content or "")


def post_json(url: str, body: dict, timeout: float) -> dict:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def chat_completion(
    api: str,
    model: str,
    prompt: str,
    *,
    max_tokens: int,
    temperature: float,
    timeout: float,
) -> str:
    """Prefer /v1/completions (raw prompt); fall back to chat with thinking off."""
    url_comp = api.rstrip("/") + "/completions"
    body = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stop": STOP_STRINGS,
    }
    try:
        payload = post_json(url_comp, body, timeout)
        text = message_text(payload["choices"][0])
        return sanitize_completion(text or "", prompt)
    except urllib.error.HTTPError as e:
        if e.code not in (404, 400, 405):
            raise
    except Exception:
        pass

    url_chat = api.rstrip("/") + "/chat/completions"
    body_c = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": (
                    "Complete the following Python function. "
                    "Output ONLY the function body continuation "
                    "(preserve indentation, no markdown, no explanation).\n\n"
                    + prompt
                ),
            }
        ],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stop": STOP_STRINGS,
        "chat_template_kwargs": {"enable_thinking": False},
        "enable_thinking": False,
        "thinking": False,
    }
    payload = post_json(url_chat, body_c, timeout)
    text = message_text(payload["choices"][0])
    return sanitize_completion(text or "", prompt)


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
    empty = 0
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
            except Exception as exc:  # noqa: BLE001
                completion = f"# GENERATION_ERROR: {exc}\n"
                print(f"  ! {task_id}: {exc}", file=sys.stderr)
            if not (completion or "").strip():
                empty += 1
            samples.append({"task_id": task_id, "completion": completion})
            done += 1
            if done % 10 == 0 or done == total:
                elapsed = time.time() - t0
                print(f"  {done}/{total} ({elapsed:.0f}s) empty={empty}")

    out = os.path.join(run_dir, "samples.jsonl")
    write_jsonl(out, samples)
    meta = {
        "api": api,
        "model": model,
        "n_samples_per_task": n,
        "n_tasks": len(task_ids),
        "empty_completions": empty,
        "elapsed_s": round(time.time() - t0, 1),
    }
    with open(os.path.join(run_dir, "generate_meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print(f"✓ wrote {out} (empty={empty}/{total})")


if __name__ == "__main__":
    main()
