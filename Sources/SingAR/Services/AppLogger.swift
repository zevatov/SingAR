import Foundation

final class AppLogger {
    static let shared = AppLogger()

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
            self.fileHandle?.write(data)
        }
    }
}
