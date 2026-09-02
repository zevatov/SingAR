<div align="center">

# 🎙 SingAR

**Высокопроизводительный нативный голосовой ввод и vibe-кодинг для macOS**

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat&logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.3-F05138?style=flat&logo=swift)](https://swift.org)
[![Metal](https://img.shields.io/badge/Metal-GPU%20Accelerated-0078D7?style=flat)](https://developer.apple.com/metal/)
[![Version](https://img.shields.io/badge/version-2.1.13-brightgreen.svg)](https://github.com/zevatov/SingAR)

</div>

---

## ⚡️ Что такое SingAR

**SingAR** — это сверхбыстрый, легковесный инструмент голосового ввода, созданный специально для разработчиков и вайбкодеров. Приложение живет в строке меню macOS, работает без иконки в Dock и вызывается по нажатию одной клавиши (по умолчанию — **Правый ⌥ Option** или **Fn / Globe**).

Приложение мгновенно расшифровывает речь, форматирует технический сленг, команды консоли, переменные `camelCase` / `snake_case` и пути к файлам, после чего вставляет готовый чистовик в активное окно редактора (Cursor, VS Code, Xcode, Терминал, браузер) за **1 миллисекунду**.

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

### 6. Защита от обрезки речи (120ms CoreAudio Drain)
Встроенный буфер задержки предотвращает проглатывание последних слогов при быстром отпускании клавиши.

---

## 🖥 Системные требования

- macOS 14.0 (Sonoma) или новее
- Компьютер Mac на базе Apple Silicon (M1, M2, M3, M4)
- Разрешения:
  - **Микрофон** (для захвата аудио)
  - **Универсальный доступ / Accessibility** (для вставки текста в сторонние приложения)

---

## 🚀 Установка

1. Скачайте образ **`SingAR 2.1.13.dmg`**.
2. Откройте DMG и перетащите `SingAR 2.1.13.app` в папку `Applications`.
3. Запустите приложение.
4. При первом запуске выдайте необходимые разрешения в **Системные настройки → Конфиденциальность и безопасность → Универсальный доступ**.

---

## 🛠 Сборка из исходного кода

Для самостоятельной сборки потребуется Xcode Command Line Tools или Swift PM:

```bash
# Клонирование репозитория
git clone https://github.com/zevatov/SingAR.git
cd SingAR

# Сборка debug-бинарника
swift build

# Сборка production DMG-установщика
./scripts/build_dmg.sh
```

Готовый подписанный образ диска появится в корне проекта: `SingAR 2.1.13.dmg`.

---

## 📂 Структура проекта

```text
SingAR/
├── Package.swift                  # Конфигурация Swift PM
├── Resources/
│   └── SingAR.entitlements        # Entitlements (Audio, Hardened Runtime)
├── scripts/
│   └── build_dmg.sh               # Скрипт сборки DMG с авто-версионированием
├── Sources/SingAR/
│   ├── App/                       # Точка входа, AppDelegate, Жизненный цикл
│   ├── ASR/                       # Движки ASR (Whisper Metal, Gemini, Groq, OpenRouter)
│   ├── Audio/                     # Захват аудио (CoreAudio, VAD, SoundFeedback)
│   ├── Commands/                  # Голосовые команды
│   ├── Config/                    # AppVersion (2.1.13)
│   ├── Dictation/                 # DictationController, Normalizer, History
│   ├── Hotkey/                    # Перехват глобальных горячих клавиш
│   ├── Media/                     # Управление системным медиаплеером
│   ├── Overlay/                   # DictationIndicator (HUD-капсула)
│   ├── Permissions/               # PermissionChecker (TCC / Privacy)
│   ├── Services/                  # AppLogger, ModelDownloadManager, WindowManager
│   ├── Settings/                  # AppSettings, SecretStore (Keychain)
│   ├── StatusBar/                 # StatusBarController, AppStatus
│   ├── TextInjection/             # TextInjector (CGEvent, Pasteboard)
│   └── Views/                     # SwiftUI Views (SettingsView, MenuBarView)
```

---

## 🔒 Безопасность и Приватность

- Все пользовательские API-ключи (Google Gemini, Groq, OpenRouter) сохраняются исключительно в системном хранилище **macOS Keychain** и никогда не логируются.
- В режиме **Local Whisper Turbo** аудиопоток обрабатывается локально на вашем GPU и не покидает пределы вашего устройства.
- Локальные логи диагностики сохраняются в `~/Library/Application Support/SingAR/singar.log`.

---

## 📄 Лицензия

Proprietary / Private. Все права защищены.
