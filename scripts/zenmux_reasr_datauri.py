#!/usr/bin/env python3
"""Try qwen3-asr-flash via audio_url with a data: URI (inline base64 as URL),
since ZenMux/Alibaba rejects input_audio base64 but expects audio_url.
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

BASE_URL = "https://zenmux.ai/api/v1"
MODEL = "qwen/qwen3-asr-flash"


def try_request(payload, label):
    api_key = os.environ.get("ZENMUX_API_KEY")
    if not api_key or api_key.startswith("sk-put-your"):
        print(f"[{label}] no ZENMUX_API_KEY")
        return
    req = urllib.request.Request(
        f"{BASE_URL}/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
        method="POST",
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as e:
        print(f"[{label}] HTTP {e.code} after {time.time()-t0:.2f}s: {e.read().decode()[:200]}")
        return
    elapsed = time.time() - t0
    data = json.loads(body)
    text = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    print(f"[{label}] {elapsed:.2f}s: {text!r}")


def main():
    audio_path = sys.argv[1] if len(sys.argv) > 1 else "test/sample_en.wav"
    with open(audio_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()
    ext = os.path.splitext(audio_path)[1].lstrip(".").lower() or "wav"

    # Attempt 1: audio_url with data: URI
    data_uri = f"data:audio/{ext};base64,{audio_b64}"
    try_request({
        "model": MODEL,
        "messages": [{"role": "user", "content": [
            {"type": "audio_url", "audio_url": {"url": data_uri}},
        ]}],
    }, "audio_url data-uri")

    # Attempt 2: audio_url with raw base64 string as url
    try_request({
        "model": MODEL,
        "messages": [{"role": "user", "content": [
            {"type": "audio_url", "audio_url": {"url": audio_b64}},
        ]}],
    }, "audio_url raw-b64")

    # Attempt 3: OpenAI /audio/transcriptions endpoint
    api_key = os.environ.get("ZENMUX_API_KEY")
    if api_key and not api_key.startswith("sk-put-your"):
        import io
        files = {"file": (os.path.basename(audio_path), open(audio_path, "rb"), f"audio/{ext}")}
        # multipart manually
        boundary = "----b"
        body = b""
        with open(audio_path, "rb") as f:
            filedata = f.read()
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{os.path.basename(audio_path)}\"\r\nContent-Type: audio/{ext}\r\n\r\n".encode() + filedata + b"\r\n"
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{MODEL}\r\n".encode()
        body += f"--{boundary}--\r\n".encode()
        req = urllib.request.Request(
            f"{BASE_URL}/audio/transcriptions", data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}", "Authorization": f"Bearer {api_key}"},
            method="POST",
        )
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                print(f"[/audio/transcriptions] {time.time()-t0:.2f}s: {resp.read().decode()[:300]}")
        except urllib.error.HTTPError as e:
            print(f"[/audio/transcriptions] HTTP {e.code} after {time.time()-t0:.2f}s: {e.read().decode()[:200]}")


if __name__ == "__main__":
    main()
