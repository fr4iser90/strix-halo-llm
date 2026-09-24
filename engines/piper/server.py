#!/usr/bin/env python3
"""OpenAI-compatible /audio/speech wrapper for Piper CLI."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response

VOICES_DIR = Path(os.environ.get("PIPER_VOICES_DIR", "/voices"))
PIPER_BIN = os.environ.get("PIPER_BIN", "/app/piper/piper")
DEFAULT_VOICE = os.environ.get("PIPER_DEFAULT_VOICE", "").strip()

app = FastAPI()


def _find_model(voice: str) -> Path:
    voice = (voice or DEFAULT_VOICE or "").strip()
    if voice:
        for name in (f"{voice}.onnx", voice):
            p = VOICES_DIR / name
            if p.is_file():
                return p
        matches = sorted(VOICES_DIR.glob(f"*{voice}*.onnx"))
        if matches:
            return matches[0]
    all_models = sorted(VOICES_DIR.glob("*.onnx"))
    if not all_models:
        raise HTTPException(503, f"no .onnx models in {VOICES_DIR}")
    return all_models[0]


@app.get("/")
def root() -> dict:
    return {
        "ok": True,
        "service": "piper-tts",
        "voices": [p.stem for p in sorted(VOICES_DIR.glob("*.onnx"))],
    }


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.post("/audio/speech")
async def audio_speech(request: Request) -> Response:
    try:
        body = await request.json()
    except Exception as e:
        raise HTTPException(400, f"invalid json: {e}") from e

    text = (body.get("input") or "").strip()
    if not text:
        raise HTTPException(400, "empty input")

    model = _find_model(str(body.get("voice") or ""))
    config = model.with_suffix(model.suffix + ".json")
    if not config.is_file():
        config = None

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        out_path = tmp.name

    cmd = [PIPER_BIN, "--model", str(model), "--output_file", out_path]
    if config:
        cmd.extend(["--config", str(config)])

    try:
        proc = subprocess.run(
            cmd,
            input=text.encode("utf-8"),
            capture_output=True,
            timeout=int(os.environ.get("PIPER_TIMEOUT_SEC", "120")),
            check=False,
        )
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or b"").decode("utf-8", errors="replace")[:800]
            raise HTTPException(502, f"piper failed: {err}")
        return Response(content=Path(out_path).read_bytes(), media_type="audio/wav")
    finally:
        Path(out_path).unlink(missing_ok=True)
