import Foundation
import SwiftUI

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

    private let defaults = UserDefaults.standard
    private let totalDictationsKey = "totalDictations"
    private let totalCharactersKey = "totalCharacters"

    @Published var totalDictations: Int = 0
    @Published var totalCharacters: Int = 0
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
        self.totalDictations = defaults.integer(forKey: totalDictationsKey)
        self.totalCharacters = defaults.integer(forKey: totalCharactersKey)
        self.items = load()
    }

    var averageLatencyMs: Int {
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0) { $0 + $1.latencyMs }
        return total / items.count
    }

    func append(_ entry: DictationHistoryEntry) {
        lock.lock()
        var entries = load()
        entries.append(entry)
        entries = Array(entries.suffix(Self.limit))

        let newDictations = totalDictations + 1
        let newCharacters = totalCharacters + entry.text.count
        defaults.set(newDictations, forKey: totalDictationsKey)
        defaults.set(newCharacters, forKey: totalCharactersKey)

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
            self.totalDictations = newDictations
            self.totalCharacters = newCharacters
            self.items = entries
        }
    }

    func reload() {
        lock.lock()
        let entries = load()
        let dictations = defaults.integer(forKey: totalDictationsKey)
        let characters = defaults.integer(forKey: totalCharactersKey)
        lock.unlock()

        DispatchQueue.main.async {
            self.totalDictations = dictations
            self.totalCharacters = characters
            self.items = entries
        }
    }

    func clear() {
        lock.lock()
        defaults.set(0, forKey: totalDictationsKey)
        defaults.set(0, forKey: totalCharactersKey)
        try? FileManager.default.removeItem(at: fileURL)
        lock.unlock()

        DispatchQueue.main.async {
            self.totalDictations = 0
            self.totalCharacters = 0
            self.items = []
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
