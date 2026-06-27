#!/usr/bin/env python3
"""Verify LLM-polish: feed a messy local whisper transcript to qwen3-max and
check it cleans up technical terms / punctuation.
"""
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dotenv import load_env  # noqa: E402

load_env()

BASE_URL = "https://zenmux.ai/api/v1"
MODEL = "qwen/qwen3-max"

# A deliberately messy transcript like local whisper produces for
# "привет запусти pytest tests/test_auth.py --verbose"
MESSY = "Привет, запусти PyTest-тесты, тест-аут-пивотишн-сварбоус."

PROMPT = """You are a dictation post-processor for coding and technical text. Fix \
punctuation, spacing, and obvious mis-transcriptions of technical terms \
(file paths, command names, identifiers). Output ONLY the corrected text, \
nothing else.

Transcript:
""" + MESSY


def main():
    api_key = os.environ.get("ZENMUX_API_KEY")
    payload = {"model": MODEL, "messages": [{"role": "user", "content": PROMPT}]}
    req = urllib.request.Request(
        f"{BASE_URL}/chat/completions", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
        method="POST",
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode())
    print(f"latency: {time.time()-t0:.2f}s")
    print(f"input:   {MESSY!r}")
    print(f"output:  {data['choices'][0]['message']['content']!r}")
    print(f"usage:   {data.get('usage')}")


if __name__ == "__main__":
    main()
