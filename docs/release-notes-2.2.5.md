# SingAR 2.2.5: Примечания к выпуску

| Параметр | Значение |
|---|---|
| Версия | 2.2.5 ([AppVersion.swift](../Sources/SingAR/Config/AppVersion.swift:4)) |
| Дата сборки | 14 сентября 2026 г. |
| Статус | **Локальная ad-hoc сборка** — тег `v2.2.5` и GitHub Release ещё не ставились |
| Целевая платформа | macOS 14.0+ (Apple Silicon M1/M2/M3/M4) |

---

## Что нового в v2.2.5

Патч безопасности поверх продуктового релиза 2.2.4: закрытие находок ref-аудита (Этапы 0–4), работа коммита `593d732` (30 файлов). Продуктовые фичи 2.2.4 (мультимониторный HUD, Fluid Droplet, Smart Media Pause) описаны в [`release-notes-2.2.4.md`](release-notes-2.2.4.md) и в 2.2.5 не менялись.

### 1. Ключи только в заголовках (header-only)
- **API-ключ вне URL**: ключ Gemini передаётся исключительно в заголовке `x-goog-api-key` (аналог Bearer) — никогда в query-параметрах, поэтому ключ не попадает в логи прокси/серверов ([SecretStore.swift](../Sources/SingAR/Settings/SecretStore.swift:145)).

### 2. Fail-closed Accessibility-гейт
- **Вставка только в верифицированную owned-цель**: дозапись live-текста и финальная вставка выполняются только в проверенную AX-цель; при любом сомнении — отказ операции, а не запись «куда попало» ([DictationFocusTarget.swift](../Sources/SingAR/Dictation/DictationFocusTarget.swift)).

### 3. Приватность-логи и Keychain ThisDeviceOnly
- **SHA-seam в логах**: вместо текста диктовки локальный лог пишет только длину и SHA-256-хэш ([AppLogger.swift](../Sources/SingAR/Services/AppLogger.swift)).
- **Ключи не покидают устройство**: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, синхронизация iCloud Keychain выключена, миграция legacy-значений из UserDefaults с read-back ([SecretStore.swift](../Sources/SingAR/Settings/SecretStore.swift:198)).

### 4. MainActor-изоляция и декомпозиция контроллера
- **UI не блокируется аудио-путями**: состояние контроллера и VAD-события изолированы на главном акторе (`@MainActor`).
- **Декомпозиция DictationController**: session lifecycle / live-typing / finalize вынесены в расширения-pipeline ([DictationController+Seams.swift](../Sources/SingAR/Dictation/DictationController+Seams.swift)); фасад сокращён, зоны ответственности разделены.

### 5. CI-доказательность
- **Секрет-скан в CI**: негативный канареечный тест (`?key=test`) и `build_dmg.sh --dry-run` в workflow ([ci.yml](../.github/workflows/ci.yml)) — утечка секрета или сломанный релиз-конвейер краснят пайплайн автоматически.

### 6. Тестовое покрытие
- **184 unit-теста проходят** (`swift test`, 0 failures), включая security-регрессы Этапов 0–3: [`Stage0SecurityFixesTests`](../Tests/SingARTests/Stage0SecurityFixesTests.swift), [`Stage1SecurityTests`](../Tests/SingARTests/Stage1SecurityTests.swift), [`Stage2StabilityTests`](../Tests/SingARTests/Stage2StabilityTests.swift), [`Stage3ArchitectureTests`](../Tests/SingARTests/Stage3ArchitectureTests.swift).

---

## Контрольные суммы и артефакты

> **TBD после сборки.** Полная DMG для 2.2.5 ещё не собиралась — значения ниже заполняются после `./scripts/build_dmg.sh`.

- **Образ диска:** `SingAR 2.2.5.dmg` (путь появится в корне проекта)
- **Размер файла:** TBD
- **SHA-256:** TBD (публикуется рядом как `SingAR 2.2.5.dmg.sha256`)
- **Подпись:** Ad-hoc hardened runtime с entitlements (`Resources/SingAR.entitlements`)
- **Команда сборки:** `./scripts/build_dmg.sh`
- **Тег / GitHub Release:** не ставились — по плану после ручного чеклиста и сборки DMG (см. [`ref-audit-remaining-fixes.md`](ref-audit-remaining-fixes.md), §1)
