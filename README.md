# SingAR

Нативная замена Apple-диктовке для macOS. Приоритет — скорость и оптимизация под
Apple Silicon: локальный ASR для мгновенного отклика, облако (ZenMux) опционально.
Зажал клавишу диктовки → наговорил → текст вставился в активное окно.

## Статус

Каркас собирается и запускается как menu-bar agent. Реализовано:
- Меню в статус-баре с одним глифом-индикатором (idle/слушает/распознаёт/облако/готово).
- Dropdown со всеми тогглами, состояние в UserDefaults.
- Скелет пайплайна (хоткей → аудио+VAD → ASR → вставка) со стабами подсистем.

В работе (см. `// TODO(Mx)` в коде): хоткей, захват аудио, whisper.cpp, live-партиалы,
голосовые команды, медиа-пауза, облачный шаг.

## Сборка

```bash
./build.sh            # debug → build/SingAR.app
./build.sh release    # release
open build/SingAR.app
```

Требования: macOS 14+, Xcode (Swift 6.3). Только Apple Silicon оптимизирован.

## Структура

```
Sources/SingAR/
├── main.swift / AppDelegate.swift        # точка входа, LSUIElement agent
├── Settings/AppSettings.swift            # все тогглы → UserDefaults
├── StatusBar/                            # NSStatusItem глиф + меню
├── Dictation/DictationController.swift   # оркестратор цикла диктовки
├── Hotkey/HotkeyManager.swift            # CGEventTap (Fn/Globe)
├── Audio/AudioRecorder.swift             # AVAudioEngine + VAD
├── ASR/ASREngine.swift                   # whisper.cpp + ZenMuxASR
├── TextInjection/TextInjector.swift      # pasteboard + Cmd+V
├── Commands/VoiceCommandParser.swift     # голосовые команды / макросы
└── Media/MediaController.swift           # MediaRemote pause/duck
```

## Архитектура

```
[хоткей] → AVAudioEngine → VAD ─┬─→ whisper.cpp(CoreML) → транскрипт
                                  │      ├─→ парсер голосовых команд
                                  │      └─→ (опц.) ZenMux: qwen3-asr-flash / Qwen3-Max
                                  └─→ pasteboard + Cmd+V → активное окно
                                       на старте: MediaRemote pause · на выходе: resume
```
