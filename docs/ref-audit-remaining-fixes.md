# SingAR — Остаточные фиксы после Этапов 0–4

> Финальный локальный handoff по остаточным фиксам. Дата: 2026-09-13 (обновлено 2026-09-14). Источник версии только [`AppVersion.current`](Sources/SingAR/Config/AppVersion.swift:4) = `2.2.5`.
> Состояние: `swift test` — 184 теста, 0 failures (сумма 141+20+13+10, evidence Этапов 0–3 в [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:1)); Этапы 0–4 **completed** в репозитории.
> Дистрибуция: GitHub + ad-hoc подпись, Developer ID и нотаризации нет (осознанное решение).
> Obsidian-sync Этапов 3–4 НЕ выполнена (MCP сломан — HTTP 404 «Session not found»), долг в §3 этого файла и §9 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:337).
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
| R1 | ✅ Выполнен локально: коммит `593d732` (30 файлов) | Этапы выполнены в рабочем дереве; без коммита нет воспроизводимого состояния для DMG/тега | Закоммичено код+docs Этапов 0–4 одним коммитом `593d732`; дерево после него было чистое. Текущий uncommitted bump версии 2.2.5 (docs-sync) — отдельный коммит поверх | `git status` был чист после `593d732`; `git log` содержит изменения всех scope-файлов Этапов 0–4 (списки в §3.3/§4.2/§5.2/§6.2/§7.2 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:1)) |
| R2 | Ручной чеклист [`manual-testing-checklist.md`](docs/manual-testing-checklist.md:46) | Runtime (CGEvent/AX/Keychain/WS) автоматом не покрыт — только ручной прогон (G1-4/G2-1/G4-5) | Прогнать интерактивный чеклист на собранной сборке: хоткей Right-Option (keyCode 61) vs левый Option (58), TextEdit/VS Code вставки, Esc-отмена, офлайн-режим, Gatekeeper-обход по [`README.md`](README.md:94) | Все пункты чеклиста отмечены `[x]`; отказ-в-старте и fail-closed поведение подтверждены на живой сборке |
| R3 | Сборка DMG `./scripts/build_dmg.sh` (не `--dry-run`) + SHA256 рядом | Полная DMG под 2.2.5 ещё не собиралась (G4-2); verify-гейт и `.sha256` в скрипте ([`build_dmg.sh`](scripts/build_dmg.sh:196)) не exercised на реальном артефакте 2.2.5 | `./scripts/build_dmg.sh` (без флагов) → дождаться `codesign --verify --deep --strict` fatal-гейта → зафиксировать `SingAR 2.2.5.dmg` + `SingAR 2.2.5.dmg.sha256`; предыдущий DMG уходит в `*.prev.dmg` (rollback-путь скрипта) | DMG создан; `.sha256` рядом; `shasum -a 256 -c` проходит; `spctl` informational-rejection ожидаем без нотаризации — не считать провалом |
| R4 | Тег `v2.2.5` только после совпадения версии везде | Единственный источник — [`AppVersion.current`](Sources/SingAR/Config/AppVersion.swift:4); дрейф ломает [`--require-tag`](.github/workflows/ci.yml:62)-ветку CI и DMG-имена | Сверить `2.2.5` в [`AppVersion.swift`](Sources/SingAR/Config/AppVersion.swift:4), [`CHANGELOG.md`](CHANGELOG.md:8), [`release-notes-2.2.5.md`](docs/release-notes-2.2.5.md:1), DMG-имени и бейдже [`README.md`](README.md:10) → затем `git tag v2.2.5` и push | `git tag` содержит `v2.2.5`; grep версии вне allowlist пуст (см. G4-4 в §2); тег ставится строго после R2+R3 |
| R5 | GitHub Release: DMG + `.sha256` + Gatekeeper-инструкция | Пользователи дистрибуции получают артефакт и способ его проверить без нотаризации | Создать Release для тега `v2.2.5`: приложить `SingAR 2.2.5.dmg` + `.sha256`; в описание вставить Gatekeeper-секцию из [`README.md`](README.md:94) (Control-клик → Открыть, `xattr -d com.apple.quarantine`, SHA-проверка) | Release опубликован; оба файла прикреплены; SHA в описании совпадает с `.sha256`; ссылки в README/release-notes ведут на Release |
| R6 | Дождаться зелёного GitHub Actions (закрытие G4-3) | Прогон нового [`ci.yml`](.github/workflows/ci.yml:1) в Actions не зафиксирован — evidence только локальные | Push R1+R4 → открыть вкладку Actions → дождаться `secret-scan` → `test` (184/0) на теге; при red — чинить workflow до зелёного | Оба job зелёные на теге `v2.2.5`; скриншот/ссылка на прогон приложена к Release |

Порядок жёсткий: R1 → R2 → R3 → R4 → R5 → R6. Тег и Release не ставить до R2/R3.

## 2. Желательно до/сразу после выкладки (маленький код/docs)

| ID | Что | Зачем | Как | Acceptance |
|---|---|---|---|---|
| G1-1 | Зафиксировать официальный SHA256 апстрима в [`expectedSHA256`](Sources/SingAR/Services/ModelDownloadManager.swift:19) — сейчас `nil` | Сеам готов, но в режиме пропуска: подменённый `ggml-large-v3-turbo.bin` (~1.6 ГБ) пройдёт как валидный; fail-closed не активен | Взять хэш доверенного источника ([`downloadURL`](Sources/SingAR/Services/ModelDownloadManager.swift:12) → `ggerganov/whisper.cpp`, страницу HF-релиза/репо), сверить перекачкой, положить 64-hex в константу; опционально добавить `verifyExistingModel()` в [`refreshStatus`](Sources/SingAR/Services/ModelDownloadManager.swift:68) | [`expectedSHA256`](Sources/SingAR/Services/ModelDownloadManager.swift:19) ≠ `nil`; скачанный файл с чужим хэшем → `.error` без `moveItem` (гейт [`isDownloadedFileValid`](Sources/SingAR/Services/ModelDownloadManager.swift:226)) |
| G1-3 | UX-текст в [`SettingsView`](Sources/SingAR/Views/SettingsView.swift:48) про Keychain ThisDeviceOnly и Migration Assistant | ThisDeviceOnly не покидает устройство: после переноса на новый Mac через Migration Assistant ключ не переедет — пользователь должен знать, что ключ вводится заново | Добавить подпись/тултип в секцию ключа Settings: «Ключ хранится только на этом Mac и не переносится Migration Assistant — после переноса введите ключ заново» | Текст виден в UI настроек; формулировка не обещает «синхронизацию»; регресс Этапов 0–3 не внесён |
| G4-4 | CI grep на хардкод версии `2.2.5` вне allowlist | Дрейф версии между [`AppVersion`](Sources/SingAR/Config/AppVersion.swift:4), CHANGELOG, release-notes и бейджем ловится автоматом, а не человеком | В [`ci.yml`](.github/workflows/ci.yml:1) (job `secret-scan` или отдельный step): `grep -REnI '2\.2\.5'` по `Sources/` `scripts/` `README.md` — совпадения вне allowlist (только [`AppVersion.swift`](Sources/SingAR/Config/AppVersion.swift:4), [`CHANGELOG.md`](CHANGELOG.md:8), [`release-notes-2.2.5.md`](docs/release-notes-2.2.5.md:1)) → FATAL; имя версии в паттерн вынести в переменную шага | CI красный при подсовывании `2.2.5` в посторонний файл; зелёный на чистом дереве; allowlist задокументирован комментарием |

## 3. Починить потом — Obsidian (не блокер релиза)

MCP-сервер Obsidian сломан: HTTP 404 «Session not found» (Этап 3-сессия — 5+ попыток list/read; Этап 4-сессия — vault не вызывался по решению владельца). Никаких vault_* вызовов до починки. Статус и таблица записей — в §9 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:337).

После починки MCP (правило владельца: targeted get до записи, allowlist `4_Spaces/Projects/SingAR/`, exact marker `ZOO_PIPELINE_`, одна мутация за раз + immediate read-back):

1. targeted get `4_Spaces/Projects/SingAR/RefAudit_Stage3_Pending.md` → write `4_Spaces/Projects/SingAR/RefAudit_Stage3_Completed.md` с маркером `ZOO_PIPELINE_SINGAR_STAGE3` + immediate read-back (содержание подготовлено в §9 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:370))
2. targeted get `4_Spaces/Projects/SingAR/RefAudit_Stage4_Pending.md` → write `4_Spaces/Projects/SingAR/RefAudit_Stage4_Completed.md` с маркером `ZOO_PIPELINE_SINGAR_STAGE4` + immediate read-back (содержание — из §7 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:282))
3. Обновить §9 [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:337): blocked → written

Pending-файлы `RefAudit_Stage3_Pending.md` и `RefAudit_Stage4_Pending.md` НЕ удалять (исторические). Delete/move/rename запрещены правилом владельца.

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

*Создано 2026-09-13, docs-only задача (techwriter): код не менялся, Obsidian не вызывался (MCP сломан). Все якоря `файл:строка` проверены чтением в этой сессии: [`AppVersion.swift`](Sources/SingAR/Config/AppVersion.swift:4)=`2.2.4`; [`expectedSHA256`](Sources/SingAR/Services/ModelDownloadManager.swift:19)=`nil`; поиск ThisDeviceOnly в `Sources/SingAR/Settings|Views` — 0 вхождений UX-текста о Migration Assistant (только [`SecretStore.swift`](Sources/SingAR/Settings/SecretStore.swift:198)); `liveTypingSuppressedDueToFocusShift` — 7 вхождений (3 файла, якоря в §4); NSLog — [`AppLogger.swift`](Sources/SingAR/Services/AppLogger.swift:86) + realtime-пути. Статусы Этапов 0–4 и 184 теста — по evidence [`ref-audit-handoffs.md`](docs/ref-audit-handoffs.md:1).*
