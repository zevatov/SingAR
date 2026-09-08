import XCTest
@testable import SingAR

/// Gate 0.6: append/read/limit/corrupt JSON DictationHistory на temporary file URL.
/// Пользовательские данные не затрагиваются: изолированный temp-файл + UserDefaults suite.
final class DictationHistoryTests: XCTestCase {

    private var fileURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("singar-gate06-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        suiteName = "test.singar.history." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        if let suiteName { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func makeEntry(text: String, latencyMs: Int = 100) -> DictationHistoryEntry {
        DictationHistoryEntry(
            timestamp: Date(),
            provider: "test",
            model: "test-model",
            latencyMs: latencyMs,
            text: text
        )
    }

    // MARK: Append / read

    func testAppendThenReadBackFromFreshInstance() {
        let history = DictationHistory(fileURL: fileURL, defaults: defaults)
        history.append(makeEntry(text: "hello world", latencyMs: 250))

        // Файл записан синхронно → новый инстанс должен прочитать запись.
        let reloaded = DictationHistory(fileURL: fileURL, defaults: defaults)
        let entries = reloaded.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "hello world")
        XCTAssertEqual(entries.first?.latencyMs, 250)
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.averageLatencyMs, 250)
    }

    /// Gate 2.1: published-счётчики обновляются синхронно внутри append,
    /// обход main run loop больше не нужен.
    func testCountersStayInIsolatedSuite() {
        let history = DictationHistory(fileURL: fileURL, defaults: defaults)
        history.append(makeEntry(text: "abc"))
        history.append(makeEntry(text: "de"))

        XCTAssertEqual(history.totalDictations, 2)
        XCTAssertEqual(history.totalCharacters, 5)
        XCTAssertEqual(defaults.integer(forKey: "totalDictations"), 2)
        XCTAssertEqual(defaults.integer(forKey: "totalCharacters"), 5)
    }

    /// Gate 2.1: три append подряд без вращения main run loop —
    /// ни один инкремент счётчиков не теряется (раньше терялся).
    func testThreeConsecutiveAppendsWithoutRunLoopRotation() {
        let history = DictationHistory(fileURL: fileURL, defaults: defaults)
        history.append(makeEntry(text: "a", latencyMs: 10))
        history.append(makeEntry(text: "bb", latencyMs: 20))
        history.append(makeEntry(text: "ccc", latencyMs: 30))

        XCTAssertEqual(history.totalDictations, 3)
        XCTAssertEqual(history.totalCharacters, 6)
        XCTAssertEqual(history.items.count, 3)
        XCTAssertEqual(history.averageLatencyMs, 20)
        XCTAssertEqual(defaults.integer(forKey: "totalDictations"), 3)
        XCTAssertEqual(defaults.integer(forKey: "totalCharacters"), 6)
    }

    // MARK: Limit

    func testLimitKeepsMostRecentEntries() {
        let history = DictationHistory(fileURL: fileURL, defaults: defaults)
        for i in 0..<(DictationHistory.limit + 5) {
            history.append(makeEntry(text: "entry-\(i)"))
        }

        let entries = DictationHistory(fileURL: fileURL, defaults: defaults).entries()
        XCTAssertEqual(entries.count, DictationHistory.limit)
        XCTAssertEqual(entries.last?.text, "entry-\(DictationHistory.limit + 4)")
        XCTAssertEqual(entries.first?.text, "entry-5")
    }

    // MARK: Corrupt JSON

    func testCorruptJSONYieldsEmptyHistory() throws {
        // Создаём файл с мусором вместо JSON.
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a json".utf8).write(to: fileURL)

        let history = DictationHistory(fileURL: fileURL, defaults: defaults)
        XCTAssertTrue(history.entries().isEmpty)
        XCTAssertTrue(history.items.isEmpty)
    }

    func testAppendRecoversAfterCorruptJSON() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{broken".utf8).write(to: fileURL)

        let history = DictationHistory(fileURL: fileURL, defaults: defaults)
        history.append(makeEntry(text: "recovered"))

        let entries = history.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "recovered")
    }
}
