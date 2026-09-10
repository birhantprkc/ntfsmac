import Foundation
import AppKit

public enum AppRelaunchError: Error, Equatable, Sendable {
    case activeMountsPresent
    case stagedAppNotFound
    case swapScriptFailed(String)
}

public protocol AppRelaunching: Sendable {
    func relaunchAndSwap(stagedAppURL: URL, targetAppURL: URL, hasActiveMounts: Bool) throws
}

public struct RealAppRelaunchService: AppRelaunching {
    public typealias ScriptSpawner = @Sendable (URL, [String]) throws -> Void
    public typealias Terminator = @Sendable () -> Void

    private let scriptSpawner: ScriptSpawner
    private let terminator: Terminator
    private let currentPID: pid_t

    public init(
        scriptSpawner: @escaping ScriptSpawner = Self.defaultScriptSpawner,
        terminator: @escaping Terminator = { DispatchQueue.main.async { NSApp.terminate(nil) } },
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.scriptSpawner = scriptSpawner
        self.terminator = terminator
        self.currentPID = currentPID
    }

    public static func defaultScriptSpawner(scriptURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path] + arguments
        try process.run()
    }

    public func relaunchAndSwap(stagedAppURL: URL, targetAppURL: URL, hasActiveMounts: Bool) throws {
        guard !hasActiveMounts else {
            throw AppRelaunchError.activeMountsPresent
        }

        let mainExecutable = stagedAppURL.appendingPathComponent("Contents/MacOS/ntfsmac-gui")
        guard FileManager.default.fileExists(atPath: mainExecutable.path) else {
            throw AppRelaunchError.stagedAppNotFound
        }

        let tempScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsmac-update-swap-\(UUID().uuidString).sh")

        let scriptContent = """
        #!/bin/sh
        PID="$1"
        STAGED="$2"
        TARGET="$3"

        # Wait for the running application to fully exit
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.1
        done

        # Clean removal of old bundle prevents leftover/orphan files
        rm -rf "$TARGET"
        cp -R "$STAGED" "$TARGET"
        rm -rf "$STAGED"

        # Strip Gatekeeper quarantine on installed bundle
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

        # Relaunch the new application
        open "$TARGET"

        # Self-delete the swap script
        rm -- "$0"
        """

        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript.path)

        try scriptSpawner(tempScript, [String(currentPID), stagedAppURL.path, targetAppURL.path])

        terminator()
    }
}
