# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.5] - 2026-09-14

> **Патч безопасности (Stages 0–4 ref-аудита)** поверх продуктового релиза 2.2.4 — работа коммита `593d732` (30 файлов), не продуктового `b63d2e6`. 184 unit-теста проходят (`swift test`, 0 failures). Локальная ad-hoc сборка `SingAR 2.2.5.dmg` (920K) + `SingAR 2.2.5.dmg.sha256` (SHA-256: `8db1ed4fbc13d1e9c7911878f0d4d8879689f7bf214c77cee677ecdd6afa8645`; `shasum -c` OK; предыдущий SHA `34f8e282…` недействителен). Коммит `e0fb1d6` — attempted-фикс презентации ([`NSHostingController`](Sources/SingAR/Services/WindowManager.swift:28) + self-frontmost refusal UX); **на живой установке runtime-дефекты не закрыл** (см. Known issues). Тег `v2.2.5` и GitHub Release **не ставить** до принятия runtime владельцем.

### Known issues (runtime, 2026-09-15)

Прогон владельца на живой установке 2026-09-15 — **runtime 2.2.5 не принят**, ручной чеклист (R2) не пройден:

- **Пустое окно при запуске** (Onboarding/Settings): остаётся после `e0fb1d6`. [`WindowManager`](Sources/SingAR/Services/WindowManager.swift:1) ранее использовал `NSHostingView` без layout; замена на [`NSHostingController`](Sources/SingAR/Services/WindowManager.swift:28) (presentation-only правка) на живой установке не помогла. Гипотезы (не подтверждены): не та сборка в `/Applications`, TCC mic/speech, SDK 27, иное.
- **Диктовка везде отказывает** generic-капсулой «Кликните в текстовое поле и повторите» ([`startRefusalMessage`](Sources/SingAR/Dictation/DictationController+Seams.swift:51)). Evidence лога: 19× `capture refused: focus/secureInput` в `~/Library/Application Support/SingAR/singar.log`; AX granted (`axUnavailable` не было). Отказ идёт из fail-closed гейта [`captureSessionTarget`](Sources/SingAR/Dictation/DictationFocusTarget.swift:106) (whitelist AXTextField/AXTextArea/AXComboBox/AXSearchField + settable; probe `nil` при frontmost == свой bundle) — **гейт не ослаблять**, отказ при сомнении является designed behavior Этапа 0.
- Откат на 2.2.4 в ту же минуту — диктовка заработала (регресс 2.2.5 подтверждён владельцем).
- Тег `v2.2.5` и GitHub Release не ставить, пока runtime красный (R4/R5 заморожены; push origin/main владельцем разрешён отдельно, тега всё равно нет).

### Security & Architecture (Ref-аудит, Этапы 0–3)
- **Ключи только в заголовках**: API-ключ передаётся исключительно в заголовке `x-goog-api-key` (аналог Bearer) — никогда в query-параметрах URL ([SecretStore.swift](Sources/SingAR/Settings/SecretStore.swift:145)).
- **Fail-closed AX-gate**: вставка/дозапись live-текста только в верифицированную owned-цель; при сомнении — отказ, а не запись «куда попало» ([DictationFocusTarget.swift](Sources/SingAR/Dictation/DictationFocusTarget.swift)).
- **Приватность-логи (SHA-seam)**: вместо текста диктовки — длина + SHA-256-хэш ([AppLogger.swift](Sources/SingAR/Services/AppLogger.swift)).
- **Keychain ThisDeviceOnly**: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + синхронизация выключена; миграция legacy-значений с read-back ([SecretStore.swift](Sources/SingAR/Settings/SecretStore.swift:198)).
- **MainActor-изоляция**: UI-состояние контроллера и VAD-события изолированы на главном акторе, аудио-пути не блокируют UI.
- **Декомпозиция DictationController**: session lifecycle / live-typing / finalize вынесены в расширения-pipeline ([DictationController+Seams.swift](Sources/SingAR/Dictation/DictationController+Seams.swift)).
- **Дебаунс проверки ключа**: `KeyVerifyDebouncer` устраняет шторм сетевых проверок при вводе ([KeyVerifyDebouncer.swift](Sources/SingAR/Settings/KeyVerifyDebouncer.swift)).
- **Стороны Option**: корректное различение Right-Option (keyCode 58/61) и Fn/Globe (63) ([HotkeyManager.swift](Sources/SingAR/Hotkey/HotkeyManager.swift:46)).
- **Минимальные entitlements**: только audio-input, speech-recognition, network.client ([SingAR.entitlements](Resources/SingAR.entitlements)).
- **CI-доказательность**: секрет-скан с негативным канареечным тестом и `build_dmg.sh --dry-run` в [ci.yml](.github/workflows/ci.yml).

## [2.2.4] - 2026-09-12

### Fixed
- **Мультимониторное позиционирование и гарантированная видимость капсулы**: индикатор статуса теперь всегда строго отображается на главном экране macOS (`NSScreen.screens.first`) под строкой меню. Если иконка меню-бара находится на главном экране — привязка строго под ней; если на другом мониторе — капсула плавно появляется по центру верхней строки главного экрана.
- **Плавная анимация Apple Fluid Droplet без сжатия окна**: устранено деструктивное сжатие окна AppKit до 40x12, ломавшее Auto Layout и скрывавшее содержимое капсулы. Вытекание из строки меню теперь реализовано через нативную трансформацию слоя `CALayer` (`translation` + `scale` $\to$ `identity` с пружинной кривой `(0.16, 1.0, 0.30, 1.0)`).
- **Надежная Smart Media Pause через CoreAudio + MediaRemote**: устранена проблема, из-за которой Яндекс.Музыка и фоновое видео в браузерах не ставились на паузу. Добавлена прямая детекция активных аудио-потоков через CoreAudio (`kAudioProcessPropertyIsRunningOutput`), снята блокирующая повторная проверка в `pauseBackgroundMedia()`. Теперь Яндекс.Музыка, YouTube, Firefox, Chrome, Safari и сторонние плееры мгновенно встают на паузу при старте речи и возобновляются после завершения диктовки. Полная безопасность от случайного запуска Apple Music сохранена.

## [2.2.3] - 2026-09-12

### Added
- **Аутентичная анимация Liquid Droplet из меню-бара**: эффект настоящей жидкой капли в стиле Apple — капля вязко вытягивается вниз прямо из иконки строки меню (`scaleY: 1.28, scaleX: 0.24`), затем под действием поверхностного натяжения расплывается в горизонтальную таблетку с мягким упругим затуханием (`scaleX: 1.08 -> 1.0`). При скрытии капля сжимается и втягивается обратно в меню-бар.
- **Интеллектуальная детекция Smart Media Resume (MediaRemote)**: устранено ложное срабатывание CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`. Теперь воспроизведение определяется напрямую через системный `MediaRemote` (`MRMediaRemoteGetNowPlayingApplicationPlaybackState == 1` и `playbackRate > 0.0`), безошибочно распознавая состояние Яндекс.Музыки, Spotify, YouTube и браузеров.
- **100% защита от случайного запуска Apple Music**: полностью удалена эмуляция аппаратных медиа-клавиш (`NX_KEYTYPE_PLAY`), вызывавшая автозапуск `Music.app` системным демоном `rcd`. Все команды `Play/Pause` идемпотентны, защищены проверками запущенного процесса и вызываются только для реально игравших треков.

## [2.2.2] - 2026-09-12

### Added
- **Liquid Glass HUD**: обновлённый дизайн плашки индикатора с полупрозрачным материалом `hudWindow`, каймой hairline border (15% white, 0.75pt) и плавной анимацией появления в виде капли из строки меню (droplet emergence).
- **Синхронизация цветов и иконок статус-бара**: все иконки индикатора статуса теперь строго соответствуют цветам меню-бара:
  - Запись: фирменный синий микрофон (`NSColor.systemCyan`) + синяя звуковая волна без зеленых артефактов.
  - Обработка: фиолетовые искорки (`NSColor.systemPurple` в стиле Apple Intelligence) слева + нативный крутящийся спиннер macOS (`NSProgressIndicator`) справа.
  - Вставка: нативная иконка стопки документов macOS (`doc.on.doc.fill`) зеленого цвета (`NSColor.systemGreen`).
  - Ошибка: нативная круглая иконка закрытия macOS (`xmark.circle.fill`) красного цвета (`NSColor.systemRed`).
- **Option Б для многозадачности (Focus Guard)**: при переключении окон во время диктовки live-печать мгновенно глушится, а черновик стирается через AX. При завершении диктовки исходное приложение возвращается в фокус, и весь текст вставляется целиком за 1 шаг (AX replace / Cmd+V) без лагов и посимвольного ввода.
- **Детектор тишины и подавление галлюцинаций фонового шума**: если пользователь не произносил слов (`vad.hasSpoken == false`), диктовка не запускает ASR и не тратит токены/сеть, а сразу выводит понятную ошибку «Речь не обнаружена».

## [2.2.1] - 2026-09-12

### Added
- Zero-Race Clipboard: отслеживание `pasteboard.changeCount`, окно восстановления увеличено до 600 мс, защита от затирания нового буфера пользователя и отмена таймеров восстановления (`cancelPendingRestore`).
- Instant AX Replace: мгновенная замена черновика на чистовик за 0 мс через Accessibility API (`kAXSelectedTextRangeAttribute` + `kAXSelectedTextAttribute`) без артефактов стирания Backspace.
- Whisper Hallucination Filter: фильтрация титров субтитров (DimaTorzok, Вадимова и др.) и фантомных точек тишины с 4-уровневой контекстной защитой от ложных срабатываний.
- Smart Media Resume: возобновление аудио только в том случае, если оно играло до старта диктовки.
- Focus Guard: настраиваемый режим в Настройках (`stopOnFocusLoss`) для свободного переключения окон во время речи с автоматической реактивацией целевого окна перед вставкой.
- HUD Capsule: контрастная белая иконка микрофона и статусов на темной плашке.
- UX Settings & MenuBar: независимая проверка API-ключей (Gemini, Groq, OpenRouter), Keychain-бейдж, относительное время истории («только что», «5 мин назад»), кнопка очистки истории, шорткаты `⌘,` и `⌘Q`.
- GitHub Community: формы баг-репортов и фич-реквестов (.github/ISSUE_TEMPLATE), 125 проходящих unit-тестов.

## [2.2.0] - 2026-09-07

> Локальная тестовая сборка; на GitHub не публиковалась.

### Added
- Keychain-миграция с read-back: legacy-удаление только после верифицированной записи ([SecretStoreMigrationTests.swift](Tests/SingARTests/SecretStoreMigrationTests.swift)).
- Esc-отмена в окне финализации через `DictationCancelGate` (Gate 2.6).
- Лимит записи 10 минут с автофинализацией полного live-текста без усечения.
- Кнопка открытия окна истории в меню.
- `resumeData` для возобновления прерванной загрузки модели.
- Окно истории: `WindowManager.showHistory()`.

### Fixed
- Whisper: таймаут subprocess 120 с + SIGKILL вместо вечного зависания.
- Gemini Live: cap очереди 200 чанков (DROP-OLDEST), переполнение больше не растит память.
- Медиа-гонка: pause-маркер привязан к generation сессии.
- История диктовки пишется только после подтверждённой вставки (AX-верифицированная цель).

### Changed
- `CodeLexiconNormalizer.normalize` применяется во всех ASR-путях (Gate 2.3).
- Launch-at-login переведён на `SMAppService` с откатом тумблера при ошибке.

### Security
- Privacy-логи: `redactedPreview` (длина + хэш) вместо текста, ротация 1 МБ, TTL 7 дней.
- Типизированные `CloudASRError` без раскрытия секретов в логах.
- Fail-closed AX-защита цели вставки: запись только в верифицированный элемент.

[2.2.5]: https://github.com/zevatov/SingAR/compare/2.2.4...2.2.5
[2.2.4]: https://github.com/zevatov/SingAR/compare/2.2.3...2.2.4
[2.2.3]: https://github.com/zevatov/SingAR/compare/2.2.2...2.2.3
[2.2.2]: https://github.com/zevatov/SingAR/compare/2.2.1...2.2.2
[2.2.1]: https://github.com/zevatov/SingAR/compare/2.2.0...2.2.1
[2.2.0]: https://github.com/zevatov/SingAR/compare/2.1.13...2.2.0
