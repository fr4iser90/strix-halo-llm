"""Throughput compare.md column parsing — canonical metric names only.

Columns:
  ttft_cold_ms | ttft_warm_ms | prefill_tok_s | decode_tok_s | itl_p50_ms
"""

from __future__ import annotations

import re
from typing import Any

_CANON = frozenset(
    {
        "ttft_cold_ms",
        "ttft_warm_ms",
        "prefill_tok_s",
        "decode_tok_s",
        "itl_p50_ms",
    }
)


def _canon_header(h: str) -> str | None:
    hl = re.sub(r"\s+", "_", h.lower().strip())
    if hl == "model":
        return None
    if hl in _CANON:
        return hl
    # Backend-prefixed headers e.g. vulkan_prefill_tok_s (native llama-bench)
    for key in _CANON:
        if hl.endswith("_" + key):
            return key
    return None


def parse_compare_md(
    text: str, default_engine: str = "llama.cpp"
) -> tuple[str, list[dict]]:
    """Parse engine tables. Unknown / short-name columns are ignored."""
    models: list[dict] = []
    engine = default_engine
    in_table = False
    header_keys: list[str | None] = []

    for line in text.splitlines():
        raw = line.rstrip()
        low = raw.lower()
        if low.startswith("engine:"):
            engine = raw.split(":", 1)[1].strip() or engine
            continue
        if raw.startswith("|") and "model" in low and (
            "prefill_tok_s" in low
            or "decode_tok_s" in low
            or "ttft_cold_ms" in low
            or "ttft_warm_ms" in low
            or "itl_p50_ms" in low
        ):
            header_cols = [c.strip() for c in raw.strip("|").split("|")]
            header_keys = [_canon_header(h) for h in header_cols]
            in_table = True
            continue
        if not in_table:
            continue
        if not raw.startswith("|") or raw.startswith("| ---") or re.match(
            r"^\|\s*-+", raw
        ):
            if models and not raw.startswith("|"):
                in_table = False
                header_keys = []
            continue
        parts = [p.strip() for p in raw.strip("|").split("|")]
        if not parts or parts[0].lower() == "model":
            continue
        if not header_keys or len(header_keys) != len(parts):
            continue
        row: dict[str, Any] = {
            "model": parts[0],
            "engine": engine,
            "ttft_cold_ms": None,
            "ttft_warm_ms": None,
            "prefill_tok_s": None,
            "decode_tok_s": None,
            "itl_p50_ms": None,
        }
        for key, val in zip(header_keys, parts):
            if key is None:
                continue
            if val in ("", "—", "-"):
                continue
            row[key] = val
        models.append(row)
    return engine, models


def dash(v: Any) -> str:
    if v is None or v == "" or v == "—":
        return "—"
    return str(v)
