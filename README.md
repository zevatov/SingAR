# SingAR

Нативная замена Apple-диктовке для macOS, заточенная под **вайбкодинг**:
мгновенный локальный ASR + опциональные облачные шаги для топ-качества на
технических терминах и путях к файлам. Приоритет — скорость и оптимизация под
Apple Silicon.

Зажал клавишу диктовки → наговорил → текст вставился в активное окно (чат,
терминал, редактор). Плюс фишки, которых у Apple нет: пауза фонового медиа на
время записи, голосовые команды для кода, live-оверлей с транскриптом.

## Архитектура

```
[Fn/Globe hold] → AVAudioEngine → VAD ─┬─→ whisper.cpp(CoreML, turbo) → транскрипт
                                        │      ├─→ парсер голосовых команд
                                        │      └─→ (опц.) облако:
                                        │            · re-ASR  — OpenRouter gpt-4o-mini-transcribe
                                        │            · polish  — ZenMux qwen3-max
                                        └─→ pasteboard + Cmd+V → активное окно
   старт: MediaRemote pause фонового медиа · выход: resume
   NSStatusItem: один глиф (idle/слушает/распознаёт/облако/готово) + меню тогглов
```

| Слой | Движок | Когда | Цена |
|---|---|---|---|
| Локальный ASR (ядро) | whisper.cpp large-v3-turbo | всегда, оффлайн | $0 |
| re-ASR (premium) | OpenRouter `gpt-4o-mini-transcribe` | тоггл | ~$0.00012 |
| LLM-polish (premium) | ZenMux `qwen3-max` | тоггл | ~$0.0001 |

Локальное ядро бесплатно для всех. Облачные шаги — BYOK (свой ключ в Keychain)
или подписка через прокси SingAR (ключ живёт серверно, в бинарнике нет ключей).

## Сборка

```bash
./build.sh            # debug → build/SingAR.app
./build.sh release    # release
open build/SingAR.app
```

Требования: macOS 14+, Xcode (Swift 6.3), Apple Silicon. Зависимости:
- `whisper-cpp` (Homebrew) + модель `ggml-large-v3-turbo.bin` (скачивается)
- `ffmpeg` (для перекодирования аудио в whisper-server)

Подготовка окружения:
```bash
brew install whisper-cpp ffmpeg
mkdir -p models
curl -L -o models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

## Первый запуск

1. `open build/SingAR.app`
2. Выдать разрешения в System Settings:
   - Privacy & Security → **Microphone**
   - Privacy & Security → **Accessibility**
   - Privacy & Security → **Input Monitoring**
3. Отключить Apple-диктовку: System Settings → Keyboard → Dictation → Off
4. (опц.) Вставить ключи: клик по глифу в статус-баре → «Настройки…»
   - OpenRouter — для re-ASR (https://openrouter.ai/keys)
   - ZenMux — для LLM-polish (https://zenmux.ai)
5. Зажать Fn/Globe → говорить → текст вставится в активное окно

## Меню статус-бара

Клик по глифу открывает тогглы (состояние в UserDefaults):
- Режим: Hold-to-talk / Toggle
- Авто-пунктуация, Голосовые команды, Live-частичные транскрипты
- Пауза фонового медиа при записи (полная пауза / приглушить)
- Облачный шаг: Off / Re-ASR / LLM-polish + выбор модели re-ASR
- Язык: Auto / RU / EN; Локальная модель: turbo / large-v3
- Запускать при входе, Настройки…, Quit

## Структура

```
Sources/SingAR/
├── main.swift / AppDelegate.swift            # точка входа, разрешения, launch-at-login
├── Settings/                                  # AppSettings, KeychainStore, SettingsWindow
├── StatusBar/                                 # NSStatusItem глиф + меню тогглов
├── Overlay/DictationOverlay.swift             # live-транскрипт оверлей
├── Dictation/DictationController.swift        # оркестратор цикла диктовки
├── Hotkey/HotkeyManager.swift                 # CGEventTap (Fn/Globe)
├── Audio/                                     # AudioRecorder + VAD
├── ASR/                                       # WhisperEngine + WhisperServerProcess + CloudASR + WAVWriter
├── TextInjection/TextInjector.swift           # pasteboard + Cmd+V
├── Commands/VoiceCommandParser.swift          # голосовые команды / макросы
└── Media/MediaController.swift                # MediaRemote pause/duck
scripts/                                       # спайк-скрипты (OpenRouter/ZenMux)
docs/spike-results.md                          # результаты тестов моделей
```

## Спайки (проведено на M1 Pro)

См. `docs/spike-results.md`. Ключевые выводы:
- whisper.cpp turbo: RTF 0.45, ~1.7с/диктовка через `whisper-server` (без холодного старта)
- OpenRouter `/audio/transcriptions`: gpt-4o-mini-transcribe лучше всех распознаёт
  пути к файлам (`tests/test_auth.py`), ~1с, ~$0.00012 — лучший re-ASR для вайбкодинга
- ZenMux qwen3-asr-flash: аудио-вход сломан через их шлюз → не используем
- ZenMux qwen3-max (LLM-polish поверх текста): работает, ~4с

## Лицензия

MIT.
