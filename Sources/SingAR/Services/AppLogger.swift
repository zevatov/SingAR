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
            FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        Self.enforceOwnerOnlyPermissions(at: logFile)
        self.fileHandle = try? FileHandle(forWritingTo: logFile)
        self.fileHandle?.seekToEndOfFile()

        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        log("🚀 SingAR initialized v\(AppVersion.current)")
    }

    /// Этап 1: права только владельца (0600) для лог-файла. Best-effort, без throw.
    static func enforceOwnerOnlyPermissions(at url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Этап 1: санитизация перед записью в лог. Убирает URL (http/https/ws/wss),
    /// остатки query с секретом, заголовок ключа; тела/полный текст сюда не класть —
    /// для текста только `redactedPreview`. Pure-seam, offline-тестируемо.
    static func sanitize(_ message: String) -> String {
        var out = message
        // URL целиком → плейсхолдер (запрет записи URL).
        // Паттерн намеренно без секрета: матчит только схему+хост, не значения.
        let urlPattern = "(https?|wss?)://\\S+"
        if let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            out = urlRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<url-redacted>")
        }
        // Остатки query с секретом без схемы.
        let queryKeyPattern = "([?&](key|api_key|apiKey)=)[^\\s&]+"
        if let keyRegex = try? NSRegularExpression(pattern: queryKeyPattern, options: .caseInsensitive) {
            out = keyRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1<redacted>")
        }
        // Заголовок с ключом, если кто-то попытался залогировать его значение.
        if let hdrRegex = try? NSRegularExpression(pattern: "(x-goog-api-key\\s*[:=]\\s*)\\S+", options: .caseInsensitive) {
            out = hdrRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1<redacted>")
        }
        return out
    }

    /// Этап 1: безопасное описание ошибки без URL/тел. Только домен+код,
    /// никогда `localizedDescription` целиком (там бывают URL).
    static func sanitizedError(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)(\(ns.code))"
    }

    /// True когда сообщение безопасно писать в лог (нет URL/схемы).
    static func isSafeForLog(_ message: String) -> Bool {
        let lower = message.lowercased()
        return !lower.contains("http://") && !lower.contains("https://")
            && !lower.contains("ws://") && !lower.contains("wss://")
    }

    func log(_ message: String) {
        // Этап 1: санитизация обязательна до NSLog и до записи в файл.
        let safe = Self.sanitize(message)
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(safe)\n"
        NSLog("[SingAR] %@", safe)

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
        FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        Self.enforceOwnerOnlyPermissions(at: logFile)
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
