#!/usr/bin/env python3
"""SingAR spike: cloud re-ASR via OpenRouter /audio/transcriptions.

WORKING format: JSON body with `input_audio` object (NOT multipart). Endpoint:
POST /api/v1/audio/transcriptions with Authorization: Bearer <key>.

Usage:
  python3 scripts/openrouter_asr_spike.py test/sample_en.wav
  python3 scripts/openrouter_asr_spike.py test/sample_ru.wav --model openai/gpt-4o-mini-transcribe
  python3 scripts/openrouter_asr_spike.py test/sample_ru.wav --compare
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dotenv import load_env  # noqa: E402

load_env()

BASE_URL = "https://openrouter.ai/api/v1"
# Default — best balance of quality/cost/latency for vibe-coding per our tests.
DEFAULT_MODEL = "openai/gpt-4o-mini-transcribe"

# All working ASR models on OpenRouter's /audio/transcriptions endpoint.
CANDIDATES = [
    "openai/gpt-4o-mini-transcribe",   # best code/path recognition, ~1s
    "openai/gpt-4o-transcribe",        # same quality, pricier
    "openai/whisper-large-v3-turbo",   # fast (0.5s), cheap, decent
    "openai/whisper-large-v3",         # cheaper, 0.8s
    "openai/whisper-1",                # legacy whisper, good punctuation
    "mistralai/voxtral-mini-transcribe",
    "nvidia/parakeet-tdt-0.6b-v3",
    "google/chirp-3",
    "microsoft/mai-transcribe-1.5",
]


def transcribe(audio_path, model, api_key):
    with open(audio_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    payload = {
        "model": model,
        "input_audio": {"data": b64, "format": "wav"},
    }
    req = urllib.request.Request(
        f"{BASE_URL}/audio/transcriptions",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read().decode()
            elapsed = time.time() - t0
            data = json.loads(raw)
            text = data.get("text", "").strip()
            usage = data.get("usage", {})
            return elapsed, text, usage, None
    except urllib.error.HTTPError as e:
        return time.time() - t0, "", {}, e.read().decode()[:200]


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__); sys.exit(0)
    audio_path = sys.argv[1]
    if not os.path.isfile(audio_path):
        print(f"audio not found: {audio_path}", file=sys.stderr); sys.exit(2)

    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        print("OPENROUTER_API_KEY not set. Add it to .env.", file=sys.stderr); sys.exit(2)

    compare = "--compare" in sys.argv
    model = DEFAULT_MODEL
    for i, a in enumerate(sys.argv):
        if a == "--model" and i + 1 < len(sys.argv):
            model = sys.argv[i + 1]

    models = CANDIDATES if compare else [model]
    print(f"audio: {audio_path}  ({os.path.getsize(audio_path)//1024} KB)\n")
    for m in models:
        elapsed, text, usage, err = transcribe(audio_path, m, api_key)
        if err:
            print(f"[{m}] {elapsed:.2f}s  ERROR: {err}")
        else:
            cost = usage.get("cost", usage.get("seconds", "?"))
            print(f"[{m}] {elapsed:.2f}s  cost={cost}")
            print(f"   {text!r}")
        print()


if __name__ == "__main__":
    main()
