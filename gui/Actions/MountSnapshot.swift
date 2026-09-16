import Foundation
import HelperShared

/// One ntfsmac-owned NFS mount observed from the host rather than inferred from a GUI action.
/// `isReadOnly == nil` means the anylinuxfs runtime reported the mount but the host mount table
/// could not be paired with it, so callers must present an explicit unverified state.
public struct ObservedMount: Equatable, Sendable {
    public let deviceIdentifier: String
    public let mountPoint: String
    public let fsDriver: String?
    public let isReadOnly: Bool?

    public init(
        deviceIdentifier: String,
        mountPoint: String,
        fsDriver: String? = nil,
        isReadOnly: Bool? = nil
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.mountPoint = mountPoint
        self.fsDriver = fsDriver
        self.isReadOnly = isReadOnly
    }
}

/// A snapshot is authoritative only when both sources agree: `anylinuxfs status` identifies the
/// owning device/session and `/sbin/mount -t nfs` confirms the live host mount plus its options.
public struct MountSnapshot: Equatable, Sendable {
    public let mounts: [ObservedMount]
    public let isAuthoritative: Bool
    public let warningCode: String?

    public init(
        mounts: [ObservedMount],
        isAuthoritative: Bool = true,
        warningCode: String? = nil
    ) {
        self.mounts = mounts
        self.isAuthoritative = isAuthoritative
        self.warningCode = warningCode
    }
}

@MainActor
public protocol MountSnapshotProviding {
    func snapshot() async -> MountSnapshot
}

/// Parser for the stable `anylinuxfs status` line shape:
/// `/dev/disk6s1 on /Volumes/Name (ntfs-3g, mounted by user) VM[cpus: ...]`.
/// The username is intentionally ignored and never reaches the GUI state.
public enum AnyLinuxFSStatusParser {
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^(?:/dev/)?(disk[0-9]+(?:s[0-9]+)?) on (.+) \((.*)\) VM\[cpus:"#
    )

    public static func parse(_ output: String) -> [ObservedMount] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = linePattern.firstMatch(in: line, range: range),
                  let device = capture(match, 1, in: line),
                  let mountPoint = capture(match, 2, in: line),
                  let info = capture(match, 3, in: line),
                  validateDevice(device)
            else { return nil }

            let driver = info
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first
            return ObservedMount(
                deviceIdentifier: device,
                mountPoint: MountTableParser.decodeEscapes(mountPoint),
                fsDriver: driver,
                isReadOnly: nil
            )
        }
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        _ index: Int,
        in line: String
    ) -> String? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }
}

public struct NFSMountTableEntry: Equatable, Sendable {
    public let source: String
    public let mountPoint: String
    public let isReadOnly: Bool
    public let deviceIdentifier: String?
}

/// Parses macOS's `/sbin/mount -t nfs` output. Matching from the right preserves mount points
/// containing spaces; octal escapes are decoded before pairing with `anylinuxfs status`.
public enum MountTableParser {
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^(\S+) on (.+) \(nfs(?:,\s*(.*))?\)$"#
    )
    private static let ntfsmacHost = try! NSRegularExpression(
        pattern: #"^(disk[0-9]+(?:s[0-9]+)?)(?:-[0-9]+)?\.local:"#,
        options: [.caseInsensitive]
    )

    public static func parse(_ output: String) -> [NFSMountTableEntry] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = linePattern.firstMatch(in: line, range: range),
                  let source = capture(match, 1, in: line),
                  let mountPoint = capture(match, 2, in: line)
            else { return nil }

            let options = capture(match, 3, in: line)?
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            return NFSMountTableEntry(
                source: decodeEscapes(source),
                mountPoint: decodeEscapes(mountPoint),
                isReadOnly: options.contains("read-only") || options.contains("ro"),
                deviceIdentifier: deviceIdentifier(from: source)
            )
        }
    }

    static func decodeEscapes(_ value: String) -> String {
        if !value.contains("\\") { return value }
        return value
            .replacingOccurrences(of: "\\040", with: " ")
            .replacingOccurrences(of: "\\011", with: "\t")
            .replacingOccurrences(of: "\\134", with: "\\")
    }

    static func deviceIdentifier(from source: String) -> String? {
        let range = NSRange(source.startIndex..., in: source)
        guard let match = ntfsmacHost.firstMatch(in: source, range: range),
              let device = capture(match, 1, in: source),
              validateDevice(device)
        else { return nil }
        return device.lowercased()
    }

    private static func capture(
        _ match: NSTextCheckingResult,
        _ index: Int,
        in line: String
    ) -> String? {
        guard match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: line)
        else { return nil }
        return String(line[range])
    }
}

/// In-memory kernel mount table inspection using Darwin's `getmntinfo`.
/// Avoids spawning `/sbin/mount -t nfs` subprocesses for production reconciliation.
public enum NativeMountTableReader {
    public static func readNFS() -> [NFSMountTableEntry] {
        var statfsPtr: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&statfsPtr, MNT_NOWAIT)
        guard count > 0, let buffer = statfsPtr else { return [] }
        var entries: [NFSMountTableEntry] = []
        for i in 0..<Int(count) {
            let item = buffer[i]
            let fstype = withUnsafeBytes(of: item.f_fstypename) { raw in
                raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? ""
            }
            guard fstype == "nfs" else { continue }
            let mntfromname = withUnsafeBytes(of: item.f_mntfromname) { raw in
                raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? ""
            }
            let mntonname = withUnsafeBytes(of: item.f_mntonname) { raw in
                raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? ""
            }
            let isReadOnly = (item.f_flags & UInt32(MNT_RDONLY)) != 0
            let decodedSource = MountTableParser.decodeEscapes(mntfromname)
            let decodedMount = MountTableParser.decodeEscapes(mntonname)
            let device = MountTableParser.deviceIdentifier(from: decodedSource)
            entries.append(NFSMountTableEntry(
                source: decodedSource,
                mountPoint: decodedMount,
                isReadOnly: isReadOnly,
                deviceIdentifier: device
            ))
        }
        return entries
    }
}

/// Reads two independent, unprivileged sources. A status-only entry is retained as unverified;
/// a `.local` mount-table entry can also recover a CLI-created mount if status output is briefly
/// unavailable. Only a complete, mutually paired read is allowed to clear cached GUI rows.
@MainActor
public struct RealMountSnapshotProvider: MountSnapshotProviding {
    private let runner: (any PrivilegedCommandRunning)?
    private let anylinuxfsPath: String
    private let mountPath: String

    public init(
        runner: (any PrivilegedCommandRunning)? = nil,
        anylinuxfsPath: String = resolveAnylinuxfsPath(),
        mountPath: String = "/sbin/mount"
    ) {
        self.runner = runner
        self.anylinuxfsPath = anylinuxfsPath
        self.mountPath = mountPath
    }

    public func snapshot() async -> MountSnapshot {
        let statusResult: CommandResult
        let tableMounts: [NFSMountTableEntry]
        let sourcesSucceeded: Bool
        if let runner {
            // Explicit runners are a deterministic test seam and execute on the caller's actor.
            statusResult = runner.run(anylinuxfsPath, ["status"])
            let mountResult = runner.run(mountPath, ["-t", "nfs"])
            tableMounts = mountResult.exitCode == 0
                ? MountTableParser.parse(mountResult.output)
                : []
            sourcesSucceeded = statusResult.exitCode == 0 && mountResult.exitCode == 0
        } else {
            // Production polling: reads mounts in-memory directly from Darwin kernel with 0 subprocesses.
            statusResult = await Self.runOffMain(anylinuxfsPath, ["status"])
            tableMounts = NativeMountTableReader.readNFS()
            sourcesSucceeded = statusResult.exitCode == 0
        }
        let statusMounts = statusResult.exitCode == 0
            ? AnyLinuxFSStatusParser.parse(statusResult.output)
            : []

        var observed: [ObservedMount] = statusMounts.map { statusMount in
            let tableMount = tableMounts.first { $0.mountPoint == statusMount.mountPoint }
            return ObservedMount(
                deviceIdentifier: statusMount.deviceIdentifier,
                mountPoint: statusMount.mountPoint,
                fsDriver: statusMount.fsDriver,
                isReadOnly: tableMount?.isReadOnly
            )
        }

        // If anylinuxfs status is transiently unavailable, its stable `<device>.local` hostname
        // still lets the host mount table identify an ntfsmac-owned session without exporting
        // the hostname, address, volume label, or path to diagnostics.
        for tableMount in tableMounts {
            guard let device = tableMount.deviceIdentifier,
                  !observed.contains(where: { $0.deviceIdentifier == device })
            else { continue }
            observed.append(ObservedMount(
                deviceIdentifier: device,
                mountPoint: tableMount.mountPoint,
                isReadOnly: tableMount.isReadOnly
            ))
        }

        observed.sort { $0.deviceIdentifier < $1.deviceIdentifier }
        let everyStatusMountWasPaired = statusMounts.allSatisfy { statusMount in
            tableMounts.contains {
                $0.mountPoint == statusMount.mountPoint
                    && ($0.deviceIdentifier == nil || $0.deviceIdentifier == statusMount.deviceIdentifier)
            }
        }
        let everyNtfsmacTableMountWasPaired = tableMounts
            .filter { $0.deviceIdentifier != nil }
            .allSatisfy { tableMount in
                statusMounts.contains {
                    $0.mountPoint == tableMount.mountPoint
                        && $0.deviceIdentifier == tableMount.deviceIdentifier
                }
            }
        let sourcesAgree = everyStatusMountWasPaired && everyNtfsmacTableMountWasPaired
        let authoritative = sourcesSucceeded && sourcesAgree
        let warningCode: String?
        if !sourcesSucceeded {
            warningCode = "MOUNT_STATE_SOURCE_UNAVAILABLE"
        } else if !sourcesAgree {
            warningCode = "MOUNT_STATE_INCONSISTENT"
        } else {
            warningCode = nil
        }
        return MountSnapshot(
            mounts: observed,
            isAuthoritative: authoritative,
            warningCode: warningCode
        )
    }

    private nonisolated static func runOffMain(
        _ executablePath: String,
        _ arguments: [String]
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            RealCommandRunner().run(executablePath, arguments)
        }.value
    }
}
