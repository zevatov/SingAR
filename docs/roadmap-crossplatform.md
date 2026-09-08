# 🗺 SingAR: Дорожная карта кроссплатформенности (Windows & Linux)

> Документ определяет архитектурный план адаптации **SingAR** для операционных систем **Windows 10/11** и **Linux (X11 / Wayland)** с сохранением ключевых фич: мгновенной вставки (Zero-Flicker Paste), нормализации кода (Vibe-Coding), HUD-индикатора и локального Whisper.

---

## 1. Архитектурная декомпозиция (Clean Architecture)

Чтобы проект поддерживал несколько ОС без дублирования кода, проект разделяется на:
1. **Платформонезависимое ядро (`SingARCore`)** — 100% чистая логика, компилируемая на любой системе.
2. **Платформенные адаптеры (`PlatformAdapters`)** — интерфейсы и их системные реализации.

```
┌─────────────────────────────────────────────────────────────┐
│                       SingAR Core                           │
│  - DictationController (State Machine & Generations)        │
│  - CodeLexiconNormalizer (npm, git, camelCase, snake_case)  │
│  - VoiceCommandParser (пунктуация, спецсимволы)             │
│  - VoiceActivityDetector (VAD: RMS & пороги тишины)         │
│  - WAVWriter & AudioPCMBuffer                               │
│  - Cloud ASR (Gemini 3.5 Live, Groq, OpenRouter)            │
│  - DictationHistory & DictationCancelGate                   │
└──────────────────────────────┬──────────────────────────────┘
                               │ relies on interfaces
┌──────────────────────────────▼──────────────────────────────┐
│                    Платформенные интерфейсы                 │
│  - TextInjectionProvider    - AudioCaptureProvider          │
│  - GlobalHotkeyProvider     - SecretStoreProvider           │
│  - HUDOverlayProvider       - LocalASRBackend               │
└──────┬───────────────────────┼───────────────────────┬──────┘
       │ macOS                 │ Windows               │ Linux
┌──────▼──────┐         ┌──────▼──────┐         ┌──────▼──────┐
│   macOS     │         │   Windows   │         │    Linux    │
│  Adapters   │         │  Adapters   │         │  Adapters   │
│ - CGEvent   │         │ - SendInput │         │ - uinput    │
│ - AVFound.  │         │ - WASAPI    │         │ - PipeWire  │
│ - Carbon    │         │ - RegHotKey │         │ - XDG Portal│
│ - Keychain  │         │ - CredMgr   │         │ - libsecret │
│ - Metal GPU │         │ - DirectML  │         │ - Vulkan    │
└─────────────┘         └─────────────┘         └─────────────┘
```

---

## 2. Спецификация системных адаптеров

### 2.1. Вставка текста и стирание (`TextInjectionProvider`)

| Платформа | Технология | Механизм работы |
|---|---|---|
| **macOS** | `CGEvent` + `NSPasteboard` | `cghidEventTap` для live-набора, `Cmd+V` для итогового чистовика |
| **Windows** | Win32 `SendInput()` + Clipboard | `SendInput` с `KEYEVENTF_UNICODE` для live-набора и `VK_BACK` для бэкспейсов. `SetClipboardData(CF_UNICODETEXT)` + `Ctrl+V` для чистовика |
| **Linux (X11)** | `XTest` / `xdotool` | Эмуляция нажатий через расширение `XTestFakeKeyEvent` |
| **Linux (Wayland)** | `/dev/uinput` или `wtype` / `ydotool` | Виртуальное устройство ядра Linux (`uinput`) для гарантированной работы сквозь изоляцию Wayland |

### 2.2. Глобальные хоткеи (`GlobalHotkeyProvider`)

| Платформа | Технология | Особенности |
|---|---|---|
| **macOS** | `NSEvent.addGlobalMonitor` | Отслеживание `flagsChanged` для правого Option / Fn |
| **Windows** | `RegisterHotKey()` или `SetWindowsHookEx(WH_KEYBOARD_LL)` | Низкоуровневый хук позволяет перехватывать одиночные модификаторы (Right Alt, R-Ctrl) |
| **Linux (X11)** | `XGrabKey()` на root window | Стандартный перехват клавиатуры X11 |
| **Linux (Wayland)** | `org.freedesktop.portal.GlobalShortcuts` | Нативный портал рабочего стола (GNOME 45+, KDE Plasma 6) без нарушения безопасности сессии |

### 2.3. Захват аудио с микрофона (`AudioCaptureProvider`)

* **Единый формат потока:** 16 000 Гц, 1 канал (Mono), Float32.
* **Windows:** **WASAPI** (Windows Audio Session API) в режиме `AUDCLNT_SHAREMODE_SHARED`.
* **Linux:** **PipeWire** (через нативный `libpipewire`) с fallback на **PulseAudio** / **ALSA**.

### 2.4. Безопасное хранилище API-ключей (`SecretStoreProvider`)

* **macOS:** Apple Keychain (`Security.framework`).
* **Windows:** **Windows Credential Manager** (`CredWriteW` / `CredReadW`) со скоупом `SingAR/APIKeys`.
* **Linux:** **libsecret** / Freedesktop Secret Service (интеграция с GNOME Keyring и KWallet).

### 2.5. HUD-индикатор статуса (`HUDOverlayProvider`)

* **Windows:** Безрамочное легковесное окно с эффектом **Mica / Acrylic** (`DwmSetWindowAttribute`), поверх всех окон (`WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`), расположенное в правом нижнем или верхнем углу. Трей через `Shell_NotifyIcon`.
* **Linux:** **GTK4 Layer Shell** (`gtk4-layer-shell` для Wayland поверх окон) или прозрачное окно с `_NET_WM_STATE_STAYS_ON_TOP` под X11. Трей через `libayatana-appindicator`.

### 2.6. Локальный движок Whisper (`LocalASRBackend`)

Используется универсальное ядро `whisper.cpp`:
* **macOS:** Бэкенд **Metal** (Apple Silicon Neural Engine & GPU).
* **Windows:** Бэкенд **DirectML** (для карт AMD/Intel/Nvidia) + **CUDA** (для Nvidia RTX).
* **Linux:** Бэкенд **Vulkan** (универсально) + **CUDA** / **ROCm**.

---

## 3. Этапы реализации (Milestones)

1. **Фаза 1: Рефакторинг ядра (`SingARCore`)**
   - Выделение платформонезависимых структур данных и ASR-клиентов в отдельный пакет.
   - Абстрагирование протоколов ввода, аудио и оверлея.
2. **Фаза 2: Linux порт**
   - Реализация PipeWire захвата аудио и эмуляции ввода через `uinput` / `wtype`.
   - Трей AppIndicator и запуск headless-тестов под Ubuntu.
3. **Фаза 3: Windows порт**
   - WASAPI захват звука и `SendInput` эмуляция.
   - Windows Credential Manager + Mica HUD оверлей.
   - DirectML ускорение `whisper.cpp`.
4. **Фаза 4: CI/CD и кроссплатформенный релиз**
   - Матрица GitHub Actions (`macos-14`, `ubuntu-24.04`, `windows-latest`).
   - Публичный мультиплатформенный релиз.
