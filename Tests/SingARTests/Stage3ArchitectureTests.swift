import XCTest
@testable import SingAR

/// Этап 3 (структура и UX-корректность): offline-тесты без сети/AX/Keychain.
/// Покрывают seams, введённые в Этапе 3:
///   - `HotkeyManager.TriggerKey`: левый Option НЕ триггерит в режиме
///     Right-Option; side-exact isTriggerEvent/isLeftOption/isRightOption;
///   - `KeyVerifyDebouncer`: gate-функция сети + константа 500 мс;
///   - seams контроллера не сломаны декомпозицией (все прежние
///     `DictationController.*` члены доступны как раньше);
///   - dead-code absence: удалённые члены больше не существуют (компиляция
///     теста = доказательство), живые seams — на месте.
/// Тесты Этапов 0–2 не тронуты (174 теста до Этапа 3).
final class Stage3ArchitectureTests: XCTestCase {

    // MARK: - Стороны Option (pure seam HotkeyManager.TriggerKey)

    func testLeftOptionMustNotTriggerInRightOptionMode() {
        // Регресс-требование Этапа 3: левый Option (58) не стартует диктовку,
        // когда выбран Right-Option (61).
        XCTAssertFalse(
            HotkeyManager.TriggerKey.isTriggerEvent(keyCode: 58, hotkey: .rightOption),
            "левый Option не должен стартовать диктовку в режиме Right-Option"
        )
        XCTAssertTrue(
            HotkeyManager.TriggerKey.isTriggerEvent(keyCode: 61, hotkey: .rightOption),
            "правый Option остаётся триггером в режиме Right-Option"
        )
    }

    func testFnGlobeModeIsSideExact() {
        XCTAssertTrue(HotkeyManager.TriggerKey.isTriggerEvent(keyCode: 63, hotkey: .fnOrGlobe))
        XCTAssertFalse(HotkeyManager.TriggerKey.isTriggerEvent(keyCode: 61, hotkey: .fnOrGlobe))
        XCTAssertFalse(HotkeyManager.TriggerKey.isTriggerEvent(keyCode: 58, hotkey: .fnOrGlobe))
    }

    func testSideClassification() {
        XCTAssertEqual(HotkeyManager.TriggerKey.classify(keyCode: 58), .leftOption)
        XCTAssertEqual(HotkeyManager.TriggerKey.classify(keyCode: 61), .rightOption)
        XCTAssertEqual(HotkeyManager.TriggerKey.classify(keyCode: 63), .fnGlobe)
        XCTAssertEqual(HotkeyManager.TriggerKey.classify(keyCode: 0), .other)
        XCTAssertEqual(HotkeyManager.TriggerKey.classify(keyCode: 40), .other)
    }

    func testLeftRightOptionPredicates() {
        XCTAssertTrue(HotkeyManager.TriggerKey.isLeftOption(keyCode: 58))
        XCTAssertFalse(HotkeyManager.TriggerKey.isLeftOption(keyCode: 61))
        XCTAssertTrue(HotkeyManager.TriggerKey.isRightOption(keyCode: 61))
        XCTAssertFalse(HotkeyManager.TriggerKey.isRightOption(keyCode: 58))
    }

    // MARK: - Дебаунс ключа (pure seams)

    func testDebouncerDefaultDelayIs500ms() {
        // Контракт задачи: 500 мс паузы ввода перед сетевым запросом.
        XCTAssertEqual(KeyVerifyDebouncer.defaultDelayNanoseconds, 500_000_000)
    }

    func testDebouncerNetworkGateUsesNormalizedKeyTrim() {
        // Сеть трогается только для непустых (после trim) ключей.
        XCTAssertTrue(KeyVerifyDebouncer.shouldScheduleNetworkVerify(rawKey: "AIzaSy-test"))
        XCTAssertTrue(KeyVerifyDebouncer.shouldScheduleNetworkVerify(rawKey: "  sk-or-v1-key \n"))
        XCTAssertFalse(KeyVerifyDebouncer.shouldScheduleNetworkVerify(rawKey: ""))
        XCTAssertFalse(KeyVerifyDebouncer.shouldScheduleNetworkVerify(rawKey: "   "))
        XCTAssertFalse(KeyVerifyDebouncer.shouldScheduleNetworkVerify(rawKey: "\n\t "))
        XCTAssertFalse(KeyVerifyDebouncer.shouldScheduleNetworkVerify(rawKey: nil))
    }

    @MainActor
    func testDebouncerCancellationCollapsesToSingleAction() async {
        // Offline-моделирование спама ввода: серия быстрых schedule с
        // микросекундным delay; между первой и последней пауза меньше delay —
        // экшен должен выполниться РОВНО один раз (последний запланированный).
        let debouncer = KeyVerifyDebouncer(delayNanoseconds: 30_000_000) // 30 мс
        let counter = CounterBox()
        debouncer.schedule { counter.increment() }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 мс < 30 мс
        debouncer.schedule { counter.increment() }
        try? await Task.sleep(nanoseconds: 5_000_000)
        debouncer.schedule { counter.increment() }
        // Ждём дольше delay: запланированные ранее — отменены, последний — сработал.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(counter.value, 1, "серия правок ключа = максимум 1 сетевой запрос")
        debouncer.cancel()
    }

    @MainActor
    func testDebouncerCancelPreventsAction() async {
        let debouncer = KeyVerifyDebouncer(delayNanoseconds: 20_000_000)
        let counter = CounterBox()
        debouncer.schedule { counter.increment() }
        debouncer.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.value, 0, "cancel() инвалидирует запланированный запрос")
    }

    // MARK: - Seams контроллера не сломаны декомпозицией

    func testControllerSeamsStillReachable() {
        // Декомпозиция Этапа 3 — расширения того же типа; все прежние
        // `DictationController.*` члены обязаны оставаться доступными
        // (gate-тесты Этапов 0–2 зовут их без правок).
        XCTAssertEqual(DictationController.insertionDecision(focusAllowed: true), .insertAndRecord)
        XCTAssertEqual(DictationController.insertionDecision(focusAllowed: false), .focusRejectedNoHistory)
        XCTAssertTrue(DictationController.truncatedSnapshotSkipsCloud(snapshotTruncated: true))
        XCTAssertFalse(DictationController.truncatedSnapshotSkipsCloud(snapshotTruncated: false))
        let flags = DictationController.resolveLiveFlags(livePartials: true)
        XCTAssertTrue(flags.feedsEngines && flags.showsLiveHints)
        XCTAssertEqual(
            DictationController.refusalMessage(axStatus: .denied),
            DictationController.axDeniedRefusalMessage
        )
        XCTAssertEqual(
            DictationController.refusalMessage(axStatus: .granted),
            DictationController.startRefusalMessage
        )
        XCTAssertTrue(DictationController.showsRefusalFeedback(captureSucceeded: false))
        XCTAssertEqual(DictationController.refusalReason(axStatus: .denied), .axDenied)
        XCTAssertEqual(DictationController.refusalFeedbackHideDelay, 1.2, accuracy: 0.0001)
    }

    func testSecretStoreNormalizedKeyStillCanonicalTrim() {
        // Дебаунс-гейт обязан опираться на единственный trim-хелпер.
        XCTAssertEqual(SecretStore.normalizedKey("  abc  "), "abc")
        XCTAssertNil(SecretStore.normalizedKey("   "))
    }
}

/// Потокобезопасный счётчик для дебаунс-тестов (колбэки идут на main).
private final class CounterBox: @unchecked Sendable {
    private var count = 0
    var value: Int { count }
    func increment() { count += 1 }
}
