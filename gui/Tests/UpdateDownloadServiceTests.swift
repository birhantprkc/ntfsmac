import Foundation
import Testing
@testable import NtfsmacGUI

private struct FakeDownloaderBackend: DownloaderBackend {
    let result: Result<URL, Error>
    let steps: [Double]

    func downloadFile(from url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        for step in steps {
            progress(step)
        }
        return try result.get()
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func add(_ val: Double) {
        lock.lock()
        _values.append(val)
        lock.unlock()
    }
}

@Test func updateDownloadServiceStreamsProgressAndReturnsFileURL() async throws {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-download.dmg")
    try "dummy dmg content".write(to: tempURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let backend = FakeDownloaderBackend(
        result: .success(tempURL),
        steps: [0.1, 0.5, 1.0]
    )
    let service = RealUpdateDownloadService(backend: backend)

    let collector = ProgressCollector()
    let downloadedURL = try await service.download(
        from: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac.dmg")!,
        progress: { collector.add($0) }
    )

    #expect(downloadedURL == tempURL)
    #expect(collector.values == [0.1, 0.5, 1.0])
}

@Test func updateDownloadServicePropagatesDownloadErrors() async throws {
    enum SimulatedError: Error, Equatable {
        case networkLost
    }
    let backend = FakeDownloaderBackend(
        result: .failure(SimulatedError.networkLost),
        steps: [0.2]
    )
    let service = RealUpdateDownloadService(backend: backend)

    await #expect(throws: SimulatedError.networkLost) {
        _ = try await service.download(
            from: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac.dmg")!,
            progress: { _ in }
        )
    }
}
