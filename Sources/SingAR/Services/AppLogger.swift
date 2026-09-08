import Foundation
import CryptoKit

final class AppLogger {
    static let shared = AppLogger()

    // Privacy-safe rotation: keep the active log small and expire old files.
    private static let maxLogBytes: UInt64 = 1_000_000 // 1 MB
    private static let maxArchivedFiles = 1 // active + 1 archived = max 2 files
    private static let logTTLSeconds: TimeInterval = 7 * 24 * 3600 // 7 days

    private let logFile: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.singar.logger", qos: .utility)
    private let dateFormatter: DateFormatter

    static var logFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SingAR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("singar.log")
    }

    private init() {
        self.logFile = Self.logFileURL
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: logFile)
        self.fileHandle?.seekToEndOfFile()

        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        log("🚀 SingAR initialized v\(AppVersion.current)")
    }

    func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        NSLog("[SingAR] %@", message)

        queue.async { [weak self] in
            guard let self, let data = line.data(using: .utf8) else { return }
            self.rotateIfNeeded()
            self.fileHandle?.write(data)
        }
    }

    /// Privacy-safe preview: never log full user text; expose length + short hash only.
    static func redactedPreview(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "<len=\(text.count) hash=\(hash)>"
    }

    // MARK: - Rotation & TTL

    /// Must be called on `queue`. Rotates the active file when it exceeds the
    /// size cap and deletes archived/expired files past the size or TTL limits.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? UInt64, size >= Self.maxLogBytes else {
            purgeExpiredArchives()
            return
        }

        // Close current handle, archive, reopen fresh.
        fileHandle?.closeFile()
        let archivedURL = logFile.deletingLastPathComponent()
            .appendingPathComponent("singar.log.1")
        try? fm.removeItem(at: archivedURL)
        try? fm.moveItem(at: logFile, to: archivedURL)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        purgeExpiredArchives()
    }

    /// Must be called on `queue`. Enforces archive count cap and 7-day TTL.
    private func purgeExpiredArchives() {
        let fm = FileManager.default
        let dir = logFile.deletingLastPathComponent()
        let prefix = logFile.deletingPathExtension().lastPathComponent + ".log."

        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let archives = entries
            .filter { $0.hasPrefix(prefix) }
            .sorted { $0 < $1 }

        // TTL: delete archives older than 7 days.
        let cutoff = Date().addingTimeInterval(-Self.logTTLSeconds)
        for name in archives {
            let url = dir.appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let modified = attrs[.modificationDate] as? Date,
               modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }

        // Count cap: keep at most maxArchivedFiles newest archives.
        let remaining = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted { $0 > $1 }
        for name in remaining.dropFirst(Self.maxArchivedFiles) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
