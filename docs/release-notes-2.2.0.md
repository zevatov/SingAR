# Release Notes — SingAR 2.2.0

| Поле | Значение |
|---|---|
| Версия | 2.2.0 ([AppVersion.swift](../Sources/SingAR/Config/AppVersion.swift:4)) |
| Дата | 2026-09-07 |
| Статус | **Локальная тестовая сборка. На GitHub не публиковалась; публичным релизом не считается.** |
| SHA-256 (DMG) | `db25ebdb5a1c336acc065a025bd8308d45749af90ee8dd5c242d6392bdf39608` |
| Тесты | 108 юнит-тестов, цель `SingARTests` ([swift test](../Package.swift:1)) |

## Что нового (Gate 0–2)

### Приватность и хранение
- **Keychain + миграция с read-back** ([SecretStore.swift](../Sources/SingAR/Settings/SecretStore.swift:37)): legacy-значение из UserDefaults удаляется только после успешной записи и совпадающего чтения обратно; при любом расхождении legacy сохраняется ([SecretStoreMigrationTests.swift](../Tests/SingARTests/SecretStoreMigrationTests.swift:16)).
- **Privacy-логи**: превью текста только как `redactedPreview` (длина + короткий SHA-256) ([AppLogger.swift](../Sources/SingAR/Services/AppLogger.swift:51)); ротация лога при 1 МБ, TTL архивов 7 дней.

### Надёжность финализации и отмена
- **Whisper timeout 120 с + SIGKILL** ([ASREngine.swift](../Sources/SingAR/ASR/ASREngine.swift:419)): зависший `whisper-cli` завершается (terminate → grace 2 с → SIGKILL), диктовка откатывается к live/локальному тексту.
- **Esc-отмена, включая окно финализации** ([DictationCancelGate.swift](../Sources/SingAR/Dictation/DictationCancelGate.swift:21), Gate 2.6): pending-окно открывается синхронно в `stopDictation` до 120 мс hand-off — Esc больше не теряется.
- **Лимит 10 минут с автофинализацией без усечения** ([AudioRecorder.swift](../Sources/SingAR/Audio/AudioRecorder.swift:70), [DictationController.swift](../Sources/SingAR/Dictation/DictationController.swift:160)): при исчерпании бюджета усечённый снапшот никогда не уходит в облачные проходы — коммитится полный live-текст.

### ASR и текст
- **Gemini queue cap 200** ([GeminiLiveEngine.swift](../Sources/SingAR/ASR/GeminiLiveEngine.swift:24)): bounded pre-connect буфер, DROP-OLDEST; типизированная причина сбоя через `lastLiveError()`.
- **`CloudASRError`** ([CloudASRError.swift](../Sources/SingAR/ASR/CloudASRError.swift:7), Gate 1.7): типизированные ошибки вместо `nil`; контракт fallback не изменён.
- **Polish typed errors** (Gate 2.5): ошибка полировки откатывает к неполированному тексту; actionable-ошибки показываются в капсуле.
- **Normalize во всех путях** (Gate 2.3, [ASREngine.swift](../Sources/SingAR/ASR/ASREngine.swift:10)): `CodeLexiconNormalizer.normalize` применён и к локальному Speech, и к live-движкам.

### Вставка и защита цели
- **AX-защита цели вставки** ([DictationFocusTarget.swift](../Sources/SingAR/Dictation/DictationFocusTarget.swift:6)): fail-closed владение целью (PID + семантическая идентичность) с повторной верификацией перед каждой мутацией.
- **История только после подтверждённой вставки** ([DictationController.swift](../Sources/SingAR/Dictation/DictationController.swift:54)): отклонённая цель ⇒ нет записи истории и success-HUD.
- **Кнопка истории** в меню ([MenuBarView.swift](../Sources/SingAR/Views/MenuBarView.swift:195) → [WindowManager.swift](../Sources/SingAR/Services/WindowManager.swift:110)).

### Прочее
- **SMAppService** для launch-at-login с синхронизацией и откатом тумблера ([LaunchAtLoginManager.swift](../Sources/SingAR/Settings/LaunchAtLoginManager.swift:8)).
- **voice-modifiers и media race**: pause-маркер привязан к generation сессии ([DictationController.swift](../Sources/SingAR/Dictation/DictationController.swift:28)); поздний callback не активирует паузу для чужой сессии.
- **resumeData**: прерванная загрузка модели возобновляется после перезапуска ([ModelDownloadManager.swift](../Sources/SingAR/Services/ModelDownloadManager.swift:34)).

## Известные ограничения
- **Ad-hoc подпись / Gatekeeper**: сборка не нотаризована; при первом запуске возможен ручной обход Gatekeeper.
- **Runtime CGEvent / AX / Keychain не верифицированы** на этой сборке — покрыты только юнит-тестами офлайн-логики.
- Сборка **не для публичного распространения**.
- Минимальная ОС: **macOS 14 (Sonoma)**, только **Apple Silicon**.
