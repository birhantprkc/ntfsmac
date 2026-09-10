import Foundation
import Testing
@testable import NtfsmacGUI

private final class TerminationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _terminated = false

    var isTerminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return _terminated
    }

    func terminate() {
        lock.lock()
        _terminated = true
        lock.unlock()
    }
}

private final class ScriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _content: String?

    var content: String? {
        lock.lock(); defer { lock.unlock() }
        return _content
    }

    func set(_ value: String?) {
        lock.lock()
        _content = value
        lock.unlock()
    }
}

@Test func relaunchAndSwapRejectsWhenActiveMountsPresent() throws {
    let tracker = TerminationTracker()
    let service = RealAppRelaunchService(terminator: { tracker.terminate() })

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stagedApp = tempDir.appendingPathComponent("ntfsmac.app")
    let targetApp = tempDir.appendingPathComponent("target.app")

    #expect(throws: AppRelaunchError.activeMountsPresent) {
        try service.relaunchAndSwap(
            stagedAppURL: stagedApp,
            targetAppURL: targetApp,
            hasActiveMounts: true
        )
    }

    #expect(!tracker.isTerminated)
}

@Test func relaunchAndSwapGeneratesValidScriptAndTriggersTermination() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let stagedApp = tempDir.appendingPathComponent("ntfsmac.app")
    let contents = stagedApp.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try "bin".write(to: contents.appendingPathComponent("ntfsmac-gui"), atomically: true, encoding: .utf8)

    let targetApp = tempDir.appendingPathComponent("target.app")

    let tracker = TerminationTracker()
    let scriptBox = ScriptBox()

    let service = RealAppRelaunchService(
        scriptSpawner: { scriptURL, args in
            scriptBox.set(try? String(contentsOf: scriptURL, encoding: .utf8))
        },
        terminator: { tracker.terminate() }
    )

    try service.relaunchAndSwap(
        stagedAppURL: stagedApp,
        targetAppURL: targetApp,
        hasActiveMounts: false
    )

    #expect(tracker.isTerminated)
    #expect(scriptBox.content != nil)
    #expect(scriptBox.content?.contains("rm -rf \"$TARGET\"") == true)
    #expect(scriptBox.content?.contains("cp -R \"$STAGED\" \"$TARGET\"") == true)
    #expect(scriptBox.content?.contains("xattr -dr com.apple.quarantine \"$TARGET\"") == true)
    #expect(scriptBox.content?.contains("open \"$TARGET\"") == true)
}
