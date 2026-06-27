# SingAR spike results

## whisper.cpp + large-v3-turbo on M-Pro (2026-06-27)

Hardware: Apple Silicon M-Pro. Model: `ggml-large-v3-turbo.bin` (1.5 GB).
Binary: `whisper-cli` (Homebrew 1.9.1, Metal/CoreML backend).

### Latency / RTF

| Audio (dur) | Mode | Wall time | RTF | Notes |
|---|---|---|---|---|
| RU 3.8s | `-l ru` | 19.7s | — | **Cold start**: model loaded from disk into RAM |
| EN 3.8s | `-l en` | 1.74s | **0.46** | Warm (model in page cache) |
| RU 3.8s | auto | 1.73s | **0.45** | Warm, auto language detect works |

**Verdict:** warm inference is comfortably real-time (RTF ≈ 0.45, faster than
speech). Local ASR core is confirmed viable for instant dictation on M-Pro.

### Quality samples (synthetic `say` voices — real mic may differ)

Input (intended): `Привет, запусти pytest tests/test_auth.py --verbose`
- whisper (ru): `Привет, запусти PyTest-тесты, тест-аут-пивотишн-сварбоус.`
- whisper (en): `Hello, run PyTestTestsTestAuth.py with verbose flag.`

Findings:
- **Punctuation is good** out of the box (commas, periods present).
- **Code/technical terms & file paths are distorted** (`pytest tests/test_auth.py`
  → `PyTestTestsTestAuth.py` / `тест-аут-пивотишн`). This is exactly where the
  optional **LLM-polish cloud step** (Qwen via ZenMux) adds value.
- **Auto language detection works** (mixed RU/EN handled on a per-clip basis).

### Architectural decision: cold start

Cold start ≈ 20s is unacceptable for dictation UX. The subprocess-per-dictation
approach (current `WhisperEngine`) reloads the model every call.

**Required change:** keep the model resident in memory. Options:
1. In-process C bridge to `libwhisper` (Swift system module) — model loaded once
   at app start, reused per dictation. Best latency, more integration work.
2. Long-lived `whisper-cli` server mode (`--server`) — HTTP endpoint, model stays
   loaded. Less integration, adds a localhost hop.

Path (1) is the target for production; path (2) is a fast interim.

## ZenMux qwen3-asr-flash — PENDING

Script ready at `scripts/zenmux_asr_spike.py`. Awaiting `ZENMUX_API_KEY` to run
against real audio and measure latency + confirm transcript return shape.
