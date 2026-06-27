#!/usr/bin/env python3
"""SingAR spike: verify ZenMux qwen3-asr-flash returns a transcript.

Reads ZENMUX_API_KEY from .env (project root) or the environment.

Usage:
  python3 scripts/zenmux_asr_spike.py path/to/audio.wav
  python3 scripts/zenmux_asr_spike.py test/sample_ru.wav
  python3 scripts/zenmux_asr_spike.py test/sample_ru.wav --model qwen/qwen3-max

Sends the audio as base64 input_audio to the OpenAI-compatible chat
completions endpoint and prints the returned transcript + latency.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Make sibling modules importable.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from dotenv import load_env  # noqa: E402

load_env()

BASE_URL = "https://zenmux.ai/api/v1"
DEFAULT_MODEL = "qwen/qwen3-asr-flash"


def parse_args(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    audio_path = argv[0]
    model = DEFAULT_MODEL
    rest = argv[1:]
    for i, arg in enumerate(rest):
        if arg == "--model" and i + 1 < len(rest):
            model = rest[i + 1]
    return audio_path, model


def main() -> int:
    audio_path, model = parse_args(sys.argv[1:])

    if not os.path.isfile(audio_path):
        print(f"audio file not found: {audio_path}", file=sys.stderr)
        return 2

    api_key = os.environ.get("ZENMUX_API_KEY")
    if not api_key or api_key.startswith("sk-put-your"):
        print(
            "ZENMUX_API_KEY is not set. Copy .env.example to .env and fill in "
            "your key (https://zenmux.ai).",
            file=sys.stderr,
        )
        return 2

    with open(audio_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()

    ext = os.path.splitext(audio_path)[1].lstrip(".").lower() or "wav"

    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Transcribe this audio verbatim."},
                    {
                        "type": "input_audio",
                        "input_audio": {"data": audio_b64, "format": ext},
                    },
                ],
            }
        ],
    }

    req = urllib.request.Request(
        f"{BASE_URL}/chat/completions",
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
            body = resp.read().decode()
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        print(f"HTTP {e.code} after {elapsed:.2f}s", file=sys.stderr)
        print(e.read().decode(), file=sys.stderr)
        return 1
    elapsed = time.time() - t0

    data = json.loads(body)
    text = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    print(f"model:   {data.get('model', '?')}")
    print(f"latency: {elapsed:.2f}s")
    print(f"usage:   {data.get('usage', {})}")
    print("---- transcript ----")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
