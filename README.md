<div align="center">

# 🎙 SingAR

**Высокопроизводительный нативный голосовой ввод и vibe-кодинг для macOS**

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat&logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-F05138?style=flat&logo=swift)](https://swift.org)
[![Metal](https://img.shields.io/badge/Metal-GPU%20Accelerated-0078D7?style=flat)](https://developer.apple.com/metal/)
[![Tests](https://img.shields.io/badge/tests-187%20passing-brightgreen.svg)](https://github.com/zevatov/SingAR)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.2.5-brightgreen.svg)](https://github.com/zevatov/SingAR/releases)

</div>

---

## ⚡️ Что такое SingAR

**SingAR** — это сверхбыстрый, легковесный инструмент голосового ввода, созданный специально для разработчиков и вайбкодеров. Приложение живет в строке меню macOS, работает без иконки в Dock и вызывается по нажатию одной клавиши (по умолчанию — **Правый ⌥ Option** или **Fn / Globe**).

Приложение мгновенно расшифровывает речь, форматирует технический сленг, команды консоли, переменные `camelCase` / `snake_case` и пути к файлам, после чего вставляет готовый чистовик в активное окно редактора (Cursor, VS Code, Xcode, Терминал, браузер) за **1 миллисекунду**.

---

## 📊 Сравнение ASR-движков

| Движок | Где выполняется | Задержка | Приватность | Идеально для |
|---|---|---|---|---|
| **Whisper Turbo** | Metal GPU (Локально) | ~1.2 с | 100% Offline | Поездки, конфиденциальный код, 0 ключей |
| **Groq Whisper** | Облако (Groq LPU) | ~500 мс | Cloud | Максимальная скорость диктовки |
| **Gemini 3.5** | Google AI Studio | ~1.0 с | Cloud (Free) | Длинные фразы, русский сленг, точность |
| **GPT-4o Audio** | OpenRouter | ~1.5 с | Cloud | Сложный код, редкие термины и аббревиатуры |

---

## ✨ Ключевые возможности

### 1. Четыре мощных движка распознавания (переключение в 1 клик)
- ⚡️ **Whisper Large Turbo (Офлайн на Metal GPU):** Полная приватность и автономность без интернета. Модель на 1.6 ГБ выполняется напрямую на нейроядрах Apple Silicon (M1/M2/M3/M4) с аппаратным ускорением Metal.
- ✨ **Google Gemini 3.5 Transcribe:** Бесплатный облачный тариф через Google AI Studio. Отличный контекст и точность понимания сложной русской и смешанной речи.
- 🚀 **Groq Whisper Cloud:** Рекордно низкая задержка (< 800 мс) на тензорных чипах LPUs.
- 🧠 **OpenRouter GPT-4o Audio:** Мультимодальная точность расшифровки редких технических библиотек и аббревиатур.

### 2. Нормализатор кода для вайб-кодинга
Встроенный оффлайн-движок `CodeLexiconNormalizer` распознает профессиональный сленг и на лету преобразует фонетические фразы:
- *«нпм ран билд»* ➔ `npm run build`
- *«гит статус шорт»* ➔ `git status --short`
- *«точка енв»* ➔ `.env`
- *«докер компоуз ап»* ➔ `docker compose up -d`
- *«сайдбар точка тсикс»* ➔ `Sidebar.tsx`
- *«хэндл клик»* ➔ `handleClick`

### 3. Моментальная вставка (Zero-Flicker Paste)
В отличие от стандартных систем, печатающих текст посимвольно и затем медленно стирающих черновик бэкспейсом, SingAR вставляет готовый результат через буфер обмена за **1 мс** (`Cmd+V`). Никакого мерцания и скачков курсора.

### 4. Умный HUD-индикатор статуса
Компактная парящая темная капсула под строкой меню отображает состояние в реальном времени:
- **Запись:** Чисто белая иконка микрофона + живая звуковая волна.
- **Обработка:** Нативное крутящееся колесо загрузки (`NSProgressIndicator`) + «Обработка».
- **Вставка:** Зеленый маркер успешного ввода.
- **Ошибка:** Красный индикатор в случае отсутствия звука или сбоя сети.

### 5. Smart Media Control
Автоматически ставит воспроизведение музыки и видео (Spotify, Apple Music, YouTube) на паузу при нажатии горячей клавиши и возобновляет звук после завершения фразы.

### 6. Защита от обрезки речи (VAD grace-tail)
Встроенный «хвост тишины» (`graceSeconds = 0.7`) в детекторе речевой активности продолжает подавать аудио в распознаватель после конца речи, поэтому последнее слово успевает финализироваться даже при быстром отпускании клавиши ([VoiceActivityDetector.swift](Sources/SingAR/Audio/VoiceActivityDetector.swift:43)).

### 7. Полная отмена по Esc
Нажатие `Esc` во время записи или обработки полностью отменяет сессию: черновик живого набора стирается, локальные и облачные операции распознавания прерываются, в историю ничего не попадает и текст не вставляется. Обычное отпускание горячей клавиши завершает диктовку штатно (финализация и вставка результата).

### 8. Лимиты работы
- **Длительность записи:** до 10 минут на сессию. При достижении лимита накопление аудио для финального прохода останавливается (live-набор продолжается).
- **Локальный Whisper:** жёсткий таймаут 120 секунд на subprocess. Зависший или сломанный `whisper-cli` прерывается, диктовка откатывается к live/локальному тексту вместо вечного зависания.

---

## 🖥 Системные требования

- macOS 14.0 (Sonoma) или новее
- Компьютер Mac на базе Apple Silicon (M1, M2, M3, M4)
- Разрешения:
  - **Микрофон** (для захвата аудио)
  - **Универсальный доступ / Accessibility** (для вставки текста в сторонние приложения)

---

## 🚀 Установка

1. Скачайте образ **`SingAR 2.2.5.dmg`** и файл контрольной суммы **`SingAR 2.2.5.dmg.sha256`** из раздела [Releases](https://github.com/zevatov/SingAR/releases).
2. Откройте DMG и перетащите `SingAR 2.2.5.app` в папку `Applications`.
3. Запустите приложение.
   > **Ad-hoc подпись — осознанный GitHub-путь (без Developer ID и нотаризации по условию владельца):**
   > Это типично для GitHub-проектов с открытым исходным кодом. Исходники и релизы: https://github.com/zevatov/SingAR.
   > macOS Gatekeeper при первом запуске покажет предупреждение, т.к. нотаризации нет — это ожидаемо.
   > - **Вариант 1 (рекомендуется):** по иконке приложения **правой кнопкой мыши (Control-клик) → Открыть**, затем **Открыть** в диалоге Gatekeeper.
   > - **Вариант 2 (терминал):** снимите карантин `xattr -d com.apple.quarantine "/Applications/SingAR 2.2.5.app"` (точечно) или `xattr -cr "/Applications/SingAR 2.2.5.app"` (полная очистка).
   > - **Проверка целостности:** `shasum -a 256 -c "SingAR 2.2.5.dmg.sha256"` в папке со скачанным DMG.
   > - **Связка ключей (Keychain):** При запросе доступа к `com.singar.app` введите пароль от вашего Mac и нажмите **«Разрешать всегда»** — это системный механизм macOS для безопасного сохранения ваших API-ключей.
4. Выдайте разрешения в **Системные настройки → Конфиденциальность и безопасность**:
   - **Микрофон** (для записи голоса)
   - **Универсальный доступ** (для вставки распознанного текста в активное окно)

---

## 🛠 Сборка из исходного кода

Для самостоятельной сборки потребуется Xcode Command Line Tools или Swift PM:

```bash
# Клонирование репозитория
git clone https://github.com/zevatov/SingAR.git
cd SingAR

# Сборка debug-бинарника
swift build

# Быстрая проверка релиз-процесса без сборки (CI dry-run)
./scripts/build_dmg.sh --dry-run

# Сборка production DMG-установщика (ad-hoc подпись, без нотаризации)
./scripts/build_dmg.sh
```

Готовый образ диска появится в корне проекта: `SingAR 2.2.5.dmg` + `SingAR 2.2.5.dmg.sha256`.
Версия (`CFBundleShortVersionString`, имя DMG) берётся только из `Sources/SingAR/Config/AppVersion.swift` (`AppVersion.current`) — хардкод-фолбэка нет, при отсутствии версии сборка падает. Предыдущий DMG сохраняется как `*.prev.dmg` для rollback.

---

## 🧪 Тестирование

```bash
swift test
```

Пакет содержит тестовую цель `SingARTests` — **184 юнит-теста** (XCTest) покрывают: Zero-Race буфер обмена (`TextInjector`), нативное AX-замещение текста (`DictationFocusTargetGate`), защиту от галлюцинаций Whisper (`CodeLexiconNormalizer`), режим свободной многозадачности (`FocusGuard`), нормализатор кода, парсер голосовых команд, детектор речевой активности (VAD), WAV Writer, историю диктовки, миграцию Keychain (`SecretStoreMigration`), бюджет захвата аудио (`AudioCaptureBudget`), Gate отмены (`DictationCancelGate`), AX-защиту цели вставки, типизированные облачные ошибки (`CloudASRError`, `GeminiLiveError`), Smart Media Resume CoreAudio + Media Remote, Apple Fluid Droplet индикатор, а также security-регрессы Этапов 0–3 ref-аудита (`Stage0SecurityFixes`, `Stage1Security`, `Stage2Stability`, `Stage3Architecture`).

---

## 📁 Структура проекта

```text
SingAR/
├── .github/                   # CI/CD Workflows и Issue Templates
├── docs/                      # Документация, Release Notes, Roadmap
├── Resources/                 # AppIcon, Entitlements
├── scripts/
│   └── build_dmg.sh           # Скрипт сборки DMG с авто-версионированием
├── Sources/SingAR/
│   ├── App/                   # Точка входа, AppDelegate, Жизненный цикл
│   ├── ASR/                   # Движки ASR (Whisper Metal, Gemini, Groq, OpenRouter)
│   ├── Audio/                 # Захват аудио (CoreAudio, VAD, SoundFeedback)
│   ├── Commands/              # Голосовые команды
│   ├── Config/                # AppVersion (2.2.5)
│   ├── Dictation/             # DictationController, Normalizer, History
│   ├── Extensions/            # SwiftUI-расширения (Color+Brand)
│   ├── Hotkey/                # Перехват глобальных горячих клавиш
│   ├── Media/                 # Управление системным медиаплеером
│   ├── Overlay/               # DictationIndicator (HUD-капсула)
│   ├── Permissions/           # PermissionChecker (TCC / Privacy)
│   ├── Services/              # AppLogger, ModelDownloadManager, WindowManager
│   ├── Settings/              # AppSettings, SecretStore (Keychain)
│   ├── StatusBar/             # StatusBarController, AppStatus
│   ├── TextInjection/         # TextInjector (CGEvent, Pasteboard)
│   └── Views/                 # SwiftUI Views (SettingsView, MenuBarView)
├── Tests/
│   └── SingARTests/           # 184 юнит-теста (swift test)
```

---

## 🔒 Privacy & Data Handling

- **По умолчанию — всё локально.** Рекомендуемый режим работы — локальный **Whisper Turbo**: аудио обрабатывается на вашем устройстве (Metal GPU) и не покидает его. Сеть используется только если вы сами выбрали и настроили облачный провайдер (BYOK — Bring Your Own Key: Google Gemini, Groq, OpenRouter).
- **Ключи — в macOS Keychain.** Все пользовательские API-ключи хранятся исключительно в системном Keychain (Legacy-значения из UserDefaults мигрируются один раз и удаляются после успешной записи) и никогда не логируются.
- **Логи без текста диктовки.** Локальный лог `~/Library/Application Support/SingAR/singar.log` не содержит распознанного текста — вместо него пишутся только длина и короткий SHA-256-хэш. Ротация файла при достижении 1 МБ, архивы старше 7 дней удаляются (хранится максимум 1 архив).

---

## 📄 Лицензия

Проект распространяется по лицензии [MIT](LICENSE). Copyright © 2026 SingAR contributors.
