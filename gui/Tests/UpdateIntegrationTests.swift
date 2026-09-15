import Foundation
import Testing
import HelperShared
@testable import NtfsmacGUI

private final class ThreadSafeState: @unchecked Sendable {
    private let lock = NSLock()
    var scriptExecuted = false
    var terminated = false
    var scriptContent: String?
    var scriptArgs: [String]?

    func recordScript(url: URL, args: [String]) {
        lock.lock()
        defer { lock.unlock() }
        scriptExecuted = true
        scriptContent = try? String(contentsOf: url, encoding: .utf8)
        scriptArgs = args
    }

    func recordTermination() {
        lock.lock()
        defer { lock.unlock() }
        terminated = true
    }

    var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    var wasScriptExecuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return scriptExecuted
    }

    var capturedContent: String? {
        lock.lock()
        defer { lock.unlock() }
        return scriptContent
    }

    var capturedArgs: [String]? {
        lock.lock()
        defer { lock.unlock() }
        return scriptArgs
    }
}

@Suite(.serialized)
struct UpdateIntegrationTests {

    @Test func liveGitHubReleaseCheckDetectsCurrentAndOlderVersions() async throws {
        let service = GitHubReleaseCheckService()

        // 1. Check with a simulated older version (e.g. 2.2 / build 010126)
        let olderVersion = ProductVersion(release: "2.2", build: "010126")
        let updateForOlder = try await service.checkForUpdates(currentVersion: olderVersion)

        #expect(updateForOlder != nil, "Expected GitHub to report an update for older version 2.2")
        guard let update = updateForOlder else { return }

        #expect(update.tagName == "v2.3.040926" || update.version == "2.3")
        #expect(update.dmgURL.host == "github.com")
        #expect(update.dmgURL.lastPathComponent.hasSuffix(".dmg"))
        #expect(update.assetSize > 50_000_000, "DMG size should be ~60MB")

        // 2. Check with the current version (2.3 / build 040926)
        let currentVersion = ProductVersion(release: "2.3", build: "040926")
        let updateForCurrent = try await service.checkForUpdates(currentVersion: currentVersion)

        #expect(updateForCurrent == nil, "Expected GitHub to report nil (up to date) for current version 2.3 (040926)")

        // 3. Check with a hypothetical future version (3.0 / build 010127)
        let futureVersion = ProductVersion(release: "3.0", build: "010127")
        let updateForFuture = try await service.checkForUpdates(currentVersion: futureVersion)

        #expect(updateForFuture == nil, "Expected GitHub to report nil (up to date) for future version 3.0")
    }

    @Test func realDMGExtractionAndIntegrityValidation() async throws {
        let sourceDMG = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/ntfsmac.dmg")

        guard FileManager.default.fileExists(atPath: sourceDMG.path) else {
            // Skip in environments where dist/ntfsmac.dmg hasn't been built beforehand (e.g. CI swift-build)
            return
        }

        // Copy DMG to a temporary location because extractAndValidate cleans up the input dmgURL
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsmac-int-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testDMG = tempDir.appendingPathComponent("ntfsmac.dmg")
        try FileManager.default.copyItem(at: sourceDMG, to: testDMG)

        let service = RealUpdateExtractionService()
        let stagedApp = try await service.extractAndValidate(dmgURL: testDMG)
        defer { try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent()) }

        // Verify staged bundle exists and structure is intact
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: stagedApp.path))

        let infoPlist = stagedApp.appendingPathComponent("Contents/Info.plist")
        #expect(fm.fileExists(atPath: infoPlist.path))

        let guiBin = stagedApp.appendingPathComponent("Contents/MacOS/ntfsmac-gui")
        #expect(fm.isExecutableFile(atPath: guiBin.path))

        let helperBin = stagedApp.appendingPathComponent("Contents/Library/LaunchServices/com.khr898.ntfsmac.helper")
        #expect(fm.isExecutableFile(atPath: helperBin.path))

        let installSh = stagedApp.appendingPathComponent("Contents/Resources/cli-src/install.sh")
        #expect(fm.isExecutableFile(atPath: installSh.path))

        // Verify codesign verification passed
        let codesignProcess = Process()
        codesignProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesignProcess.arguments = ["-v", stagedApp.path]
        try codesignProcess.run()
        codesignProcess.waitUntilExit()
        #expect(codesignProcess.terminationStatus == 0)

        // Verify quarantine attribute is absent
        #expect(!hasQuarantineAttribute(at: stagedApp))

        // Verify test DMG was cleaned up
        #expect(!fm.fileExists(atPath: testDMG.path))
    }

    @Test func activeMountGuardBlocksRelaunchWhenDrivesAreMounted() throws {
        let state = ThreadSafeState()

        let service = RealAppRelaunchService(
            scriptSpawner: { url, args in state.recordScript(url: url, args: args) },
            terminator: { state.recordTermination() }
        )

        let dummyApp = FileManager.default.temporaryDirectory.appendingPathComponent("dummy.app")

        #expect(throws: AppRelaunchError.activeMountsPresent) {
            try service.relaunchAndSwap(
                stagedAppURL: dummyApp,
                targetAppURL: dummyApp,
                hasActiveMounts: true
            )
        }

        #expect(!state.wasScriptExecuted)
        #expect(!state.isTerminated)
    }

    @Test func relaunchGeneratesValidSwapScriptWhenUnmounted() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsmac-relaunch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create mock staged app with executable
        let stagedApp = tempDir.appendingPathComponent("staged.app")
        let stagedBinDir = stagedApp.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: stagedBinDir, withIntermediateDirectories: true)
        let stagedBin = stagedBinDir.appendingPathComponent("ntfsmac-gui")
        try "binary".write(to: stagedBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedBin.path)

        let targetApp = tempDir.appendingPathComponent("target.app")

        let state = ThreadSafeState()

        let service = RealAppRelaunchService(
            scriptSpawner: { url, args in state.recordScript(url: url, args: args) },
            terminator: { state.recordTermination() }
        )

        try service.relaunchAndSwap(
            stagedAppURL: stagedApp,
            targetAppURL: targetApp,
            hasActiveMounts: false
        )

        #expect(state.isTerminated)
        #expect(state.wasScriptExecuted)
        guard let scriptContent = state.capturedContent, let args = state.capturedArgs else {
            Issue.record("Script was not captured")
            return
        }

        #expect(scriptContent.contains("rm -rf \"$TARGET\""))
        #expect(scriptContent.contains("cp -R \"$STAGED\" \"$TARGET\""))
        #expect(scriptContent.contains("xattr -dr com.apple.quarantine \"$TARGET\""))
        #expect(scriptContent.contains("open \"$TARGET\""))

        #expect(args.count == 3)
        #expect(args[1] == stagedApp.path)
        #expect(args[2] == targetApp.path)
    }
}
