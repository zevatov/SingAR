# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[2.2.0]: https://github.com/zevatov/SingAR/compare/2.1.13...2.2.0
