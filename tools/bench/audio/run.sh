#!/usr/bin/env bash
# Shared audio-engine identity helpers are in engine.sh (protocol=audio).
# This suite: Piper TTS latency + Whisper STT RTF — same CLI pattern as other benches.
#
#   ./bench audio --engine piper
#   ./bench audio --engine whisper
#   ./bench audio --engine piper,whisper
#   BENCH_ENGINE=piper ./bench audio
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

PROJECT_ROOT="$ROOT"
# shellcheck source=../lib/paths.sh
source "$ROOT/tools/bench/lib/paths.sh"
# shellcheck source=../lib/lifecycle.sh
source "$ROOT/tools/bench/lib/lifecycle.sh"
# shellcheck source=../lib/python.sh
source "$ROOT/tools/bench/lib/python.sh"

OUT_ROOT="${BENCH_OUT:-$ROOT/output/bench/audio}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PIPER_TEXT="${AUDIO_PIPER_TEXT:-Hello from Strix Halo. This is a Piper latency sample.}"
PIPER_VOICE="${AUDIO_PIPER_VOICE:-${PIPER_DEFAULT_VOICE:-}}"
WHISPER_WAV="${AUDIO_WHISPER_WAV:-}"
N_RUNS="${AUDIO_N_RUNS:-3}"

die() { printf '[bench audio] error: %s\n' "$*" >&2; exit 1; }
log() { printf '[bench audio] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./bench audio [--engine piper|whisper|piper,whisper] [options]

Options:
  --engine NAME[,NAME]   default: BENCH_ENGINE or piper,whisper
  --runs N               repeats per engine (default 3)
  --text STR             Piper input text
  --voice NAME           Piper voice stem
  --wav PATH             Whisper input wav (else generate 2s tone)
  -h|--help

Same lifecycle as other engines: prepare via compose, optional BENCH_ENGINE_KEEP=1.
EOF
}

ENGINES_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --engine) shift; ENGINES_ARG="${1:?}"; shift ;;
    --runs) shift; N_RUNS="${1:?}"; shift ;;
    --text) shift; PIPER_TEXT="${1:?}"; shift ;;
    --voice) shift; PIPER_VOICE="${1:?}"; shift ;;
    --wav) shift; WHISPER_WAV="${1:?}"; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

if [[ -z "$ENGINES_ARG" ]]; then
  case "${BENCH_ENGINE:-}" in
    piper|whisper) ENGINES_ARG="$BENCH_ENGINE" ;;
    *) ENGINES_ARG="piper,whisper" ;;
  esac
fi

ensure_tone_wav() {
  local out="$1" secs="${2:-2}"
  [[ -f "$out" ]] && return 0
  mkdir -p "$(dirname "$out")"
  bench_python - "$out" "$secs" <<'PY'
import struct, sys, math, wave
path, secs = sys.argv[1], float(sys.argv[2])
rate, amp = 16000, 0.2
n = int(rate * secs)
with wave.open(path, "w") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    for i in range(n):
        v = int(amp * 32767 * math.sin(2 * math.pi * 440 * i / rate))
        w.writeframes(struct.pack("<h", v))
PY
}

wav_duration_s() {
  local path="$1"
  bench_python - "$path" <<'PY'
import wave, sys
with wave.open(sys.argv[1], "r") as w:
    print(w.getnframes() / float(w.getframerate()))
PY
}

bench_piper() {
  local eng="piper" url run_dir i t0 t1 ms bytes dur rtf
  local -a times=()
  export BENCH_ENGINE=piper
  bench_engine_prepare piper || die "piper prepare failed"
  url="$(bench_engine_base_url piper)"
  run_dir="$OUT_ROOT/piper-$STAMP"
  mkdir -p "$run_dir"
  log "piper @ $url  runs=$N_RUNS"

  local body
  body="$(bench_python - "$PIPER_TEXT" "$PIPER_VOICE" <<'PY'
import json, sys
text, voice = sys.argv[1], sys.argv[2]
d = {"input": text, "model": "tts"}
if voice:
    d["voice"] = voice
print(json.dumps(d))
PY
)"

  for i in $(seq 1 "$N_RUNS"); do
    t0="$(date +%s%N)"
    if ! curl -sfS --max-time 180 -X POST "${url}/audio/speech" \
      -H 'Content-Type: application/json' \
      -d "$body" -o "$run_dir/out-$i.wav"; then
      die "piper POST /audio/speech failed (run $i)"
    fi
    t1="$(date +%s%N)"
    ms="$(bench_python -c "print(round(($t1-$t0)/1e6, 2))")"
    bytes="$(wc -c <"$run_dir/out-$i.wav" | tr -d ' ')"
    dur="$(wav_duration_s "$run_dir/out-$i.wav" 2>/dev/null || echo 0)"
    rtf="n/a"
    if bench_python -c "import sys; sys.exit(0 if float('$dur')>0 else 1)" 2>/dev/null; then
      rtf="$(bench_python -c "print(round(($ms/1000.0)/float('$dur'), 4))")"
    fi
    times+=("$ms")
    log "  run $i: ${ms} ms  wav=${bytes}B  audio=${dur}s  RTF=${rtf}"
    printf '%s\n' "{\"run\":$i,\"latency_ms\":$ms,\"bytes\":$bytes,\"audio_s\":$dur,\"rtf\":$([[ "$rtf" == "n/a" ]] && echo null || echo "$rtf")}" \
      >>"$run_dir/runs.jsonl"
  done

  bench_python - "$run_dir" "${times[*]}" <<'PY'
import json, os, sys, statistics
d = sys.argv[1]
vals = [float(x) for x in sys.argv[2].split()]
summary = {
    "engine": "piper",
    "n": len(vals),
    "latency_ms_mean": round(statistics.mean(vals), 2),
    "latency_ms_median": round(statistics.median(vals), 2),
    "latency_ms_min": round(min(vals), 2),
    "latency_ms_max": round(max(vals), 2),
}
path = os.path.join(d, "summary.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
print(json.dumps(summary))
latest = os.path.join(os.path.dirname(d), "latest")
os.makedirs(latest, exist_ok=True)
import shutil
shutil.copy2(path, os.path.join(latest, "piper-summary.json"))
PY
  bench_engine_cleanup piper
}

bench_whisper() {
  local eng="whisper" url run_dir i t0 t1 ms dur rtf wav
  local -a times=() rtfs=()
  export BENCH_ENGINE=whisper
  bench_engine_prepare whisper || die "whisper prepare failed"
  url="$(bench_engine_base_url whisper)"
  run_dir="$OUT_ROOT/whisper-$STAMP"
  mkdir -p "$run_dir"
  wav="${WHISPER_WAV:-$run_dir/fixture-tone.wav}"
  ensure_tone_wav "$wav" 2
  dur="$(wav_duration_s "$wav")"
  log "whisper @ $url  wav=$wav (${dur}s)  runs=$N_RUNS"

  for i in $(seq 1 "$N_RUNS"); do
    t0="$(date +%s%N)"
    # whisper.cpp server: multipart field "file" on /inference
    if ! curl -sfS --max-time 600 -X POST "${url}/inference" \
      -F "file=@${wav}" \
      -F "response_format=json" \
      -o "$run_dir/out-$i.json" 2>/dev/null \
      && ! curl -sfS --max-time 600 -X POST "${url}/inference" \
        -F "file=@${wav}" \
        -o "$run_dir/out-$i.json"; then
      die "whisper POST /inference failed (run $i) — is whisper-server up?"
    fi
    t1="$(date +%s%N)"
    ms="$(bench_python -c "print(round(($t1-$t0)/1e6, 2))")"
    rtf="$(bench_python -c "print(round(($ms/1000.0)/float('$dur'), 4))")"
    times+=("$ms")
    rtfs+=("$rtf")
    log "  run $i: ${ms} ms  audio=${dur}s  RTF=${rtf}"
    printf '%s\n' "{\"run\":$i,\"latency_ms\":$ms,\"audio_s\":$dur,\"rtf\":$rtf}" >>"$run_dir/runs.jsonl"
  done

  bench_python - "$run_dir" "${times[*]}" "${rtfs[*]}" <<'PY'
import json, os, sys, statistics, shutil
d = sys.argv[1]
lat = [float(x) for x in sys.argv[2].split()]
rtf = [float(x) for x in sys.argv[3].split()]
summary = {
    "engine": "whisper",
    "n": len(lat),
    "latency_ms_mean": round(statistics.mean(lat), 2),
    "latency_ms_median": round(statistics.median(lat), 2),
    "rtf_mean": round(statistics.mean(rtf), 4),
    "rtf_median": round(statistics.median(rtf), 4),
}
path = os.path.join(d, "summary.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
print(json.dumps(summary))
latest = os.path.join(os.path.dirname(d), "latest")
os.makedirs(latest, exist_ok=True)
shutil.copy2(path, os.path.join(latest, "whisper-summary.json"))
PY
  bench_engine_cleanup whisper
}

IFS=',' read -r -a ENGS <<< "${ENGINES_ARG// /}"
mkdir -p "$OUT_ROOT"
for e in "${ENGS[@]}"; do
  [[ -n "$e" ]] || continue
  e="$(bench_engine_normalize "$e")"
  case "$e" in
    piper) bench_piper ;;
    whisper) bench_whisper ;;
    *) die "audio suite only supports piper|whisper (got $e)" ;;
  esac
done
log "done → $OUT_ROOT"
