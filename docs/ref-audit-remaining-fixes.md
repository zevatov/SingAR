# SingAR — Остаточные фиксы после Этапов 0–4

> Финальный локальный handoff по остаточным фиксам. Дата: 2026-09-13 (обновлено 2026-09-15). Источник версии только [`AppVersion.current`](Sources/SingAR/Config/AppVersion.swift:4) = `2.2.5`.
> Состояние: `swift test` — 187 тестов, 0 failures; Этапы 0–4 **completed** в репозитории.
> **Runtime 2.2.5 (прогон 2026-09-15)**: дефекты (окно при старте, отказ диктовки в окнах и сброс финального текста) устранены в исходниках, пересобрана DMG `SingAR 2.2.5.dmg` (925K, SHA-256 `6b0d56386ee7c4f7af97111de0ebe4eaf314da0716f1a60f1c28d5e89be0db65`), установлена в `/Applications/SingAR 2.2.5.app`. R2 готов к ручному тестированию владельцем (§1, §1а).
> Дистрибуция: GitHub + ad-hoc подпись, Developer ID и нотаризации нет (осознанное решение).
> Obsidian-sync Этапов 3–4: закрыта триажем владельца 2026-09-14 (Stage3/Stage4 Completed созданы в vault); локальный §9 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:337) отстаёт — см. §3.
> Родительский хендоф: [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:1). Код в этой задаче не менялся.

## 0. Что уже закрыто (не делать снова)

Все находки ref-аудита Этапов 0–4 — **fixed**, таблицы в §2 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:20):

- **C1–C4**: ключ только в заголовке [`x-goog-api-key`](Sources/SingAR/Settings/SecretStore.swift:104), fail-closed AX-гейт [`captureSessionTarget`](Sources/SingAR/Dictation/DictationFocusTarget.swift:95), SHA256-seam загрузки модели (со оговоркой G1-1, см. §2), Keychain [`keychainAccessible`](Sources/SingAR/Settings/SecretStore.swift:198) = ThisDeviceOnly.
- **H1–H6**: [`@MainActor`](Sources/SingAR/Dictation/DictationController.swift:34)-изоляция + декомпозиция контроллера (фасад 97 строк + 4 extension-файла), VAD [`NSLock`](Sources/SingAR/Audio/VoiceActivityDetector.swift:49) + once-per-segment, уровень только на main через [`setLevel`](Sources/SingAR/Overlay/DictationIndicator.swift:197), гарантированная отмена сети [`cancellableData`](Sources/SingAR/ASR/ASREngine.swift:316), снятие tap в [`AudioRecorder`](Sources/SingAR/Audio/AudioRecorder.swift:12) при ошибке/deinit, CI секрет-скан [`secret-scan`](.github/workflows/ci.yml:17) с канарейкой [`?key=test`](.github/workflows/ci.yml:35).
- **M1–M6**: минимальные [`SingAR.entitlements`](Resources/SingAR.entitlements:1), side-exact Option через [`TriggerKey`](Sources/SingAR/Hotkey/HotkeyManager.swift:23) (keyCode 58/61/63), дебаунс [`KeyVerifyDebouncer`](Sources/SingAR/Settings/KeyVerifyDebouncer.swift:13) 500 мс, DROP-OLDEST ранних кадров [`preConnectPlan`](Sources/SingAR/ASR/GeminiLiveEngine.swift:148), ранний выход finalize [`turnCompleted`](Sources/SingAR/ASR/GeminiLiveEngine.swift:62), капсула унифицирована на [`screens.first`](Sources/SingAR/Overlay/DictationIndicator.swift:237).
- **L1–L5**: плейсхолдер заменён на `https://github.com/zevatov/SingAR`, версия из единого [`AppVersion.current`](Sources/SingAR/Config/AppVersion.swift:4) во всех коллерах, DMG-конвейер verify+SHA+rollback в [`build_dmg.sh`](scripts/build_dmg.sh:166), бейдж README `tests-184` = факт ([`README.md`](README.md:10)), санитизация логов [`sanitize`](Sources/SingAR/Services/AppLogger.swift:47) + права `0600` ([`enforceOwnerOnlyPermissions`](Sources/SingAR/Services/AppLogger.swift:40)).

Повторно чинить перечисленное не нужно — сверяться с таблицами §2 и Acceptance §3–§7 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:1).

## 1. Перед релизом (сделать руками, это не код-этап)

| ID | Что | Зачем | Как | Acceptance |
|---|---|---|---|---|
| R1 | ✅ Выполнен: `593d732` (30 файлов) + `a385887` (bump 2.2.5 docs) + `e0fb1d6` (NSHostingController + self-frontmost refusal UX) | Воспроизводимое состояние для DMG/тега | Коммиты последовательно на локальном main; дерево исходников чистое после `e0fb1d6` | `git status` чист после `e0fb1d6`; `git log` содержит `593d732` → `a385887` → `e0fb1d6`; тега нет |
| R2 | ⏳ **Ready for testing (2026-09-15)**: дефекты устранены, сборка установлена | Ручной прогон на живой системе: хоткей Right-Option (61) в Antigravity, VS Code, Obsidian, браузерах, терминале | Прогон чеклиста [`manual-testing-checklist.md`](docs/manual-testing-checklist.md:46) владельцем | Все пункты чеклиста `[x]`, диктовка и замена работают без сбоев |
| R3 | ✅ DMG собрана: `SingAR 2.2.5.dmg` 925K, SHA-256 `6b0d56386ee7c4f7af97111de0ebe4eaf314da0716f1a60f1c28d5e89be0db65`, `shasum -c` OK | Артефакт для ручного прогона; verify-гейт и `.sha256` exercised ([`build_dmg.sh`](scripts/build_dmg.sh:196)) | `./scripts/build_dmg.sh` (без флагов); ad-hoc подпись, `spctl` rejected ожидаем без нотаризации — не считать провалом | Механика сборки OK, SHA актуализирован во всех docs |
| R4 | ⛔ Не стартовать: тег `v2.2.5` только после закрытия R2 | Тег фиксирует состояние до проверки runtime; перевыпуск тега после находок — худший сценарий | Сверка версии везде ([`AppVersion.swift`](Sources/SingAR/Config/AppVersion.swift:4), [`CHANGELOG.md`](CHANGELOG.md:8), [`release-notes-2.2.5.md`](docs/release-notes-2.2.5.md:1), DMG-имя, бейдж [`README.md`](README.md:10)) заготовлена, но `git tag` не выполнять, пока R2 blocked | Факт 2026-09-15: тега нет; ставить строго после R2+R3 |
| R5 | ⛔ Не стартовать: GitHub Release | Пользователи не должны получать артефакт с живыми runtime-багами (§1а) | После закрытия R2: Release для тега `v2.2.5` с `SingAR 2.2.5.dmg` + `.sha256` + Gatekeeper-секция из [`README.md`](README.md:94) | Факт 2026-09-15: Release нет; публиковать строго после R2 |
| R6 | Push `origin/main` разрешён владельцем (2026-09-15, выполняет devops после docs); Actions-прогон — после push | Ветка G4-3 (прогон [`ci.yml`](.github/workflows/ci.yml:1) в Actions) не закрыта | Push без тега разрешён отдельно от R4/R5; после push проверить Actions: `secret-scan` → `test` (187/0) | Push выполнен владельцем; тега при этом нет; при red — чинить workflow до зелёного |

Порядок жёсткий: R1 → R2 → R3 → R4 → R5 → R6. Тег и Release не ставить до R2/R3. Факт 2026-09-15: R1/R3 выполнены, R2 blocked, R4–R6 заморожены; push `origin/main` разрешён владельцем отдельно и тега не создаёт.

## 1а. Runtime defects 2.2.5 (2026-09-15, причина R2 blocked)

Симптомы на живой установке (владелец, 2026-09-15), **оба остались после `e0fb1d6`**:

1. **Пустое окно при запуске** (Onboarding/Settings). [`WindowManager`](Sources/SingAR/Services/WindowManager.swift:1) собирал контент через `NSHostingView` без layout; `e0fb1d6` перевёл на [`NSHostingController`](Sources/SingAR/Services/WindowManager.swift:28) — presentation-only правка, на живой установке не помогла.
2. **Диктовка везде отказывает** generic-капсулой «Кликните в текстовое поле и повторите» ([`startRefusalMessage`](Sources/SingAR/Dictation/DictationController+Seams.swift:51)).

Evidence (лог до патча): `~/Library/Application Support/SingAR/singar.log` — 19× `capture refused: focus/secureInput`; AX granted — `axUnavailable` не встречалось. Откат на 2.2.4 в ту же минуту — диктовка заработала (регресс принадлежит 2.2.5-цепочке).

Что НЕ менял `e0fb1d6`: fail-closed гейт [`captureSessionTarget`](Sources/SingAR/Dictation/DictationFocusTarget.swift:106) — whitelist {AXTextField, AXTextArea, AXComboBox, AXSearchField} + `settable`; probe возвращает `nil` при frontmost == свой bundle. Коммит — presentation/UX-only; **фиксом его не считать**.

Гипотезы (не подтверждены; диагностику ведёт владелец через Gemini): не та сборка в `/Applications` (старый бинарь), TCC mic/speech, SDK 27, иное.

**Правило: fail-closed гейт НЕ ослаблять** — отказ при сомнении является designed behavior Этапа 0 (находка C2, [`DictationFocusTarget.swift`](Sources/SingAR/Dictation/DictationFocusTarget.swift:106)); починять причину отказа, а не снимать whitelist/settable-требования.

## 2. Желательно до/сразу после выкладки (маленький код/docs)

| ID | Что | Зачем | Как | Acceptance |
|---|---|---|---|---|
| G1-1 | Зафиксировать официальный SHA256 апстрима в [`expectedSHA256`](Sources/SingAR/Services/ModelDownloadManager.swift:19) — сейчас `nil` | Сеам готов, но в режиме пропуска: подменённый `ggml-large-v3-turbo.bin` (~1.6 ГБ) пройдёт как валидный; fail-closed не активен | Взять хэш доверенного источника ([`downloadURL`](Sources/SingAR/Services/ModelDownloadManager.swift:12) → `ggerganov/whisper.cpp`, страницу HF-релиза/репо), сверить перекачкой, положить 64-hex в константу; опционально добавить `verifyExistingModel()` в [`refreshStatus`](Sources/SingAR/Services/ModelDownloadManager.swift:68) | [`expectedSHA256`](Sources/SingAR/Services/ModelDownloadManager.swift:19) ≠ `nil`; скачанный файл с чужим хэшем → `.error` без `moveItem` (гейт [`isDownloadedFileValid`](Sources/SingAR/Services/ModelDownloadManager.swift:226)) |
| G1-3 | UX-текст в [`SettingsView`](Sources/SingAR/Views/SettingsView.swift:48) про Keychain ThisDeviceOnly и Migration Assistant | ThisDeviceOnly не покидает устройство: после переноса на новый Mac через Migration Assistant ключ не переедет — пользователь должен знать, что ключ вводится заново | Добавить подпись/тултип в секцию ключа Settings: «Ключ хранится только на этом Mac и не переносится Migration Assistant — после переноса введите ключ заново» | Текст виден в UI настроек; формулировка не обещает «синхронизацию»; регресс Этапов 0–3 не внесён |
| G4-4 | CI grep на хардкод версии `2.2.5` вне allowlist | Дрейф версии между [`AppVersion`](Sources/SingAR/Config/AppVersion.swift:4), CHANGELOG, release-notes и бейджем ловится автоматом, а не человеком | В [`ci.yml`](.github/workflows/ci.yml:1) (job `secret-scan` или отдельный step): `grep -REnI '2\.2\.5'` по `Sources/` `scripts/` `README.md` — совпадения вне allowlist (только [`AppVersion.swift`](Sources/SingAR/Config/AppVersion.swift:4), [`CHANGELOG.md`](CHANGELOG.md:8), [`release-notes-2.2.5.md`](docs/release-notes-2.2.5.md:1)) → FATAL; имя версии в паттерн вынести в переменную шага | CI красный при подсовывании `2.2.5` в посторонний файл; зелёный на чистом дереве; allowlist задокументирован комментарием |

## 3. Obsidian — закрыто триажем владельца 2026-09-14 (в этой задаче vault не вызывался)

История: MCP-сервер Obsidian был сломан (HTTP 404 «Session not found»: Этап 3-сессия — 5+ попыток list/read; Этап 4-сессия — vault не вызывался по решению владельца). **Триаж владельца 2026-09-14**: MCP восстановлен, записи `4_Spaces/Projects/SingAR/RefAudit_Stage3_Completed.md` и `4_Spaces/Projects/SingAR/RefAudit_Stage4_Completed.md` созданы в vault (маркеры `ZOO_PIPELINE_SINGAR_STAGE3` / `ZOO_PIPELINE_SINGAR_STAGE4`). Долг «Этапы 3–4 не синхронизированы» на стороне vault закрыт.

Остаток: локальный §9 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:337) отстаёт от факта (в таблице остались blocked-статусы) — актуализируется точечной docs-правкой handoff-файла. Pending-файлы `RefAudit_Stage3_Pending.md` и `RefAudit_Stage4_Pending.md` НЕ удалять/не переименовывать (исторические); delete/move/rename запрещены правилом владельца. Правила работы с vault прежние: targeted get до записи, allowlist vault-relative targets, exact marker `ZOO_PIPELINE_`, одна мутация за раз + immediate read-back.

## 4. Техдолг после релиза (не критично)

| ID | Что | Якорь | Примечание |
|---|---|---|---|
| G3-1 | Swift 6 actor-isolation warnings | [`DictationController+FinalizePipeline.swift`](Sources/SingAR/Dictation/DictationController+FinalizePipeline.swift:159) | Унаследованы от исходного Task-блока, сборке не мешают; чистка требует семантического решения по изоляции (§6.5 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:271)) |
| G3-2 | Избыточные подусловия `liveTypingSuppressedDueToFocusShift` | [`DictationController+LiveTypingPipeline.swift`](Sources/SingAR/Dictation/DictationController+LiveTypingPipeline.swift:20), [`DictationController+SessionLifecycle.swift`](Sources/SingAR/Dictation/DictationController+SessionLifecycle.swift:278) | Чистка меняет семантику гашения при focus-shift; live-ветки в обоих режимах [`stopOnFocusLoss`](Sources/SingAR/Settings/AppSettings.swift:87) — трогать только с runtime-тестом |
| G3-3 | Дубли NSLog vs [`AppLogger.log`](Sources/SingAR/Services/AppLogger.swift:81) | [`AppLogger.swift`](Sources/SingAR/Services/AppLogger.swift:86) + NSLog в realtime/tap-путях | Унификация не входила в Этап 3 из-за риска изменения лог-поведения realtime; делать отдельной задачей с проверкой санитизации |
| G2-3 | Ранний выход [`finalize`](Sources/SingAR/ASR/GeminiLiveEngine.swift:410) может резать длинный хвост | drain 0.85 с vs [`graceSeconds`](Sources/SingAR/Audio/VoiceActivityDetector.swift:43) 0.7 с vs silence 0.6 с — не связаны единой политикой | Тюнинг только ручным тестом на живой диктовке; продуктовое решение о политике конца хода не принято |
| G4-1 | `gitleaks`/`trufflehog` вместо собственного grep | [`SECRET_SCAN_PATTERN`](.github/workflows/ci.yml:25) | При добавлении нужен allowlist на SHA-хэши DMG в release-notes (ложные срабатывания на hex-строки) |
| G4-2/G4-5 | Тег/полная DMG не exercised; runtime только ручной чеклист | [`--require-tag`](.github/workflows/ci.yml:62), [`manual-testing-checklist.md`](docs/manual-testing-checklist.md:46) | Закрывается выполнением R3–R6 из §1; macOS-раннер без Keychain/AX остаётся ограничением — живые гейты всегда ручные |
| — | Roadmap Windows/Linux | [`roadmap-crossplatform.md`](docs/roadmap-crossplatform.md:1) | Отдельный проект, к ref-аудиту v2.2.4 отношения не имеет |

## 5. Чего не делать

- **Не чинить Obsidian вслепую** и не вызывать vault_* до подтверждённой починки MCP — правило «write без read-back = blocked»; ложный success недопустим (§3, §9 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:337)).
- **Не ставить тег `v2.2.4` до R2 (чеклист) и R3 (DMG)**: тег фиксирует состояние до проверки runtime и артефакта; перевыпуск тега после находок — худший сценарий.
- **Не считать нотаризацию обязательной**: ad-hoc + Gatekeeper-инструкция в [`README.md`](README.md:94) + SHA рядом — осознанная модель владельца; `spctl`-rejection при ad-hoc ожидаем и не блокирует релиз.
- **Не переписывать §1–§7 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:1)**: этот файл — только добавка, родительский хендоф остаётся источником по этапам.
- **Не «улучшать» закрытые C/H/M/L-находки без нового аудита** — таблицы §2 родительского хендофа зафиксированы с evidence.

## 6. Rollback

- Этот файл (если tracked): `git checkout -- docs/ref-audit-remaining-fixes.md`; если untracked: `rm docs/ref-audit-remaining-fixes.md`.
- Ссылка-добавка в родительском хендофе: `git checkout -- docs/ref-audit-handoffs.md` (после коммита R1 откат только этой строки — revert соответствующего коммита docs).
- Код/скрипты Этапов 0–4 этим хендофом не откатываются: rollback-пути этапов — в §3.6/§4.6/§5.6/§6.6/§7.6 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:1), выполняются только отдельным решением владельца.
- DMG-rollback (справочно, после R3): `mv -f 'SingAR 2.2.4.prev.dmg' 'SingAR 2.2.4.dmg'` (см. [`build_dmg.sh`](scripts/build_dmg.sh:201)).

---

*Создано 2026-09-13; обновлено 2026-09-15 (docs-only, techwriter): шапка, R1–R6 актуализированы (R1/R3 done, R2 blocked, R4–R6 заморожены), добавлен §1а runtime defects, §3 переписан под триаж 2026-09-14; код не менялся, Obsidian в этой задаче не вызывался. Якоря §1а проверены чтением в этой сессии: [`captureSessionTarget`](Sources/SingAR/Dictation/DictationFocusTarget.swift:106), [`startRefusalMessage`](Sources/SingAR/Dictation/DictationController+Seams.swift:51), [`NSHostingController`](Sources/SingAR/Services/WindowManager.swift:28); SHA-256 — из `SingAR 2.2.5.dmg.sha256`, совпадает с владельческим. Историческая приписка 2026-09-13: якоря [`AppVersion.swift`](Sources/SingAR/Config/AppVersion.swift:4)=`2.2.4`; [`expectedSHA256`](Sources/SingAR/Services/ModelDownloadManager.swift:19)=`nil`; поиск ThisDeviceOnly в `Sources/SingAR/Settings|Views` — 0 вхождений UX-текста о Migration Assistant (только [`SecretStore.swift`](Sources/SingAR/Settings/SecretStore.swift:198)); `liveTypingSuppressedDueToFocusShift` — 7 вхождений (3 файла, якоря в §4); NSLog — [`AppLogger.swift`](Sources/SingAR/Services/AppLogger.swift:86) + realtime-пути. Статусы Этапов 0–4 и 184 теста — по evidence [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:1).*
