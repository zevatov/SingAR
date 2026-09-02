import Foundation
import Combine

/// Manages on-demand downloading and storage of the local Whisper model
/// (~1.5 GB ggml-large-v3-turbo.bin). Keeps the app bundle tiny (~1.6 MB).
final class ModelDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = ModelDownloadManager()

    static let modelFileName = "ggml-large-v3-turbo.bin"
    static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!

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
            status = .downloading(progress: 0.0)
            let task = urlSession.downloadTask(with: Self.downloadURL)
            self.downloadTask = task
            task.resume()
            return
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshStatus()
    }

    func deleteModel() {
        cancelDownload()
        if FileManager.default.fileExists(atPath: modelPath.path) {
            try? FileManager.default.removeItem(at: modelPath)
        }
        refreshStatus()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        self.status = .downloading(progress: progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
            }
            try FileManager.default.moveItem(at: location, to: modelPath)
            self.status = .installed(path: modelPath.path)
        } catch {
            self.status = .error("Ошибка сохранения модели: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
                refreshStatus()
            } else {
                self.status = .error("Ошибка скачивания: \(error.localizedDescription)")
            }
        }
    }
}
