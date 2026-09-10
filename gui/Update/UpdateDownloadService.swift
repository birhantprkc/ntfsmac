import Foundation

public enum UpdateDownloadError: Error, Equatable, Sendable {
    case invalidHTTPStatus(Int)
    case downloadFailed(String)
    case cancelled
}

public protocol DownloaderBackend: Sendable {
    func downloadFile(from url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL
}

public protocol UpdateDownloading: Sendable {
    func download(from url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL
}

public struct RealUpdateDownloadService: UpdateDownloading {
    private let backend: any DownloaderBackend

    public init(backend: any DownloaderBackend = URLSessionDownloaderBackend()) {
        self.backend = backend
    }

    public func download(from url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        try await backend.downloadFile(from: url, progress: progress)
    }
}

/// Production downloader backend leveraging URLSession and delegate callbacks for accurate progress streaming.
public final class URLSessionDownloaderBackend: NSObject, DownloaderBackend, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var progressCallback: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var targetDestination: URL?

    public override init() {
        super.init()
    }

    public func downloadFile(from url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsmac-download-\(UUID().uuidString).dmg")

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.progressCallback = progress
            self.continuation = continuation
            self.targetDestination = destination
            lock.unlock()

            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.setValue("ntfsmac-updater", forHTTPHeaderField: "User-Agent")

            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        lock.lock()
        let cb = progressCallback
        lock.unlock()
        cb?(fraction)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard let target = targetDestination, let cont = continuation else { return }
        self.continuation = nil

        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            cont.resume(throwing: UpdateDownloadError.invalidHTTPStatus(response.statusCode))
            return
        }

        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            cont.resume(returning: target)
        } catch {
            cont.resume(throwing: error)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard let cont = continuation else { return }
        self.continuation = nil

        if let error {
            cont.resume(throwing: error)
        }
    }
}
