import Foundation
import Combine
import CryptoKit

/// Manages on-demand downloading and storage of the local Whisper model
/// (~1.5 GB ggml-large-v3-turbo.bin). Keeps the app bundle tiny (~1.6 MB).
final class ModelDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = ModelDownloadManager()

    static let modelFileName = "ggml-large-v3-turbo.bin"
    static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!

    /// G1-1: официальный SHA256 модели ggml-large-v3-turbo.bin от ggerganov/whisper.cpp (HuggingFace LFS).
    static let expectedSHA256: String? = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case installed(path: String)
        case error(String)
    }

    @Published private(set) var status: ModelStatus = .notDownloaded

    private var downloadTask: URLSessionDownloadTask?
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    // MARK: Resume support

    /// Resume data of an interrupted download; lets startDownload() continue
    /// from already received bytes instead of restarting the ~1.6 GB transfer.
    private var pendingResumeData: Data?

    /// File where resumeData is persisted so an interrupted download survives app relaunch.
    var resumeDataURL: URL {
        modelsDirectory.appendingPathComponent("download.resumeData")
    }

    /// Additive read-only flag: an interrupted download can be continued.
    var canResumeDownload: Bool {
        if pendingResumeData != nil { return true }
        if let disk = try? Data(contentsOf: resumeDataURL), !disk.isEmpty { return true }
        return false
    }

    var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("SingAR", isDirectory: true).appendingPathComponent("models", isDirectory: true)
    }

    var modelPath: URL {
        modelsDirectory.appendingPathComponent(Self.modelFileName)
    }

    override init() {
        super.init()
        refreshStatus()
    }

    func refreshStatus() {
        // 1. Check Application Support
        if FileManager.default.fileExists(atPath: modelPath.path) {
            status = .installed(path: modelPath.path)
            clearResumeData() // resume state is moot once the model is installed
            return
        }

        // 2. Check bundled model in .app Resources / models
        if let bundled = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin") {
            status = .installed(path: bundled.path)
            return
        }

        // 3. Check development directory models/
        let devModel = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models/\(Self.modelFileName)")
        if FileManager.default.fileExists(atPath: devModel.path) {
            status = .installed(path: devModel.path)
            return
        }

        if case .downloading = status {
            // keep current downloading state
        } else {
            status = .notDownloaded
        }
    }

    var isModelInstalled: Bool {
        if case .installed = status { return true }
        return false
    }

    var activeModelPath: String? {
        if case .installed(let path) = status { return path }
        refreshStatus()
        if case .installed(let path) = status { return path }
        return nil
    }

    // MARK: Actions

    func startDownload() {
        guard case .downloading = status else {
            try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            // Continue an interrupted download when saved resumeData exists;
            // otherwise start a fresh task. Real progress arrives via didWriteData.
            if let resumeData = loadPersistedResumeData() {
                AppLogger.shared.log("⬇️ Model download: resuming from saved resumeData")
                status = .downloading(progress: 0.0)
                let task = urlSession.downloadTask(withResumeData: resumeData)
                self.downloadTask = task
                task.resume()
            } else {
                AppLogger.shared.log("⬇️ Model download: starting from scratch")
                status = .downloading(progress: 0.0)
                let task = urlSession.downloadTask(with: Self.downloadURL)
                self.downloadTask = task
                task.resume()
            }
            return
        }
    }

    func cancelDownload() {
        // Ask the session for resumeData so the download can be continued later;
        // `data` is nil when the task cannot be resumed.
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            self?.storeResumeData(data)
        })
        downloadTask = nil
        refreshStatus()
        // Cancel leaves a stale .downloading state behind; reflect the truth instead.
        if case .downloading = status {
            status = .notDownloaded
        }
    }

    func deleteModel() {
        cancelDownload()
        if FileManager.default.fileExists(atPath: modelPath.path) {
            try? FileManager.default.removeItem(at: modelPath)
        }
        clearResumeData()
        refreshStatus()
    }

    // MARK: Resume data storage

    /// Saves resumeData in memory and on disk. In-memory copy is replaced even
    /// when `data` is nil or empty (keeps the freshest session state).
    private func storeResumeData(_ data: Data?) {
        pendingResumeData = data
        guard let data = data, !data.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try data.write(to: resumeDataURL, options: .atomic)
        } catch {
            AppLogger.shared.log("⚠️ Model download: failed to persist resumeData (in-memory copy kept)")
        }
    }

    private func loadPersistedResumeData() -> Data? {
        if let data = pendingResumeData { return data }
        guard let data = try? Data(contentsOf: resumeDataURL), !data.isEmpty else { return nil }
        pendingResumeData = data
        return data
    }

    /// Removes resume state after the download succeeded or the model was deleted.
    private func clearResumeData() {
        pendingResumeData = nil
        if FileManager.default.fileExists(atPath: resumeDataURL.path) {
            try? FileManager.default.removeItem(at: resumeDataURL)
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        self.status = .downloading(progress: progress)
    }

    // MARK: - Этап 1: SHA256 integrity (offline-testable pure seam)

    /// Потоковый SHA256 файла без загрузки целиком в память (модель ~1.6 ГБ).
    /// Возвращает hex (64 символа). Бросает при ошибке чтения.
    static func sha256HexOfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Pure offline-seam: hex-сравнение без I/O (для unit-тестов без сети).
    /// Сравнение case-insensitive, пробелы/переносы по краям игнорируются.
    static func verifySHA256Hex(_ actualHex: String, expected: String) -> Bool {
        actualHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Pure offline-seam: SHA256 байтов в памяти (малые фикстуры тестов).
    static func verifySHA256(data: Data, expected: String) -> Bool {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return verifySHA256Hex(actual, expected: expected)
    }

    /// Fail-closed проверка скачанного файла ДО moveItem.
    /// - nil/пустой expected = хэш официально не зафиксирован → пропуск (совместимость с Этапом 0).
    /// - mismatch → temp удаляется вызывающей стороной, возвращается false.
    static func isDownloadedFileValid(at location: URL) -> Bool {
        guard let expected = expectedSHA256?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else { return true }
        guard let actual = try? sha256HexOfFile(at: location) else { return false }
        return verifySHA256Hex(actual, expected: expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Этап 1: SHA256 до moveItem. Несовпадение → удалить temp, status=.error, без move.
        // Лог только len+short-hash (без URL/полного хэша/тел), диктовка не затрагивается.
        if let expected = Self.expectedSHA256?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty {
            do {
                let attrs = try? FileManager.default.attributesOfItem(atPath: location.path)
                let byteCount = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
                let actual = try Self.sha256HexOfFile(at: location)
                guard Self.verifySHA256Hex(actual, expected: expected) else {
                    try? FileManager.default.removeItem(at: location)
                    AppLogger.shared.log("❌ Model SHA256 mismatch len=\(byteCount) hash=\(String(actual.prefix(8)))")
                    self.status = .error("Ошибка целостности модели (SHA256)")
                    return
                }
            } catch {
                try? FileManager.default.removeItem(at: location)
                AppLogger.shared.log("❌ Model SHA256 verify failed (unreadable temp)")
                self.status = .error("Ошибка проверки модели (SHA256)")
                return
            }
        }
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
            }
            try FileManager.default.moveItem(at: location, to: modelPath)
            clearResumeData() // download finished successfully; resume state is no longer needed
            self.status = .installed(path: modelPath.path)
        } catch {
            self.status = .error("Ошибка сохранения модели: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                // Cancel: keep resumeData if the session produced one, then drop
                // the stale progress state instead of showing a fake percentage.
                if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    storeResumeData(data)
                }
                downloadTask = nil
                refreshStatus()
                if case .downloading = status {
                    status = .notDownloaded
                }
            } else {
                downloadTask = nil
                if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    storeResumeData(data)
                    AppLogger.shared.log("⚠️ Model download interrupted; resumeData saved (\(data.count) bytes), can be continued")
                    self.status = .error("Загрузка прервана — можно продолжить")
                } else {
                    AppLogger.shared.log("⚠️ Model download failed (code \(nsError.code)) without resumeData")
                    self.status = .error("Ошибка скачивания: \(error.localizedDescription)")
                }
            }
        }
    }
}
