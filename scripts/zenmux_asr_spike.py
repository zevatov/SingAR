#!/usr/bin/env python3
"""SingAR spike: verify ZenMux qwen3-asr-flash returns a transcript.

Usage:
  export ZENMUX_API_KEY="sk-..."
  python3 scripts/zenmux_asr_spike.py path/to/audio.wav

Sends the audio as base64 input_audio to the OpenAI-compatible chat completions
endpoint and prints the returned transcript + latency.
"""
import base64
import os
import sys
import time
import urllib.request

BASE_URL = "https://zenmux.ai/api/v1"
MODEL = "qwen/qwen3-asr-flash"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: zenmux_asr_spike.py <audio.wav>", file=sys.stderr)
        return 2
    audio_path = sys.argv[1]
    api_key = os.environ.get("ZENMUX_API_KEY")
    if not api_key:
        print("ZENMUX_API_KEY env var is required", file=sys.stderr)
        return 2

    with open(audio_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()

    # Infer format from extension.
    ext = os.path.splitext(audio_path)[1].lstrip(".").lower() or "wav"

    payload = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Transcribe this audio."},
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
        data=__import__("json").dumps(payload).encode(),
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

    import json
    data = json.loads(body)
    text = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    print(f"latency: {elapsed:.2f}s")
    print(f"model:   {data.get('model', '?')}")
    print(f"usage:   {data.get('usage', {})}")
    print("---- transcript ----")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
