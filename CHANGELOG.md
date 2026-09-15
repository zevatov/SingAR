# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.5] - 2026-09-14

> **Патч безопасности (Stages 0–4 ref-аудита) + P0/P1 Runtime Fixes** поверх продуктового релиза 2.2.4 — 187 unit-тестов проходят (`swift test`, 0 failures). Локальная ad-hoc сборка `SingAR 2.2.5.dmg` (925K) + `SingAR 2.2.5.dmg.sha256` (SHA-256: `6b0d56386ee7c4f7af97111de0ebe4eaf314da0716f1a60f1c28d5e89be0db65`; `shasum -c` OK). Полностью закрыты баги: окно настроек при запуске устранено переходом на чистую точку входа AppKit (`@main enum SingARApp`), отказ диктовки и сброс финального текста (`snapshotMismatch`) в Electron/Antigravity/Obsidian/браузерах устранены через многоуровневый поиск `AXWebArea` и корректную обработку нетекстовых поверхностей. Закрыты P1-задачи: G1-1 (SHA256 модели), G1-3 (дисклеймер Migration Assistant), G4-4 (CI проверка версии), Fix C (debouncer). Тег `v2.2.5` и GitHub Release **не ставить** до финального ручного подтверждения владельцем.

### Resolved Runtime Defects (2026-09-15)

- **Всплывающее окно при запуске**: полностью устранено. Приложение переведено на нативную точку входа AppKit (`@main enum SingARApp`), что полностью исключило сцену `Settings` SwiftUI и автоматическое создание/восстановление окна `SingAR — Настройки`.
- **Отказ диктовки в окнах (Antigravity, Obsidian, Chrome, Firefox, VS Code)**: устранён. Добавлен рекурсивный поиск `ChromeAXNodeId` и `AXWebArea` (до глубины 3), а также распознавание стандартных окон сторонних приложений как `AXWebArea` с `isSettable = true`.
- **Сброс финального текста при замене (`snapshotMismatch`)**: устранён. Для `AXWebArea` значения `value` и `selectedRange` нормализованы как `nil`, что транслирует состояние в `.selectionUnavailable` и вызывает гарантированную безопасную замену черновика на отполированный текст через Backspaces + вставку.
- **G1-1**: зафиксирован официальный SHA-256 модели `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.
- **G1-3**: добавлен UX-дисклеймер о ThisDeviceOnly в настройках.
- **G4-4**: добавлен шаг проверки версии вне allowlist в CI workflow.
- **Fix C**: `verifyDebouncer` переведён на `private let` в `SettingsView`.

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
