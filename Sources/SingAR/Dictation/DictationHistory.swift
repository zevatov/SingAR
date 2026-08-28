import Foundation

struct DictationHistoryEntry: Codable, Equatable, Identifiable {
    var id: String { "\(timestamp.timeIntervalSince1970)-\(latencyMs)" }
    let timestamp: Date
    let provider: String
    let model: String
    let latencyMs: Int
    let text: String
}

final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()
    static let limit = 50

    @Published var items: [DictationHistoryEntry] = []

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SingAR", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("history.json")
        }
        self.items = load()
    }

    func append(_ entry: DictationHistoryEntry) {
        lock.lock()
        var entries = load()
        entries.append(entry)
        entries = Array(entries.suffix(Self.limit))

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[SingAR] history write failed code=history_write_failed error=%@", String(describing: error))
        }
        lock.unlock()

        DispatchQueue.main.async {
            self.items = entries
        }
    }

    func entries() -> [DictationHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    private func load() -> [DictationHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) else {
            return []
        }
        return Array(entries.suffix(Self.limit))
    }
}
