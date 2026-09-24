"""Summarize a bench stream JSONL into a full latency/throughput report.

Client wall-clock (primary for user feel):
  ttft_ms          — request start → first content chunk
  decode_tok_s     — tokens after first / (end − first)
  e2e_s            — request start → last chunk
  itl_ms_p50/p95   — inter-token latency distribution

Optional with --fill-tokens N:
  prefill_tok_s    — fill_tokens / (ttft_ms/1000)  (use cold stream for real prefill)

Server timings when the engine emits them (Gufo / llama.cpp):
  server_prompt_ms, server_predicted_ms, server_prompt_n, server_predicted_n,
  server_prompt_tok_s, server_decode_tok_s, server_cache_n
  (non-positive server rates are dropped — warm cache often reports 0)
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any


def _pct(vals: list[float], p: float) -> float | None:
    if not vals:
        return None
    vals = sorted(vals)
    k = (len(vals) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(vals) - 1)
    if f == c:
        return vals[f]
    return vals[f] + (vals[c] - vals[f]) * (k - f)


def summarize(path: str, fill_tokens: float | None = None) -> dict[str, Any]:
    t0: float | None = None
    chunks: list[float] = []
    server: dict[str, Any] = {}
    usage: dict[str, Any] = {}

    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            ev = rec.get("event")
            if ev == "start":
                t0 = rec.get("t0") or rec.get("t")
            elif ev == "chunk":
                t = rec.get("t")
                if t is not None:
                    chunks.append(float(t))
            elif ev == "timings" and isinstance(rec.get("timings"), dict):
                server = dict(rec["timings"])
            elif ev == "usage" and isinstance(rec.get("usage"), dict):
                usage = dict(rec["usage"])

    out: dict[str, Any] = {
        "chunks": len(chunks),
        "ttft_ms": None,
        "e2e_s": None,
        "decode_tok_s": None,
        "prefill_tok_s": None,
        "itl_ms_p50": None,
        "itl_ms_p95": None,
        "itl_ms_max": None,
        "total_ms": None,
    }

    if t0 is not None and chunks:
        ttft = (chunks[0] - t0) * 1000.0
        e2e = chunks[-1] - t0
        out["ttft_ms"] = round(ttft, 2)
        out["e2e_s"] = round(e2e, 3)
        out["total_ms"] = round(e2e * 1000.0, 2)

        if len(chunks) > 1:
            decode_s = chunks[-1] - chunks[0]
            if decode_s > 0:
                out["decode_tok_s"] = round((len(chunks) - 1) / decode_s, 2)

        deltas = []
        for i in range(1, len(chunks)):
            d = (chunks[i] - chunks[i - 1]) * 1000.0
            if d > 0.05:
                deltas.append(d)
        if deltas:
            out["itl_ms_p50"] = round(_pct(deltas, 50) or 0, 2)
            out["itl_ms_p95"] = round(_pct(deltas, 95) or 0, 2)
            out["itl_ms_max"] = round(max(deltas), 2)

        if fill_tokens and fill_tokens > 0 and ttft > 0:
            out["prefill_tok_s"] = round(fill_tokens / (ttft / 1000.0), 2)

    if server:
        prompt_ms = server.get("prompt_ms")
        predicted_ms = server.get("predicted_ms")
        prompt_n = server.get("prompt_n")
        predicted_n = server.get("predicted_n")
        out["server_prompt_ms"] = prompt_ms
        out["server_predicted_ms"] = predicted_ms
        out["server_prompt_n"] = prompt_n
        out["server_predicted_n"] = predicted_n
        out["server_cache_n"] = server.get("cache_n")
        out["server_prompt_tok_s"] = server.get("prompt_per_second")
        out["server_decode_tok_s"] = server.get("predicted_per_second")
        # Drop non-positive server rates (warm cache often reports 0).
        try:
            if out["server_prompt_tok_s"] is not None and float(out["server_prompt_tok_s"]) <= 0:
                out["server_prompt_tok_s"] = None
        except (TypeError, ValueError):
            out["server_prompt_tok_s"] = None
        try:
            if out["server_decode_tok_s"] is not None and float(out["server_decode_tok_s"]) <= 0:
                out["server_decode_tok_s"] = None
        except (TypeError, ValueError):
            out["server_decode_tok_s"] = None
        if (
            out["server_prompt_tok_s"] is None
            and prompt_ms
            and prompt_n
            and float(prompt_ms) > 0
            and float(prompt_n) > 0
        ):
            out["server_prompt_tok_s"] = round(
                float(prompt_n) * 1000.0 / float(prompt_ms), 2
            )
        if (
            out["server_decode_tok_s"] is None
            and predicted_ms
            and predicted_n
            and float(predicted_ms) > 0
            and float(predicted_n) > 0
        ):
            out["server_decode_tok_s"] = round(
                float(predicted_n) * 1000.0 / float(predicted_ms), 2
            )

    if usage:
        out["usage_prompt_tokens"] = usage.get("prompt_tokens")
        out["usage_completion_tokens"] = usage.get("completion_tokens")
        out["usage_cached_tokens"] = usage.get("cached_tokens") or (
            (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
        )

    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl")
    ap.add_argument("out_json")
    ap.add_argument("--fill-tokens", type=float, default=None)
    args = ap.parse_args()
    summary = summarize(args.jsonl, args.fill_tokens)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
