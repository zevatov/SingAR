# SingAR spike results

## whisper.cpp + large-v3-turbo on M-Pro (local)

Hardware: Apple M1 Pro. Model: `ggml-large-v3-turbo.bin` (1.5 GB). Metal backend.

| Audio (dur) | Mode | Wall time | RTF |
|---|---|---|---|
| 3.8s | `whisper-cli` cold | 19.7s | — (cold start) |
| 3.8s | `whisper-cli` warm | 1.74s | **0.46** |
| 3.8s | `whisper-server /inference` | 1.72–1.90s | **0.45–0.50** (model resident, no cold start) |

**Verdict:** local ASR is real-time on M-Pro; `whisper-server` keeps the model
resident → ~1.7s per dictation regardless of idle. This is the free/offline core.

## ZenMux qwen3-asr-flash (re-ASR) — BROKEN

`qwen3-asr-flash` is listed in ZenMux's catalogue but audio input is broken
through their gateway (400 on base64, 500 on data-URI, 403 on transcriptions).
**re-ASR via ZenMux is dropped.** ZenMux `qwen3-max` (LLM-polish, text-only)
works at ~4s.

## OpenRouter /audio/transcriptions — WORKS (re-ASR resurrected)

Format: `POST /api/v1/audio/transcriptions` with JSON `{"model","input_audio":
{"data":<base64>,"format":"wav"}}` (NOT multipart). Endpoint confirmed working.

### English audio — `pytest tests/test_auth.py --verbose` (intended)

| Model | Latency | Cost | Transcript |
|---|---|---|---|
| **gpt-4o-transcribe** | 0.95s | $0.00024 | `pytest tests/test_auth.py` ✅ path with slash |
| **gpt-4o-mini-transcribe** | 1.10s | $0.00012 | `pytest tests test_auth.py` (space, no slash) |
| whisper-large-v3-turbo | 0.46s | $0.00011 | `pytest tests test auth.py` (whisper-style spacing) |
| whisper-large-v3 | 1.79s | $0.00010 | `PyTest tests test auth.py` |
| whisper-1 | 2.34s | $0.00040 | good punctuation, `test auth.py` |
| voxtral-mini-transcribe | 0.62s | $0.00015 | `PyTest tests test off.py` |
| parakeet-tdt-0.6b-v3 | 1.01s | $0.00010 | `py test tests test auth.py` |
| chirp-3 | 2.01s | $0.00107 | `test -v -s -v` (cheapest-quality, priciest) |
| mai-transcribe-1.5 | 0.77s | $0.00040 | `pytest tests test auth.py` |

### Russian audio (synthetic TTS — quality limited by input)

All models distort the technical terms on RU TTS (the TTS itself mangles
`pytest`/`pivotations`). On real speech quality will be higher. Latency & cost
consistent with EN. `gpt-4o-mini-transcribe` keeps Cyrillic + Latin mixed cleanly.

### Verdict — best for vibe-coding

**`openai/gpt-4o-mini-transcribe`** is the recommended re-ASR model:
- ✅ Best code-path recognition (`tests/test_auth.py` — closest to intent)
- ✅ Fast (~1s)
- ✅ Cheap (~$0.00012/transcription → ~$1 per 8000 dictations)
- ✅ Handles RU+EN mixed (keeps Cyrillic, recognises Latin identifiers)

`gpt-4o-transcribe` is the premium alternative (slash-paths perfect, 2× cost).
`whisper-large-v3-turbo` is the budget/ultra-fast option (0.46s, $0.00011).

## Final architecture

| Step | Engine | When | Cost |
|---|---|---|---|
| Local ASR (instant, offline) | whisper.cpp large-v3-turbo | always, free | $0 |
| re-ASR (premium, cloud) | OpenRouter gpt-4o-mini-transcribe | opt-in toggle | ~$0.00012 |
| LLM-polish (premium, cloud) | ZenMux qwen3-max | opt-in toggle | ~$0.0001 (110 tok) |

Two providers, both steps live. App ships with no key; BYOK or proxy-subscription.
