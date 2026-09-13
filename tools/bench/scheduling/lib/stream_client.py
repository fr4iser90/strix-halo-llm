#!/usr/bin/env python3
"""Stream /v1/chat/completions and log SSE chunks with timestamps (JSONL)."""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request


def main() -> int:
    ap = argparse.ArgumentParser(description="llama-server streaming client for sched-bench")
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--label", default="slot")
    ap.add_argument("--prompt-file", required=True)
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.prompt_file, encoding="utf-8") as f:
        prompt = f.read()

    body = {
        "model": args.model,
        "stream": True,
        "max_tokens": args.max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        args.url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    t0 = time.perf_counter()

    def emit(event: str, **extra: object) -> None:
        rec = {"t": time.perf_counter(), "label": args.label, "event": event, **extra}
        out_f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        out_f.flush()

    try:
        with open(args.out, "w", encoding="utf-8") as out_f:
            emit("start", t0=t0)
            with urllib.request.urlopen(req, timeout=600) as resp:
                for raw in resp:
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line or not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        emit("done")
                        break
                    try:
                        obj = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    choices = obj.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    text = delta.get("content") or delta.get("reasoning_content")
                    if text:
                        emit("chunk", text=text)
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", errors="replace")
        print(f"HTTP {e.code}: {err}", file=sys.stderr)
        return 1
    except urllib.error.URLError as e:
        print(f"request failed: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
