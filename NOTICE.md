# NOTICE

This document applies to the SingAR distribution and its components.

## SingAR Application Code

Copyright (c) 2026 Stanislav Zevatov

SingAR application code is licensed under the **MIT License** — see
[`LICENSE`](LICENSE) for the full license text.

## Third-Party Components and Models

SingAR integrates or interfaces with the following third-party components:

- **Whisper.cpp / GGML**: Local speech recognition engine utilizing Apple Metal GPU acceleration.
  Licensed under the MIT License by Georgi Gerganov and contributors.
- **OpenAI Whisper Models**: Pretrained speech recognition weights (`ggml-large-v3-turbo-q5_0.bin`)
  derived from OpenAI Whisper, distributed under the MIT License.
- **Google Generative AI / Gemini API**: Cloud transcription provider (optional, BYOK).
- **Groq Cloud API**: High-speed LPU transcription provider (optional, BYOK).
- **OpenRouter API**: Cloud LLM / Audio transcription provider (optional, BYOK).
