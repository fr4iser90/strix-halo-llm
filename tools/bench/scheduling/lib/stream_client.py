#!/usr/bin/env python3
"""Stream /v1/chat/completions and log SSE chunks with timestamps (JSONL).

Events:
  start   — request begin (t0)
  chunk   — content/reasoning delta
  timings — server timing object when present (llama.cpp / Gufo)
  done    — stream finished
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request


def _emit(out_f, event: str, **extra: object) -> None:
    rec = {"t": time.perf_counter(), "event": event, **extra}
    out_f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    out_f.flush()


def main() -> int:
    ap = argparse.ArgumentParser(description="OpenAI streaming client for bench timing")
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
        "stream_options": {"include_usage": True},
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
    timings_seen = False

    try:
        with open(args.out, "w", encoding="utf-8") as out_f:
            _emit(out_f, "start", t0=t0, label=args.label)
            with urllib.request.urlopen(req, timeout=600) as resp:
                for raw in resp:
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line or not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        _emit(out_f, "done", label=args.label)
                        break
                    try:
                        obj = json.loads(payload)
                    except json.JSONDecodeError:
                        continue

                    # Server timings (llama.cpp / Gufo) on terminal or usage chunk.
                    timings = obj.get("timings")
                    if isinstance(timings, dict) and not timings_seen:
                        timings_seen = True
                        _emit(out_f, "timings", label=args.label, timings=timings)

                    usage = obj.get("usage")
                    if isinstance(usage, dict):
                        _emit(out_f, "usage", label=args.label, usage=usage)
                        nested = usage.get("timings")
                        if isinstance(nested, dict) and not timings_seen:
                            timings_seen = True
                            _emit(out_f, "timings", label=args.label, timings=nested)

                    choices = obj.get("choices") or []
                    if not choices:
                        continue
                    choice0 = choices[0] or {}
                    # Some servers put timings on the terminal choice object.
                    if isinstance(choice0.get("timings"), dict) and not timings_seen:
                        timings_seen = True
                        _emit(
                            out_f,
                            "timings",
                            label=args.label,
                            timings=choice0["timings"],
                        )
                    delta = choice0.get("delta") or {}
                    text = delta.get("content") or delta.get("reasoning_content")
                    if text:
                        _emit(out_f, "chunk", label=args.label, text=text)
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
