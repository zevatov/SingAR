# SingAR 2.2.5: Примечания к выпуску

| Параметр | Значение |
|---|---|
| Версия | 2.2.5 ([AppVersion.swift](../Sources/SingAR/Config/AppVersion.swift:4)) |
| Дата сборки | 14 сентября 2026 г. |
| Статус | **Локальная ad-hoc сборка; runtime 2.2.5 владельцем НЕ принят (прогон 2026-09-15)** — тег `v2.2.5` и GitHub Release **не ставить** (см. Known issues ниже) |
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
- **187 unit-тестов проходят** (`swift test`, 0 failures), включая security-регрессы Этапов 0–3: [`Stage0SecurityFixesTests`](../Tests/SingARTests/Stage0SecurityFixesTests.swift), [`Stage1SecurityTests`](../Tests/SingARTests/Stage1SecurityTests.swift), [`Stage2StabilityTests`](../Tests/SingARTests/Stage2StabilityTests.swift), [`Stage3ArchitectureTests`](../Tests/SingARTests/Stage3ArchitectureTests.swift), [`StartRefusalFeedbackTests`](../Tests/SingARTests/StartRefusalFeedbackTests.swift).

### 7. Устранение дефектов рантайма (2026-09-15)
- **Точка входа AppKit**: `@main enum SingARApp` полностью устраняет авто-создание окна SwiftUI Settings (`SingAR — Настройки`) при старте. Меню-бар работает чисто, без всплывающих окон.
- **Детекция веб- и сторонних приложений**: `LiveAXFocusProbe` рекурсивно ищет `ChromeAXNodeId` и `AXWebArea` (до глубины 3) и распознаёт стандартные окна (`AXStandardWindow`) сторонних приложений.
- **Корректная финализация**: для `AXWebArea` `value` и `selectedRange` нормализованы как `nil`, что транслирует состояние в `.selectionUnavailable` и вызывает гарантированную безопасную замену черновика на отполированный текст через Backspaces + вставку.

---

## Контрольные суммы и артефакты

DMG собрана `./scripts/build_dmg.sh`:

- **Образ диска:** `SingAR 2.2.5.dmg` — в корне проекта
- **Размер файла:** 925K
- **SHA-256:** `6b0d56386ee7c4f7af97111de0ebe4eaf314da0716f1a60f1c28d5e89be0db65` — публикуется рядом как `SingAR 2.2.5.dmg.sha256`, `shasum -a 256 -c` OK.
- **Подпись:** Ad-hoc hardened runtime с entitlements (`Resources/SingAR.entitlements`); `spctl` rejection ожидаем (нотаризации нет)
- **Команда сборки:** `./scripts/build_dmg.sh`
- **Тег / GitHub Release:** **не ставить** — runtime не принят (R2 blocked; см. Known issues выше и [`ref-audit-remaining-fixes.md`](ref-audit-remaining-fixes.md), §1)
